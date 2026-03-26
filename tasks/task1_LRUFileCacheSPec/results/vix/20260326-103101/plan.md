## Implementation Plan: LRU File Cache in Swift

### Architectural Overview

The implementation uses Swift Package Manager with a single library target and a test target. The core design centers on an `actor`-based cache that serializes all mutations while keeping reads non-blocking via the actor's built-in concurrency isolation. Eviction is debounced via a `Task` that is cancelled and recreated on each triggering write.

---

### Project Structure

```
/workspace/
  Package.swift
  Sources/
    LRUFileCache/
      LRUFileCache.swift          # Main public actor + public API
      CacheConfiguration.swift    # Configuration struct
      CacheEntry.swift            # Index entry (Codable)
      CacheIndex.swift            # In-memory index management
      DebouncedTask.swift         # Generic debounce helper
  Tests/
    LRUFileCacheTests/
      LRUFileCacheTests.swift     # XCTest suite
```

---

### File-by-File Design

#### `/workspace/Package.swift`

Standard SPM manifest. Minimum platform iOS 16 (to use `actor`, structured concurrency, and `FileProtectionType`). Two targets: `LRUFileCache` (library) and `LRUFileCacheTests` (test).

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LRUFileCache",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LRUFileCache", targets: ["LRUFileCache"]),
    ],
    targets: [
        .target(name: "LRUFileCache"),
        .testTarget(name: "LRUFileCacheTests", dependencies: ["LRUFileCache"]),
    ]
)
```

---

#### `/workspace/Sources/LRUFileCache/CacheConfiguration.swift`

A plain `struct` holding all per-cache configuration. `FileProtectionType` is a Foundation type available on both iOS and macOS.

```swift
import Foundation

public struct CacheConfiguration: Sendable {
    public let name: String
    public let maxEntryCount: Int
    public let maxTotalBytes: Int
    public let evictionDebounceInterval: TimeInterval
    public let fileProtection: FileProtectionType

    public init(
        name: String,
        maxEntryCount: Int,
        maxTotalBytes: Int,
        evictionDebounceInterval: TimeInterval = 1.0,
        fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication
    )
}
```

The `name` value is used as the subdirectory name under the application's Caches directory, scoped per cache instance.

---

#### `/workspace/Sources/LRUFileCache/CacheEntry.swift`

A `Codable` struct representing a single index record. The on-disk filename is stored separately from the user-facing key to allow safe filesystem names without character escaping in lookup paths.

```swift
import Foundation

struct CacheEntry: Codable {
    let key: String
    let filename: String      // UUID-based, collision-free
    var byteSize: Int
    var lastAccessedDate: Date
}
```

The filename is assigned once at insertion time using `UUID().uuidString` and never changes. The key-to-entry mapping lives in the in-memory index.

---

#### `/workspace/Sources/LRUFileCache/CacheIndex.swift`

Manages the in-memory LRU state. Internally uses a `Dictionary<String, CacheEntry>` for O(1) key lookup. LRU order is derived by sorting on `lastAccessedDate` only when eviction runs (lazy sort), avoiding the overhead of maintaining a doubly-linked list.

```swift
import Foundation

struct CacheIndex {
    private(set) var entries: [String: CacheEntry] = [:]
    private(set) var totalBytes: Int = 0

    mutating func insert(_ entry: CacheEntry)
    mutating func update(_ entry: CacheEntry)       // replaces existing
    mutating func remove(key: String)
    func entry(for key: String) -> CacheEntry?

    // Returns keys to evict, sorted LRU-first (oldest access first),
    // until both maxEntryCount and maxTotalBytes constraints are satisfied.
    func keysToEvict(maxCount: Int, maxBytes: Int) -> [String]
}
```

The `keysToEvict` method sorts `entries.values` by `lastAccessedDate` ascending and walks the list until both constraints are met, returning the keys for the entries that should be moved to `tmp/`.

---

#### `/workspace/Sources/LRUFileCache/DebouncedTask.swift`

A lightweight helper that owns a cancellable `Task` and replaces it on each `schedule` call. The debounce fires after a fixed delay with no coalescing of payloads — the caller captures what it needs in the closure.

```swift
import Foundation

final class DebouncedTask: @unchecked Sendable {
    private var currentTask: Task<Void, Never>?
    private let delay: TimeInterval

    init(delay: TimeInterval)

    // Cancels any pending task and schedules a new one.
    func schedule(_ work: @escaping @Sendable () async -> Void)

    // Immediately cancels any pending task (called on deinit or explicit flush).
    func cancel()
}
```

This class is `@unchecked Sendable` because it is only ever accessed from within the actor's serial executor, but Swift cannot prove that statically.

---

#### `/workspace/Sources/LRUFileCache/LRUFileCache.swift`

The main public `actor`. All mutable state (`CacheIndex`, `DebouncedTask`) is actor-isolated. File I/O is performed inside the actor but offloaded to a background executor where needed to avoid stalling the actor.

**Directory layout on disk:**

```
<Caches>/<name>/
    index.json          # Serialized [CacheEntry] array
    <uuid>.bin          # Payload files
