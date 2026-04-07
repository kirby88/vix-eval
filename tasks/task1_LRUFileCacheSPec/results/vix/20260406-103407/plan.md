## Implementation Plan: LRU File Cache in Swift

### Overview

This is a greenfield Swift package — no existing files to follow patterns from. The design targets iOS and will be structured as a Swift Package with a single library target plus a test target.

---

### Architecture

**Three-layer design:**

1. `LRUCacheConfiguration` — value type holding per-cache settings
2. `LRUCacheIndex` — in-memory index of entries with LRU metadata; handles serialization/deserialization
3. `LRUFileCache` — the public-facing actor that owns the index, coordinates I/O, schedules eviction and debounced persistence

**Concurrency model:** Swift `actor` for `LRUFileCache`. This gives us data-race safety for free, ensures the index is never accessed from two threads simultaneously, and allows `async` callers without blocking threads. Eviction is dispatched as a detached `Task` so it does not block the caller.

---

### File Structure

```
/workspace/
  Package.swift
  Sources/
    LRUFileCache/
      LRUCacheConfiguration.swift
      LRUCacheEntry.swift
      LRUCacheIndex.swift
      LRUFileCache.swift
  Tests/
    LRUFileCacheTests/
      LRUFileCacheTests.swift
```

---

### Step-by-Step Implementation Plan

#### Step 1 — `Package.swift`

- Swift tools version 5.9 (minimum for full `actor` and `async/await` support on iOS 15+)
- Single library product `LRUFileCache`
- Test target `LRUFileCacheTests` depending on `LRUFileCache`
- Platform minimum: `.iOS(.v15)`

---

#### Step 2 — `LRUCacheConfiguration.swift`

A plain `struct` (value type, `Sendable`):

```swift
public struct LRUCacheConfiguration: Sendable {
    public let name: String
    public let maxEntryCount: Int
    public let maxTotalBytes: Int
    public let evictionDebounceInterval: TimeInterval
    public let dataProtectionClass: FileProtectionType
}
```

`FileProtectionType` is already defined in Foundation for iOS. Provide a memberwise initializer with sensible defaults (e.g. `.completeUntilFirstUserAuthentication`).

---

#### Step 3 — `LRUCacheEntry.swift`

A `struct` representing one index record. Needs `Codable` for persistence, `Sendable` for actor crossing:

```swift
struct LRUCacheEntry: Codable, Sendable {
    let key: String
    var fileName: String      // stable UUID-based name, not the key itself
    var byteSize: Int
    var lastAccessedDate: Date
}
```

Key insight: store a stable `fileName` (UUID on first insert) separate from the logical `key`. This avoids filesystem escaping issues and makes rename/replace safe.

---

#### Step 4 — `LRUCacheIndex.swift`

Manages the in-memory ordered collection and serialization. Not an actor — it is always accessed from within `LRUFileCache`'s actor isolation.

**Internal state:**
- `var entries: [String: LRUCacheEntry]` — keyed by logical key for O(1) lookup
- `var totalBytes: Int` — tracked incrementally

**Methods:**
- `insert(_:)` / `remove(key:)` / `entry(for:)` — basic CRUD
- `touch(key:)` — update `lastAccessedDate` to `Date.now`
- `evictionCandidates(maxCount:maxBytes:) -> [LRUCacheEntry]` — returns entries to evict sorted by `lastAccessedDate` ascending (oldest first) until both limits are satisfied
- `save(to url: URL) throws` — `JSONEncoder` → write atomically via `Data.write(to:options:.atomic)`
- `static func load(from url: URL) throws -> LRUCacheIndex` — `JSONDecoder`; caller catches and falls back to empty index on any error

The index file is named `index.json` inside the cache directory.

---

#### Step 5 — `LRUFileCache.swift` (core)

Declared as `public actor LRUFileCache`.

