## Implementation Plan: LRU File Cache for iOS

### Overview

This is a greenfield Swift package. The workspace is empty, so we will create a Swift Package Manager library with a clean, minimal structure. The design centers on a single `LRUFileCache` actor, a value-type `CacheIndex` that is serialized to disk, and a `CacheConfiguration` struct. No third-party dependencies.

---

### File Structure

```
/workspace/
  Package.swift
  Sources/
    LRUFileCache/
      CacheConfiguration.swift
      CacheIndex.swift
      LRUFileCache.swift
      LRUFileCacheError.swift
```

---

### Design Decisions

**Concurrency model**: Swift `actor` for `LRUFileCache`. All mutation and reads are serialized through the actor, which eliminates the need for manual locking. Actor isolation is the correct Swift 5.5+ primitive here.

**Index in memory**: The index is loaded once at init into a private in-memory `CacheIndex` value. All hot-path operations (get, add, promote) mutate only the in-memory index. The index is serialized to disk as needed. This satisfies "fast start" — no blocking I/O on the hot path after init (init itself may do one synchronous read but it is isolated to the actor's init path, not the caller's thread).

**Index persistence strategy**:
- Mutations (add, modify, eviction): write index synchronously within the same actor turn (no debounce).
- Reads (get, promote): schedule a debounced write via a `Task.detached` with a `Task.sleep` delay; if a new access arrives before the delay expires, the pending task is cancelled and replaced.

**Eviction**: Runs as a fire-and-forget `Task` inside the actor after each mutation that could push the cache over its limits. The actor's async nature means eviction does not block the caller. Evicted files are moved to `FileManager.default.temporaryDirectory` with a UUID-prefixed name to avoid collisions.

**Atomic writes**: Use `FileManager.replaceItemAt` or write to a temp file then `FileManager.moveItem` (which is atomic on the same volume).

**Index format**: `Codable` struct serialized to JSON via `JSONEncoder`/`JSONDecoder` written to `<cacheDir>/index.json`. On decode failure, degrade to empty index.

**Data protection**: Set via `FileManager` attributes on the cache directory at creation time using `FileProtectionType` mapped from the configuration enum.

---

### Detailed Type Designs

#### `CacheConfiguration.swift`

```swift
public struct CacheConfiguration {
    public let name: String
    public let maxEntryCount: Int
    public let maxTotalBytes: Int
    public let evictionDebounceInterval: TimeInterval
    public let dataProtection: DataProtectionClass

    public enum DataProtectionClass {
        case none
        case complete
        case completeUnlessOpen
        case completeUntilFirstUserAuthentication
    }
}
```

#### `LRUFileCacheError.swift`

```swift
public enum LRUFileCacheError: Error {
    case keyNotFound(String)
}
```

#### `CacheIndex.swift`

```swift
struct CacheEntry: Codable {
    let key: String
    let fileName: String    // UUID-based, stable
    var lastAccessedDate: Date
    var byteSize: Int
}

struct CacheIndex: Codable {
    var entries: [String: CacheEntry]   // keyed by cache key

    // Returns entries sorted oldest-access-first for eviction
    func evictionOrder() -> [CacheEntry]

    // Total bytes across all entries
    var totalBytes: Int

    mutating func insert(_ entry: CacheEntry)
    mutating func remove(key: String) -> CacheEntry?
    mutating func touch(key: String, date: Date)
}
```

#### `LRUFileCache.swift`

```swift
public actor LRUFileCache {
    private let config: CacheConfiguration
    private let cacheDirectory: URL
    private let indexURL: URL
    private var index: CacheIndex
    private var debouncedPersistTask: Task<Void, Never>?

    public init(config: CacheConfiguration, baseDirectory: URL) async throws

    public func add(key: String, data: Data) throws
    public func update(key: String, data: Data) throws   // calls add
    public func modify(key: String, data: Data) throws   // errors if absent
    public func get(key: String) -> Data?
    public func promote(key: String) throws
}
```

---

### Implementation Sequencing

**Step 1 — Package.swift**

