# Implementation Plan: LRU File Cache in Swift

## Architectural Overview

This is a greenfield Swift package. The implementation will be a Swift Package Manager library with no external dependencies, targeting iOS. The design uses an actor-based concurrency model (Swift 5.5+) for thread safety, a doubly-linked list + dictionary for O(1) LRU operations, and a separate debounce mechanism for index persistence.

## File Structure

```
/workspace/
  Package.swift
  Sources/
    LRUFileCache/
      LRUFileCache.swift          # Public API — the main actor-based cache type
      CacheConfiguration.swift   # Configuration struct
      CacheIndex.swift           # In-memory LRU index (linked list + dict)
      CacheEntry.swift           # Index entry model (key, fileURL, size, lastAccessed)
      IndexPersistence.swift      # Encode/decode index to/from disk (JSON)
      EvictionManager.swift       # Async eviction logic (move to tmp/)
      Debouncer.swift             # Generic debounce helper
  Tests/
    LRUFileCacheTests/
      LRUFileCacheTests.swift
      CacheIndexTests.swift
      EvictionTests.swift
```

## Component Design

### 1. `CacheConfiguration.swift`

A plain `struct` with no behavior.

```
struct CacheConfiguration {
    let name: String
    let maxEntryCount: Int
    let maxTotalBytes: Int
    let evictionDebounceInterval: TimeInterval
    let dataProtectionClass: FileProtectionType  // e.g. .complete, .completeUnlessOpen
}
```

`FileProtectionType` is already defined in Foundation for iOS. Used when creating the cache directory and writing files via `setAttributes`.

### 2. `CacheEntry.swift`

The unit stored in the index. Must be `Codable` for persistence.

```
struct CacheEntry: Codable {
    let key: String
    let fileName: String       // derived from key, not the key itself, to avoid FS-unsafe chars
    var byteSize: Int
    var lastAccessed: Date
}
```

`fileName` is derived once at insertion time (e.g. SHA256 hex of key, or a UUID). Using a stable hash of the key means the filename is deterministic and survives index reconstruction.

### 3. `CacheIndex.swift`

The in-memory LRU structure. This is not an actor — it is a plain class (reference type) owned exclusively by the cache actor, so no separate synchronization is needed.

Internal structure: a `Dictionary<String, Node>` for O(1) lookup, and a doubly-linked list where the head is the most-recently used and the tail is the least-recently used. This is the standard LRU pattern.

Key operations:
- `insert(entry:)` — prepend to head; if key exists, remove old node first
- `touch(key:) -> CacheEntry?` — move node to head, update `lastAccessed`, return updated entry or nil
- `remove(key:)` — unlink node from list
- `evictionCandidates(untilCount:underBytes:) -> [CacheEntry]` — walk from tail, collect entries until both constraints are satisfied
- `allEntries() -> [CacheEntry]` — snapshot for persistence

The index is initialized as empty. The actor loads it from disk during `init` asynchronously, so the cache is immediately usable (all reads/writes will simply miss or be appended until the load completes — more on sequencing below).

### 4. `IndexPersistence.swift`

Responsible solely for reading and writing the index file. No actor — it is a namespace of static functions called by the cache actor on its own executor.

```
enum IndexPersistence {
    static func load(from url: URL) -> [CacheEntry]   // returns [] on any error (corrupt/missing)
    static func save(_ entries: [CacheEntry], to url: URL) throws
}
```

`load` catches all errors and returns an empty array — this satisfies the "corrupted index degrades gracefully" constraint. `save` writes atomically using `Data.write(to:options:.atomic)`.

### 5. `Debouncer.swift`

A generic, actor-isolated debounce mechanism. Used to coalesce index saves triggered by `get`/`promote`.

```
actor Debouncer {
    init(interval: TimeInterval, action: @escaping @Sendable () async -> Void)
    func trigger()    // schedules action after interval; cancels previous pending task
}
```

Internally holds an optional `Task` that sleeps for `interval` then calls `action`. Each `trigger()` cancels any pending task and creates a new one.

### 6. `EvictionManager.swift`

A namespace of static async functions. Called by the cache actor after every mutation.

```
enum EvictionManager {
    static func moveToTmp(entry: CacheEntry, from cacheDir: URL) async throws
    static func evict(
        index: inout CacheIndex,
        config: CacheConfiguration,
        cacheDir: URL,
        indexURL: URL
    ) async
}
```

`moveToTmp` moves a file from `cacheDir/fileName` to `FileManager.default.temporaryDirectory/fileName`. If a file with that name already exists in tmp, it appends a UUID suffix before moving, handling the collision constraint.

`evict` is the main entry point. It:
1. Asks the index for eviction candidates
2. Removes each candidate from the index
3. Calls `moveToTmp` for each (errors are swallowed — the file may already be gone)
4. Saves the index immediately (mutation path — no debounce)

### 7. `LRUFileCache.swift`

The main public type. An `actor` for automatic Sendable/isolation guarantees.

```swift
public actor LRUFileCache {
    private let config: CacheConfiguration
    private let cacheDir: URL
    private let indexURL: URL
    private var index: CacheIndex
    private let debouncer: Debouncer

    public init(config: CacheConfiguration) async
    public func add(key: String, data: Data) async throws
    public func update(key: String, data: Data) async throws   // calls add
    public func modify(key: String, data: Data) async throws
    public func get(key: String) async throws -> Data?
    public func promote(key: String) async throws
}
```

