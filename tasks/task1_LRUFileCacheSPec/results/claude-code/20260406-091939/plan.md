# DiskLRUCache — Swift Package Implementation Plan

## Context
Greenfield implementation of a disk-backed LRU file cache for iOS as a Swift Package. The workspace is empty. The cache must support multiple independent named instances, survive restarts via a persisted index, run eviction asynchronously without blocking callers, and provide clear error semantics distinguishing absent-key operations.

---

## File Structure

```
Package.swift
Sources/DiskLRUCache/
  CacheConfig.swift       ← per-cache configuration struct
  CacheEntry.swift        ← index entry metadata struct (Codable, Sendable)
  CacheError.swift        ← public error enum
  IndexStore.swift        ← index JSON read/write with graceful degradation
  Eviction.swift          ← pure eviction algorithm + tmp-move logic
  DiskLRUCache.swift      ← public actor + all API methods
Tests/DiskLRUCacheTests/
  DiskLRUCacheTests.swift    ← core API tests
  EvictionTests.swift        ← eviction order, limits, tmp-move, debounce
  PersistenceTests.swift     ← restart survival, corruption, self-heal
  ConcurrencyTests.swift     ← non-blocking init, races, concurrent ops
```

---

## Key Types

### `Package.swift`
- `swift-tools-version: 5.9`
- Platforms: `.iOS(.v15), .macOS(.v12)` (macOS for running tests on CI)
- One library target `DiskLRUCache`, one test target `DiskLRUCacheTests`
- `swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]`

### `CacheConfig` (struct, Sendable)
```swift
public struct CacheConfig: Sendable {
    public let name: String
    public let maxEntryCount: Int           // default 500
    public let maxTotalBytes: Int           // default 50 MB
    public let evictionDebounce: TimeInterval  // default 1.0s
    public let fileProtection: FileProtectionType  // default .completeUntilFirstUserAuthentication
    // Internal testability hook:
    let baseDirectory: URL?                 // nil → uses FileManager.cachesDirectory
}
```

### `CacheEntry` (struct, Codable, Sendable)
```swift
public struct CacheEntry: Codable, Sendable {
    let key: String
    let filename: String     // SHA256(key) hex — the on-disk filename under data/
    var lastAccessed: Date
    let fileSize: Int
}
```

### `CacheError` (enum, Sendable)
```swift
public enum CacheError: Error, Sendable {
    case keyNotFound(String)
    case writeFailure(underlying: Error)
    case moveFailure(underlying: Error)
}
```

---

## Directory Layout (per cache)

```
<cachesDirectory>/<name>/
    index.json            ← JSON-encoded [String: CacheEntry]
    data/
        <sha256hex>       ← one file per entry, named by SHA256(key)
```

---

## `DiskLRUCache` Actor

### Non-blocking init via `initTask` pattern
```swift
public actor DiskLRUCache {
    private var index: [String: CacheEntry] = [:]
    private var initTask: Task<Void, Never>?   // set in init, then stable
    private var evictionTask: Task<Void, Never>?
    private var indexPersistTask: Task<Void, Never>?

    public init(config: CacheConfig) {
        // ... set up URLs ...
        self.initTask = Task { await self.loadIndex() }  // no blocking I/O on caller
    }

    private func ensureReady() async {
        await initTask?.value  // no-op after first resolution; all waiters released together
    }
}
```
Every public method calls `await ensureReady()` first. The calling thread is never blocked.

### Public API
| Method | Behavior |
|---|---|
| `add(key, data)` | `ensureReady`, write entry, persist index immediately, schedule eviction |
| `update(key, data)` | calls `add` |
| `modify(key, data)` | `ensureReady`, throw `.keyNotFound` if absent, else same as `add` |
| `get(key) -> Data?` | `ensureReady`, nil if absent; read file, nil + self-heal if missing on disk; touch LRU; debounced index persist |
| `promote(key)` | `ensureReady`, throw `.keyNotFound` if absent; touch LRU; debounced index persist |

### Atomic Write (used by `add`/`modify`)
```
1. ensureDirectories() — creates <name>/data/ if absent (handles external deletion)
2. Write data to sibling temp: <data>/<UUID>.tmp  using Data.write(options: .withoutOverwriting)
3. setAttributes(.protectionKey: config.fileProtection) on tmp file
4. FileManager.replaceItemAt(destination, withItemAt: tmpURL)
   — atomic rename on APFS/HFS+; handles destination-already-exists case
5. On error: remove tmp; rethrow as CacheError.writeFailure
```
`replaceItemAt` is preferred over `moveItem` because it handles the destination-exists case (needed for upsert in `add`).

### Index Persistence
- **Mutations** (`add`, `modify`, eviction completion): fire-and-forget `Task.detached` immediately — no debounce
- **Access** (`get`, `promote`): cancel previous `indexPersistTask`, create new one that sleeps 500ms then writes (hardcoded debounce, not in config)
- `IndexStore.write` is a static func called from detached tasks; receives a snapshot `[String: CacheEntry]` value (no actor-isolation issue, no staleness beyond debounce window)

