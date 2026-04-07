# LRU File Cache — Swift Package Implementation Plan

## Context
Greenfield Swift Package implementing a disk-backed LRU file cache for iOS. Empty workspace. Requirements specify multiple named caches, non-blocking init, async eviction, atomic writes, debounced index persistence, and graceful degradation on corruption.

---

## Package Structure

```
Package.swift
Sources/DiskCache/
  CacheError.swift           # Public error enum
  CacheConfiguration.swift   # Config struct + FileProtectionType default
  CacheEntry.swift           # Codable index entry (key, filename, sizeBytes, dates)
  FileHasher.swift           # SHA256(key) → 64-char hex filename
  CacheIndex.swift           # In-memory [String: CacheEntry] dict + eviction logic
  Internal/
    DebounceTask.swift        # Cancel-and-recreate debounce helper (@unchecked Sendable)
  DiskCache.swift            # Public actor — all public API methods
Tests/DiskCacheTests/
  Helpers/TempDirectoryFixture.swift
  DiskCacheTests.swift
  EvictionTests.swift
  PersistenceTests.swift
  ConcurrencyTests.swift
  EdgeCaseTests.swift
```

---

## Package.swift

```swift
// swift-tools-version: 6.0
// Platforms: [.iOS(.v16), .macOS(.v13)]  (macOS for CI test runs)
// No external dependencies — CryptoKit + Foundation are system frameworks
// Targets: .target("DiskCache"), .testTarget("DiskCacheTests", dependencies: ["DiskCache"])
// Swift settings: .enableUpcomingFeature("StrictConcurrency")
```

---

## Types

### `CacheError`
```swift
public enum CacheError: Error, Sendable {
    case keyNotFound
}
```

### `CacheConfiguration`
```swift
public struct CacheConfiguration: Sendable {
    public let name: String
    public let maxEntryCount: Int?         // nil = unlimited
    public let maxTotalBytes: Int?         // nil = unlimited
    public let evictionDebounceInterval: Duration   // default: .milliseconds(500)
    public let dataProtection: FileProtectionType  // default: .completeUntilFirstUserAuthentication
    public let baseDirectory: URL          // default: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
}
```

### `CacheEntry` (Codable, Sendable)
```swift
struct CacheEntry: Codable, Sendable {
    let key: String           // original key
    let filename: String      // SHA256 hex of key
    var sizeBytes: Int
    var lastAccessedDate: Date
    let insertedDate: Date
}
```

### `FileHasher`
```swift
// CryptoKit SHA256.hash(data: Data(key.utf8)) → lowercase hex string (64 chars)
// Deterministic, filesystem-safe, no collisions across distinct keys
static func filename(for key: String) -> String
```

### `CacheIndex` (value type, used inside actor)
```swift
struct CacheIndex {
    private(set) var entries: [String: CacheEntry] = [:]
    private(set) var totalBytes: Int = 0

    mutating func insert(_ entry: CacheEntry)      // updates totalBytes
    mutating func remove(key: String)              // updates totalBytes
    mutating func updateAccessDate(key: String, date: Date)
    func contains(key: String) -> Bool

    // Returns keys to evict, sorted oldest-first, satisfying both caps
    func evictionCandidates(maxEntryCount: Int?, maxTotalBytes: Int?) -> [String]

    func encode() throws -> Data                   // JSON array of entries
    static func decode(from: Data) throws -> CacheIndex
}
```

### `DebounceTask` (@unchecked Sendable — exclusively owned by DiskCache actor)
```swift
final class DebounceTask: @unchecked Sendable {
    func schedule(delay: Duration, action: @escaping @Sendable () async -> Void)
    func cancel()
    // Internally: cancels pendingTask, creates new Task { try await Task.sleep(for: delay); await action() }
}
```

---

## `DiskCache` Actor

### Directory layout
```
<baseDirectory>/<name>/          ← cache files (named by SHA256 of key)
<baseDirectory>/<name>/tmp/      ← evicted files land here
<baseDirectory>/<name>/index.json
```

### Init (non-blocking)
```swift
public init(configuration: CacheConfiguration) {
    // 1. Compute all URLs synchronously (pure computation, no I/O)
    // 2. self.indexLoadTask = Task { [weak self] in await self?.loadIndex() }
    // Init returns immediately — no blocking I/O
}
```

### Barrier pattern (every public method calls this first)
```swift
private func waitForIndex() async {
    await indexLoadTask?.value
    indexLoadTask = nil   // cleared after first resolution
}
```
Any call before index loads suspends until `loadIndex()` completes. Subsequent calls find `indexLoadTask == nil` and proceed immediately. Actor serializes all callers.

### `loadIndex()` (called once from init Task)
```swift
private func loadIndex() async {
    do {
        try ensureDirectoriesExist()
        let data = try Data(contentsOf: indexURL)
        self.index = try CacheIndex.decode(from: data)
    } catch {
        self.index = CacheIndex()   // graceful degradation — corrupted or missing = empty
    }
}
```

### `ensureDirectoriesExist()` — called before every write
```swift
// FileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true,
//     attributes: [.protectionKey: configuration.dataProtection])
// Same for tmpDirectoryURL
// Handles external deletion of cache dir — idempotent (no error if exists)
```