Create the SPM manifest targeting iOS 16+ (minimum version that has full Swift concurrency support without hacks). Single library target `LRUFileCache`, no dependencies.

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LRUFileCache",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "LRUFileCache", targets: ["LRUFileCache"])
    ],
    targets: [
        .target(name: "LRUFileCache"),
        .testTarget(name: "LRUFileCacheTests", dependencies: ["LRUFileCache"])
    ]
)
```

**Step 2 — LRUFileCacheError.swift**

Simple error enum. No logic. Defines `keyNotFound`. Foundation for `modify` and `promote` failure paths.

**Step 3 — CacheConfiguration.swift**

Plain value type. Include a computed property that maps `DataProtectionClass` to `FileProtectionType` for use when setting directory attributes.

**Step 4 — CacheIndex.swift**

The core data structure. Key behaviors:

- `evictionOrder()` sorts `entries.values` by `lastAccessedDate` ascending (oldest first).
- `totalBytes` is a computed property summing `entry.byteSize`.
- `insert` upserts: if a key exists, replace its entry (new fileName, new size, new date).
- `touch` updates `lastAccessedDate` in place.

This type has no I/O and is fully testable in isolation.

**Step 5 — LRUFileCache.swift**

The actor. Detailed method behaviors:

`init(config:baseDirectory:)`:
- Compute `cacheDirectory = baseDirectory/<config.name>`.
- Compute `indexURL = cacheDirectory/index.json`.
- Attempt to load and decode index from `indexURL`. On any failure (missing, corrupt), assign `index = CacheIndex()` — no crash.
- Do NOT create the directory here (fast start — no blocking I/O required until first write).

`add(key:data:)`:
- Call `ensureCacheDirectoryExists()` — creates directory (with data protection attributes) if needed; this is the write path so I/O here is acceptable.
- Compute a stable `fileName`: if the key already exists in the index, reuse its `fileName` (overwrite in place); otherwise generate a new `UUID().uuidString`.
- Write data atomically: write to a temp file in the cache directory, then `FileManager.moveItem` to the final path (atomic on same volume). Use `FileManager.replaceItemAt` if the destination already exists.
- Upsert the index entry with the new byte size and current date.
- Persist index immediately (call `persistIndex()`).
- Schedule eviction check (`Task { await self.runEvictionIfNeeded() }`).

`modify(key:data:)`:
- Check index. If key absent, throw `LRUFileCacheError.keyNotFound(key)`.
- Otherwise, proceed exactly as `add`.

`update(key:data:)`:
- Calls `add(key:data:)` directly.

`get(key:)`:
- Look up entry in index. If absent, return nil.
- Build file URL from `fileName`. Attempt to read data. If file is missing on disk, call `index.remove(key:)`, call `persistIndex()`, return nil (self-heal).
- If data read succeeds, call `index.touch(key:date:Date())`.
- Schedule debounced persist: cancel `debouncedPersistTask`, assign new `Task { try await Task.sleep(for: .seconds(config.evictionDebounceInterval)); await self.persistIndex() }`.
- Return data.

`promote(key:)`:
- Look up entry in index. If absent, throw `LRUFileCacheError.keyNotFound(key)`.
- Call `index.touch(key:date:Date())`.
- Schedule debounced persist (same mechanism as `get`).

`persistIndex()` (private):
- Encode `index` to JSON.
- Write atomically to `indexURL` (write to temp, move).

`runEvictionIfNeeded()` (private, async):
- Loop while `index.entries.count > config.maxEntryCount || index.totalBytes > config.maxTotalBytes`.
- Take the oldest entry from `evictionOrder()`.
- Move its file to `FileManager.default.temporaryDirectory/<UUID>-<originalFileName>`.
- Remove from index.
- After loop, call `persistIndex()`.

`ensureCacheDirectoryExists()` (private):
- If directory does not exist, create it with `FileManager.createDirectory(withIntermediateDirectories:attributes:)`.
- Set `FileProtectionType` attribute via `setAttributes` if needed.

---

### Key Design Constraints Addressed

| Constraint | Approach |
|---|---|
| Fast start | Directory not created at init; index loaded but failure is silent |
| No blocking I/O on hot path | All I/O inside actor async methods; actor runs on cooperative thread pool |
| modify fails if absent | Explicit index check before write; throws keyNotFound |
| get/promote self-heal | On missing file, remove from index and persist immediately |
| Debounced persist for reads | Task-based debounce via cancel+replace pattern |
| Immediate persist for mutations | Direct `persistIndex()` call, no debounce |
| Eviction to tmp, no collisions | UUID prefix on tmp filename |
| Atomic writes | Write to temp then moveItem |
| Corrupted index graceful | try/catch around JSONDecoder; fallback to empty index |
| Directory deleted externally | ensureCacheDirectoryExists() called on every write |

---

### Critical Files for Implementation

- `/workspace/Package.swift` - SPM manifest; establishes platform, targets, and test structure
- `/workspace/Sources/LRUFileCache/LRUFileCache.swift` - Core actor; all cache logic, I/O, eviction, debounce
- `/workspace/Sources/LRUFileCache/CacheIndex.swift` - In-memory index data structure; LRU ordering, entry management
- `/workspace/Sources/LRUFileCache/CacheConfiguration.swift` - Configuration value type and data protection mapping
- `/workspace/Sources/LRUFileCache/LRUFileCacheError.swift` - Error type used by modify and promote