**Init:**
```swift
public init(configuration: LRUCacheConfiguration) throws
```
- Computes cache directory URL: `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: configuration.name)`
- Creates directory if needed, applying `dataProtectionClass` via `FileManager` attributes
- Attempts `LRUCacheIndex.load(from: indexURL)` — on any failure (missing file, corrupt JSON), starts with empty `LRUCacheIndex`
- No network/blocking I/O; directory creation is fast and is the only I/O at init time
- Init is marked `throws` only for directory creation failure (a hard error); index corruption is swallowed

**`add(key:data:) async throws`:**
1. Determine `fileName`: if entry already exists reuse its `fileName`, else generate `UUID().uuidString`
2. Compute file URL: `cacheDirectory.appending(path: fileName)`
3. Ensure cache directory exists (`recreate` helper — see constraints)
4. Write atomically: `data.write(to: fileURL, options: [.atomic, .noFileProtection])` — `.noFileProtection` is overridden by the directory's inherited protection class on iOS; alternatively set the file attribute explicitly after write
5. Update index: `index.insert(LRUCacheEntry(key: key, fileName: fileName, byteSize: data.count, lastAccessedDate: .now))`
6. Save index immediately (`try index.save(to: indexURL)`)
7. Schedule eviction (debounced via `evictionTask`)

**`update(key:data:) async throws`:**
- Calls `add(key:data:)` — literal alias

**`modify(key:data:) async throws`:**
- Check `index.entry(for: key)` — if nil, throw `LRUCacheError.keyNotFound`
- Otherwise proceed exactly as `add` steps 2–7 (reusing existing `fileName`)

**`get(key:) async throws -> Data?`:**
1. Guard `index.entry(for: key)` exists, else return `nil`
2. Attempt `Data(contentsOf: fileURL)`
3. If file missing (catch `CocoaError.fileNoSuchFile`): call `index.remove(key:)`, schedule debounced index save, return `nil` — self-heal
4. On success: call `index.touch(key:)`, schedule debounced index save
5. Return data

**`promote(key:) async throws`:**
1. Guard `index.entry(for: key)` exists, else throw `LRUCacheError.keyNotFound`
2. `index.touch(key:)`
3. Schedule debounced index save

**Eviction:**

```swift
private var pendingEvictionTask: Task<Void, Never>?

private func scheduleEviction() {
    pendingEvictionTask?.cancel()
    pendingEvictionTask = Task { [configuration] in
        try? await Task.sleep(for: .seconds(configuration.evictionDebounceInterval))
        guard !Task.isCancelled else { return }
        await self.runEviction()
    }
}

private func runEviction() {
    let candidates = index.evictionCandidates(
        maxCount: configuration.maxEntryCount,
        maxBytes: configuration.maxTotalBytes
    )
    guard !candidates.isEmpty else { return }
    for entry in candidates {
        let src = cacheDirectory.appending(path: entry.fileName)
        let dst = tmpURL(for: entry.fileName)   // unique name in tmp/
        try? FileManager.default.moveItem(at: src, to: dst)
        index.remove(key: entry.key)
    }
    try? index.save(to: indexURL)
}
```

`tmpURL(for:)` produces a URL in `FileManager.default.temporaryDirectory` using the original filename; to handle collisions it appends a UUID suffix if a file already exists at the destination:

```swift
private func tmpURL(for fileName: String) -> URL {
    let base = FileManager.default.temporaryDirectory.appending(path: fileName)
    if FileManager.default.fileExists(atPath: base.path) {
        return FileManager.default.temporaryDirectory
            .appending(path: "\(fileName)-\(UUID().uuidString)")
    }
    return base
}
```

**Debounced index save (for `get`/`promote`):**

```swift
private var pendingIndexSaveTask: Task<Void, Never>?

private func scheduleDebouncedIndexSave() {
    pendingIndexSaveTask?.cancel()
    pendingIndexSaveTask = Task {
        try? await Task.sleep(for: .seconds(0.5))   // short debounce
        guard !Task.isCancelled else { return }
        try? self.index.save(to: self.indexURL)
    }
}
```