## Key Design Decisions and Sequencing

### Fast start / no blocking I/O on hot path

The `init` is `async` and loads the index from disk on the actor's executor before returning. This means init itself does the I/O (it is awaited by the caller), but no subsequent hot-path call ever blocks waiting for initialization. There is no lazy-load race condition. The caller simply `await`s the init once.

Alternative considered: load index in a background Task and serve from an empty index until ready, then merge. This is much more complex and error-prone. The simpler approach — async init that completes loading before returning — satisfies "usable immediately after init with no blocking I/O on the hot path" because after init returns, the index is warm in memory. All subsequent operations are O(1) in-memory with async file I/O only for the payload.

### Concurrency model

`LRUFileCache` is an `actor`. The `CacheIndex` is a non-Sendable reference type owned exclusively by the actor, so it never needs its own lock. The `Debouncer` is a separate actor to allow it to hold its own cancellable task state independently.

### `add` implementation

1. Derive `fileName` from key (stable hash).
2. Ensure `cacheDir` exists (create if absent — satisfies "directory deleted externally" constraint).
3. Write `data` atomically to `cacheDir/fileName` with the configured data protection class.
4. Build a `CacheEntry` with `byteSize = data.count`, `lastAccessed = .now`.
5. `index.insert(entry:)` — this handles the "replace if key exists" case by removing the old node first. If an old entry existed with a different size, that is replaced.
6. `IndexPersistence.save` immediately (mutation path).
7. Trigger `EvictionManager.evict` as a detached Task (does not block the caller).

### `modify` implementation

1. Guard that the key exists in the index. If not, throw `LRUFileCacheError.keyNotFound`.
2. Follow the same write path as `add` from step 2 onward, but update the existing entry's `byteSize` in the index rather than inserting fresh.

### `get` implementation

1. Look up key in index. If absent, return nil.
2. Check that `cacheDir/fileName` exists on disk. If missing, call `index.remove(key:)`, save index immediately, return nil. (Self-heal constraint.)
3. Read data from disk.
4. `index.touch(key:)` to update `lastAccessed` and move to head.
5. Trigger `debouncer.trigger()` — coalesced index save.
6. Return data.

### `promote` implementation

1. Look up key in index. If absent, throw `LRUFileCacheError.keyNotFound`.
2. `index.touch(key:)`.
3. Trigger `debouncer.trigger()`.

### Index persistence strategy

| Trigger | Persistence |
|---|---|
| `add`, `modify`, eviction | Immediate `IndexPersistence.save` |
| `get`, `promote` | Debounced via `Debouncer` |

The `Debouncer`'s action closure calls `IndexPersistence.save` with the current index snapshot. Because the closure runs on the cache actor's executor (it is captured as `@Sendable` and calls back through the actor), it is safe.

### Eviction collision handling in tmp/

```swift
var dest = tmpDir.appendingPathComponent(entry.fileName)
if FileManager.default.fileExists(atPath: dest.path) {
    dest = tmpDir.appendingPathComponent(entry.fileName + "-" + UUID().uuidString)
}
try FileManager.default.moveItem(at: src, to: dest)
```

### Data protection

When creating the cache directory:
```swift
try FileManager.default.createDirectory(
    at: cacheDir,
    withIntermediateDirectories: true,
    attributes: [.protectionKey: config.dataProtectionClass]
)
```

When writing files, use `setAttributes` after the atomic write, or pass attributes to `write(to:options:)` via the file coordinator path.

### Error type

```swift
public enum LRUFileCacheError: Error {
    case keyNotFound(String)
    case writeFailed(underlying: Error)
}
```

## Test Plan

- `CacheIndexTests`: unit-test the doubly-linked list — insert, touch, eviction candidate selection, LRU ordering
- `EvictionTests`: verify files are moved to tmp/, verify collision suffix is applied, verify index is updated and saved
- `LRUFileCacheTests`: integration — add/get roundtrip, modify fails on missing key, promote updates order, corrupted index init, missing file self-heal, directory recreation

## Implementation Sequencing

1. `Package.swift` — establish the package manifest
2. `CacheEntry.swift` — the foundational data model
3. `CacheConfiguration.swift` — configuration struct
4. `CacheIndex.swift` — LRU data structure (pure logic, no I/O, easiest to unit test)
5. `IndexPersistence.swift` — JSON encode/decode, atomic write
6. `Debouncer.swift` — standalone actor, no dependencies
7. `EvictionManager.swift` — depends on CacheIndex, IndexPersistence
8. `LRUFileCache.swift` — assembles all components
9. Tests

---

### Critical Files for Implementation

- `/workspace/Sources/LRUFileCache/LRUFileCache.swift` — Main actor; public API surface; orchestrates all other components
- `/workspace/Sources/LRUFileCache/CacheIndex.swift` — Core LRU data structure; all ordering logic lives here
- `/workspace/Sources/LRUFileCache/IndexPersistence.swift` — Index serialization; correctness of persistence and graceful corruption handling
- `/workspace/Sources/LRUFileCache/EvictionManager.swift` — Async eviction; tmp/ move and collision handling
- `/workspace/Sources/LRUFileCache/Debouncer.swift` — Debounce mechanism; prevents write amplification on read path