### `add(key:data:)` / `update(key:data:)`
```swift
// 1. await waitForIndex()
// 2. ensureDirectoriesExist()
// 3. Atomic write: data.write(to: fileURL, options: .atomic)
//    + FileManager.setAttributes([.protectionKey: ...]) on final path
// 4. index.insert(CacheEntry(...))  — preserve insertedDate on replace
// 5. debounce.cancel(); persistIndex() immediately
// 6. scheduleEviction() — fire-and-forget Task
```

### `update` is a direct alias for `add`.

### `modify(key:data:)` — replace existing only
```swift
// 1. await waitForIndex()
// 2. guard index.contains(key: key) else { throw CacheError.keyNotFound }
// 3. try await add(key: key, data: data)
```

### `get(key:) -> Data?`
```swift
// 1. await waitForIndex()
// 2. guard let entry = index.entries[key] else { return nil }
// 3. guard let data = try? Data(contentsOf: fileURL) else {
//        // Self-heal: file in index but missing on disk
//        index.remove(key: key); debounce.cancel(); try? persistIndex()
//        return nil
//    }
// 4. index.updateAccessDate(key: key, date: Date())
// 5. scheduleIndexPersistDebounced()  ← debounced, avoids write amplification
// 6. return data
```

### `promote(key:)` — bump LRU without reading
```swift
// 1. await waitForIndex()
// 2. guard index.contains(key: key) else { throw CacheError.keyNotFound }
// 3. index.updateAccessDate(key: key, date: Date())
// 4. scheduleIndexPersistDebounced()
```

### Index persistence helpers
```swift
// Immediate: debounce.cancel(); try data.write(to: indexURL, options: .atomic)
// Debounced: debounce.schedule(delay: config.evictionDebounceInterval) { [weak self] in
//                await self?.persistIndexDebounced() }
```

### Eviction (async, non-blocking)
```swift
private func scheduleEviction() {
    Task { [weak self] in await self?.performEviction() }  // fire-and-forget
}

private func performEviction() async {
    let candidates = index.evictionCandidates(maxEntryCount:..., maxTotalBytes:...)
    guard !candidates.isEmpty else { return }
    for key in candidates {
        let src = cacheDir/<entry.filename>
        let dst = evictionDestinationURL(filename:)  // tmp/<filename> or tmp/<filename>-<UUID> on collision
        try? FileManager.default.moveItem(at: src, to: dst)
        index.remove(key: key)
    }
    debounce.cancel(); try? persistIndex()  // immediate persist after eviction
}

// Collision handling in tmp/:
// Check if dst exists → if yes, append "-<UUID>" suffix before extension (extension is always empty for SHA256 names)
```

---

## Persistence Strategy

| Operation | Persist mode | Reason |
|---|---|---|
| `add` / `modify` | Immediate, cancels debounce | Mutation — no data loss on crash |
| Eviction | Immediate, cancels debounce | Mutation — evicted entries must not reappear |
| Self-heal | Immediate, cancels debounce | Index correction |
| `get` / `promote` | Debounced | Read-path — LRU order loss on crash is acceptable |

---

## Concurrency Notes

- Actor serialization guarantees no concurrent index access.
- Eviction `Task` calls back into actor method — naturally serialized.
- `DebounceTask` closure uses `weak self` + calls actor method via `await` → re-enters actor correctly.
- Multiple `await indexLoadTask?.value` callers are safe — Task result can be awaited by many concurrent callers.
- `@unchecked Sendable` on `DebounceTask` is safe because it is exclusively owned by the actor.

---

## Edge Cases

1. **External cache dir deletion**: `ensureDirectoriesExist()` before every write recreates it.
2. **Corrupted index**: `loadIndex` catches all errors → empty cache (no crash).
3. **File in index, missing on disk**: `get` self-heals: removes from index, immediate persist, returns nil.
4. **`add` replacing existing key**: Same filename (deterministic SHA256). `CacheIndex.insert` subtracts old size before adding new. `insertedDate` preserved.
5. **Filename collisions in tmp/**: UUID suffix appended on collision.
6. **Data protection on iOS Simulator**: `FileProtectionType` attributes silently ignored. Gate those test assertions with `#if !targetEnvironment(simulator)`.

---

## Test Plan

- **Core** (`DiskCacheTests`): add/get/update/modify/promote happy paths + error cases
- **Eviction** (`EvictionTests`): count cap, bytes cap, LRU ordering, files in tmp, collision handling
- **Persistence** (`PersistenceTests`): index survives reinit, LRU order survives, corrupted index degrades, immediate persist on mutation verified by reading index.json
- **Concurrency** (`ConcurrencyTests`): 50 concurrent adds (no crash, index consistent), parallel add+get (no crash), rapid adds to capped cache
- **Edge cases** (`EdgeCaseTests`): self-heal, dir recreation, debounce timing, immediate write cancels pending debounce

Each test uses `TempDirectoryFixture` for isolated per-test directories. Concurrency tests use `TaskGroup` or `async let`.

---

## Implementation Order

1. `Package.swift`
2. `CacheError.swift`
3. `CacheConfiguration.swift`
4. `CacheEntry.swift`
5. `FileHasher.swift`
6. `CacheIndex.swift`
7. `Internal/DebounceTask.swift`
8. `DiskCache.swift`
9. Test helper + test files