```

**Init sequence (non-blocking):**

1. Compute `cacheDirectory` path synchronously (no I/O).
2. Launch a detached `Task` that:
   a. Creates the directory if absent.
   b. Reads and decodes `index.json`.
   c. On decode failure, logs and uses an empty `CacheIndex`.
   d. Writes the loaded index back to the actor via an `actor`-isolated setter.
3. Return immediately. The actor is usable at once; operations before the index loads queue behind the actor and execute after the index is set.

**Key method contracts:**

`add(key:data:)` / `update(key:data:)`:
- Write data atomically to `<cacheDir>/<uuid>.bin` using `FileManager.default.createFile` with `.atomic` option (or `Data.write(to:options:.atomic)`).
- Set file protection attribute.
- Insert/replace entry in `CacheIndex`.
- Persist index immediately.
- Schedule eviction (debounced via separate eviction debounce).

`modify(key:data:)`:
- Look up existing entry; throw `LRUCacheError.keyNotFound` if absent.
- Atomically overwrite the existing file (same filename, same UUID — no rename needed).
- Update `byteSize` and reset `lastAccessedDate` to now.
- Persist index immediately.
- Schedule eviction.

`get(key:) -> Data?`:
- Look up entry; if absent return `nil`.
- Read file from disk. If file missing on disk: remove entry from index, persist index immediately (self-heal), return `nil`.
- Bump `lastAccessedDate` to now in the index.
- Schedule debounced index persist.
- Return data.

`promote(key:)`:
- Look up entry; throw `LRUCacheError.keyNotFound` if absent.
- Bump `lastAccessedDate` to now.
- Schedule debounced index persist.

**Eviction:**

A debounced `Task` (separate from the index-persist debounce) fires after `evictionDebounceInterval`. It:
1. Collects `keysToEvict` from the index.
2. For each key, moves the file to `FileManager.default.temporaryDirectory/<filename>`. If a file with that name already exists in `tmp/`, appends a `UUID` suffix before the extension to avoid collision.
3. Removes the entries from the index.
4. Persists the index immediately.

**Index persistence:**

A private `persistIndex()` method encodes `CacheIndex.entries` (as an array) to JSON and writes atomically to `index.json`.

**Error type:**

```swift
public enum LRUCacheError: Error {
    case keyNotFound(String)
}
```

**Concurrency model summary:**

- `actor` serializes all state mutations — no explicit locks needed.
- File reads/writes happen inside `actor` methods but use async-friendly APIs.
- Eviction runs in a `Task` that re-enters the actor when it needs to mutate the index.
- `DebouncedTask` is accessed only from actor-isolated context.

---

#### `/workspace/Tests/LRUFileCacheTests/LRUFileCacheTests.swift`

XCTest suite using `async` test methods (`XCTestCase` with `setUp` creating a temp directory). Test cases cover:

| Test | What it validates |
|---|---|
| `testAddAndGet` | Basic round-trip |
| `testUpdateReplacesExisting` | `add` on existing key replaces payload |
| `testModifySucceeds` | `modify` on existing key works |
| `testModifyFailsOnMissingKey` | `modify` throws `keyNotFound` |
| `testGetReturnsNilForMissingKey` | `get` returns nil correctly |
| `testPromoteUpdatesLRUOrder` | `promote` moves key to MRU position, affecting eviction order |
| `testEvictionByCount` | Inserting beyond `maxEntryCount` evicts LRU entries |
| `testEvictionByBytes` | Inserting beyond `maxTotalBytes` evicts LRU entries |
| `testEvictedFilesMovedToTmp` | Evicted files appear in `tmp/` not deleted |
| `testIndexPersistence` | Creating a second cache instance with same name sees prior data |
| `testCorruptedIndexDegrades` | Writing garbage to `index.json` produces empty cache, no crash |
| `testSelfHealMissingFile` | Deleting a payload file directly; `get` returns nil and removes entry |
| `testConcurrentReadsAndWrites` | Fire multiple async tasks simultaneously; no crash, consistent state |
| `testDirectoryRecreation` | Delete cache directory; next write recreates it |

---

### Sequencing and Dependencies

1. `Package.swift` — must exist before any Swift files can be compiled.
2. `CacheConfiguration.swift` — no dependencies, pure value type.
3. `CacheEntry.swift` — no dependencies, pure value type.
4. `CacheIndex.swift` — depends on `CacheEntry`.
5. `DebouncedTask.swift` — no dependencies beyond Foundation.
6. `LRUFileCache.swift` — depends on all of the above.
7. `LRUFileCacheTests.swift` — depends on `LRUFileCache` module.

---

### Key Design Decisions and Rationale

| Decision | Rationale |
|---|---|
| `actor` over `DispatchQueue` + locks | Native Swift concurrency; compiler-enforced isolation; composable with async/await |
| UUID filenames | Avoids all filesystem escaping issues; stable across key renames |
| Lazy sort for LRU order | `Dictionary` lookup is O(1); sort only runs at eviction time which is infrequent |
| JSON index format | Human-readable for debugging; `Codable` round-trip is trivial; small enough that parse time is negligible |
| Move-to-tmp eviction | Matches spec; gives the OS/user a chance to inspect evicted data; avoids immediate `unlink` syscall on the hot path |
| Debounce via Task cancellation | No timer objects; cancellation is O(1); straightforward to reason about |
| Non-blocking init | Spec requires "usable immediately"; detached Task + actor queuing satisfies this without any explicit semaphore or flag |

---

### Critical Files for Implementation

- `/workspace/Package.swift` — SPM manifest; must exist before any compilation is possible
- `/workspace/Sources/LRUFileCache/LRUFileCache.swift` — core actor with all public API, eviction logic, index persistence, and directory management
- `/workspace/Sources/LRUFileCache/CacheIndex.swift` — in-memory LRU state and eviction candidate selection
- `/workspace/Sources/LRUFileCache/DebouncedTask.swift` — debounce helper used by both index-persist and eviction paths
- `/workspace/Tests/LRUFileCacheTests/LRUFileCacheTests.swift` — full test coverage validating every specified constraint