Mutations bypass this and call `index.save` directly.

**Directory recreation helper:**

```swift
private func ensureCacheDirectoryExists() throws {
    guard !FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
    try FileManager.default.createDirectory(
        at: cacheDirectory,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: configuration.dataProtectionClass]
    )
}
```

Called at the start of every write operation (`add`, `modify`).

---

#### Step 6 — `LRUCacheError.swift` (can be in same file or separate)

```swift
public enum LRUCacheError: Error {
    case keyNotFound
    case directoryCreationFailed(underlying: Error)
}
```

---

#### Step 7 — `Tests/LRUFileCacheTests/LRUFileCacheTests.swift`

Tests using `XCTest` (compatible with Swift Package testing on Linux/macOS):

- `testAddAndGet` — round-trips data
- `testGetMissingKeyReturnsNil`
- `testModifyFailsOnMissingKey`
- `testModifySucceedsOnExistingKey`
- `testAddReplacesExistingKey`
- `testGetSelfHealsOnMissingFile` — write entry to index manually, delete file, call get, expect nil + index cleaned
- `testPromoteFailsOnMissingKey`
- `testPromoteUpdatesAccessDate`
- `testEvictionByCount` — insert N+1 items with maxCount=N, wait for eviction, verify oldest is gone from cache dir
- `testEvictionByBytes`
- `testIndexPersistsSurvivesReinit` — add item, reinit cache from same config, get item
- `testCorruptedIndexDegradesToEmpty` — write garbage to index.json, init cache, expect no crash and empty state
- `testCacheDirectoryRecreation` — delete cache dir after init, do add, expect success
- `testEvictionMovesToTmp` — after eviction, file should appear in tmp directory
- `testEvictionTmpCollision` — force collision in tmp, expect unique suffix name used

Each test creates a unique `configuration.name` (e.g. using `UUID().uuidString`) to get an isolated cache directory. Teardown removes the directory.

---

### Key Design Decisions and Trade-offs

**Actor vs serial DispatchQueue:** `actor` is the idiomatic modern Swift choice. It composes naturally with `async/await` and gives compile-time data-race checking. The downside is iOS 15+ minimum; if iOS 13 were needed we'd fall back to `DispatchQueue` serialization.

**Stable `fileName` vs key-as-filename:** Using a UUID-based filename avoids URL encoding, path traversal, and length issues with arbitrary cache keys. The key→fileName mapping is maintained in the index.

**Incremental `totalBytes` tracking:** Recomputing total bytes by summing all entries on every eviction check would be O(n). Instead, maintain a running total in the index, updating it on insert/remove.

**Debounce scope:** Only `get`/`promote` are debounced. Writes and evictions are immediately durable. This matches the spec precisely and prevents index drift after mutations.

**Atomic write for data files:** `Data.write(to:options:.atomic)` uses a write-to-temp-then-rename pattern internally, which is correct. The index also uses `.atomic` for the same reason.

**Move-to-tmp instead of delete:** This matches the spec and provides a grace window if the caller holds a reference to the file URL. Files in tmp are cleaned up by the OS on restart or when space pressure occurs.

---

### Critical Files for Implementation

- `/workspace/Sources/LRUFileCache/LRUFileCache.swift` - Core actor: all public API, eviction scheduling, debounced persistence, directory lifecycle
- `/workspace/Sources/LRUFileCache/LRUCacheIndex.swift` - In-memory index with LRU metadata, serialization/deserialization, eviction candidate selection
- `/workspace/Sources/LRUFileCache/LRUCacheEntry.swift` - Codable entry model; foundation for correct LRU ordering and stable file naming
- `/workspace/Package.swift` - Swift package manifest; defines targets, platform constraints, and test linkage
- `/workspace/Tests/LRUFileCacheTests/LRUFileCacheTests.swift` - Test coverage for all API methods and edge cases (self-heal, corruption, eviction, persistence)