### Eviction Scheduling
```swift
private func scheduleEviction() {
    evictionTask?.cancel()
    let snapshot = index   // value-type snapshot at scheduling time
    evictionTask = Task.detached(priority: .background) { [weak self] in
        try? await Task.sleep(nanoseconds: debounceNS)
        guard !Task.isCancelled else { return }
        let toEvict = Eviction.keysToEvict(from: snapshot, config: config)
        let evicted = Eviction.moveToTmp(keys: toEvict, entries: snapshot, dataDirectory: dataDir)
        await self?.applyEviction(keys: evicted)  // re-enters actor to update index
    }
}
```
The snapshot may be slightly stale if mutations happen during debounce — acceptable; eviction is best-effort.

---

## `IndexStore`

```swift
enum IndexStore {
    static func read(from url: URL) -> [String: CacheEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }  // missing → nil
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([String: CacheEntry].self, from: data)  // corrupted → nil
    }

    static func write(_ index: [String: CacheEntry], to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).index.tmp")
        try data.write(to: tmp, options: .withoutOverwriting)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
    }
}
```
`loadIndex()` (actor-isolated) calls `IndexStore.read`; a `nil` return means "start empty, no crash."

---

## `Eviction`

```swift
enum Eviction {
    // Pure function — no I/O. Returns keys to evict sorted oldest-first.
    static func keysToEvict(from index: [String: CacheEntry], config: CacheConfig) -> [String] {
        guard index.count > config.maxEntryCount
           || index.values.reduce(0, { $0 + $1.fileSize }) > config.maxTotalBytes
        else { return [] }

        var sorted = index.values.sorted { $0.lastAccessed < $1.lastAccessed }
        var count = index.count, bytes = index.values.reduce(0) { $0 + $1.fileSize }
        var victims: [String] = []
        while count > config.maxEntryCount || bytes > config.maxTotalBytes, let oldest = sorted.first {
            sorted.removeFirst(); victims.append(oldest.key); count -= 1; bytes -= oldest.fileSize
        }
        return victims
    }

    // Moves files to tmp/; handles collisions with UUID suffix. Returns successfully evicted keys.
    static func moveToTmp(keys: [String], entries: [String: CacheEntry], dataDirectory: URL) -> Set<String> {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        var evicted = Set<String>()
        for key in keys {
            guard let entry = entries[key] else { continue }
            let src = dataDirectory.appendingPathComponent(entry.filename)
            guard fm.fileExists(atPath: src.path) else { evicted.insert(key); continue }
            var dest = tmp.appendingPathComponent(entry.filename)
            if fm.fileExists(atPath: dest.path) {
                dest = tmp.appendingPathComponent("\(entry.filename).\(UUID().uuidString)")
            }
            if (try? fm.moveItem(at: src, to: dest)) != nil { evicted.insert(key) }
            // Move failure is non-fatal: key stays in index, retried next eviction cycle
        }
        return evicted
    }
}
```

---

## Constraint Checklist

| Constraint | Implementation |
|---|---|
| `modify` throws if absent | `guard index[key] != nil` before write |
| `add`/`update` don't throw if absent | unconditional upsert |
| `get`/`promote` update LRU | `index[key]?.lastAccessed = Date()` |
| Access persistence debounced | 500ms `indexPersistTask` cancel+replace |
| Mutation persistence immediate | fire-and-forget `Task.detached` |
| Eviction async, non-blocking | `Task.detached(priority: .background)` |
| Eviction moves to tmp, not delete | `Eviction.moveToTmp` |
| tmp collision handled | UUID suffix appended |
| Atomic writes | write-to-tmp + `replaceItemAt` |
| Corrupted index → empty cache | `try?` decode returns nil → `index = [:]` |
| Missing file at get → nil + self-heal | read fails → remove from index → persist |
| Dir deleted externally → recreate | `ensureDirectories()` called before every write |
| Fast start (no blocking I/O in init) | `initTask = Task { await loadIndex() }` |
| Index survives restarts | `IndexStore.read` from `index.json` in `loadIndex()` |
| Data protection per file | `setAttributes(.protectionKey:)` on tmp before rename |

---

## Testability

All test targets use `@testable import DiskLRUCache`. `CacheConfig` has an `internal` `baseDirectory: URL?` parameter so tests pass `FileManager.default.temporaryDirectory.appendingPathComponent(UUID())` instead of the system caches directory. Test-only internal accessors on the actor: `indexEntry(for:)`, `entryCount()`, `totalBytes()`, `filename(for:)`.

---

## Test Matrix

| Suite | Cases |
|---|---|
| Core API | add/get round-trip, nil on missing, add replaces, update=add, modify success, modify throws, promote success, promote throws, get bumps lastAccessed, concurrent adds safe |
| Eviction | over maxEntryCount, LRU order, over maxTotalBytes, files in tmp not deleted, tmp collision, debounce collapses rapid mutations |
| Persistence | index survives restart, corrupted JSON → empty, missing index → empty, dir deletion → recreated, missing file → nil + self-heal, LRU order persists across restart |
| Concurrency | init non-blocking (<10ms), concurrent reads+writes no crash, operations queue behind initTask |

---

## Verification

```bash
# Build + run all tests (macOS target for CI)
swift test

# Confirm no Swift 6 concurrency warnings
swift build -Xswiftc -strict-concurrency=complete
```
