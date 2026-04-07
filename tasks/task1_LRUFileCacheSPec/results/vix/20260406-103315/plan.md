## Implementation Plan: LRU File Cache in Swift

### Architecture Overview

The implementation will consist of four files:

1. `LRUFileCache.swift` — public-facing cache type (the main entry point)
2. `LRUFileCacheIndex.swift` — in-memory index + persistence logic
3. `LRUFileCacheConfig.swift` — configuration type
4. `LRUFileCacheError.swift` — error enum

All files live in a single module with no external dependencies beyond Foundation.

---

### Concurrency Model

All mutations and reads go through a single serial `DispatchQueue` (internal, private label). This queue is the synchronization boundary for the in-memory index. Callers block on this queue for reads/writes, which are fast (no disk I/O beyond the atomic file write itself). Eviction is dispatched asynchronously onto a separate low-priority background queue so it never blocks callers.

The public API is synchronous and `throws`. This keeps the interface simple and avoids async/await for broader iOS compatibility.

---

### File-by-File Plan

#### `LRUFileCacheConfig.swift`

A plain `struct` with all per-cache configuration fields:

```
public struct LRUFileCacheConfig {
    public let name: String
    public let maxEntryCount: Int
    public let maxTotalBytes: Int
    public let evictionDebounceInterval: TimeInterval
    public let dataProtectionClass: FileProtectionType
}
```

`FileProtectionType` is the Foundation type (`URLFileProtection`) so it maps directly to iOS data protection attributes set via `FileManager` when creating directories and writing files.

---

#### `LRUFileCacheError.swift`

A simple enum used for the two explicit failure cases:

```
public enum LRUFileCacheError: Error {
    case keyNotFound(String)
}
```

`modify` and `promote` throw `.keyNotFound` when the key is absent.

---

#### `LRUFileCacheIndex.swift`

This is the internal index. It is NOT public. It manages:

**Index entry model:**

```
struct IndexEntry: Codable {
    let key: String
    var fileName: String    // stable UUID-based filename on disk
    var lastAccessedDate: Date
    var byteSize: Int
}
```

`fileName` is a UUID-based string generated at insert time. This decouples the on-disk filename from the cache key (which could contain characters unsafe for file system use) and ensures no collisions between caches.

**In-memory state:**

- `var entries: [String: IndexEntry]` — keyed by cache key for O(1) lookup
- `var totalBytes: Int` — running total, maintained incrementally

**Persistence:**

The index is persisted as a `Codable`-encoded `[IndexEntry]` array using `JSONEncoder`/`JSONDecoder`. The index file lives at `<cacheDirectory>/index.json`.

On `init`, the index file is loaded synchronously (this is acceptable since it runs once, before the cache is handed to callers; no hot-path I/O). If decoding fails for any reason, the index degrades to empty — no crash.

Persistence is triggered by calling `save()`:
- Mutations call `save()` synchronously (still on the serial queue, so non-blocking to callers in terms of correctness; it is a disk write but an atomic one to a small JSON file)
- Access operations (`get`/`promote`) schedule a debounced `save()` using a `DispatchWorkItem` that is cancelled and recreated on each access within the debounce window

**Eviction decision:** The index exposes a method `entriesExceedingLimits(maxCount:maxBytes:) -> [IndexEntry]` which returns entries sorted by `lastAccessedDate` ascending (oldest first) that need to be removed to bring the cache within limits. Caller (the cache) acts on the returned list.

---

#### `LRUFileCache.swift`

The public type. `public final class LRUFileCache`.

**Initialization:**

```swift
public init(config: LRUFileCacheConfig, baseDirectory: URL) throws
```

`baseDirectory` is typically the app's Caches directory. The cache creates a subdirectory at `baseDirectory/<config.name>/`. This is done eagerly at init time. The index is loaded from disk here. This init is not failable — if the directory cannot be created, it throws.

**Fast-start guarantee:** The init reads the index from disk (small JSON file) and creates the directory if needed. No enumeration of cache files is performed. The index is the single source of truth.

**Directory recreation on write:** Before any disk write (`add`/`modify`), the cache checks `FileManager.default.fileExists(atPath:)` and calls `createDirectory` if absent. This is cheap and handles the external-deletion case.

**Atomic writes:** All data writes use `Data.write(to:options:.atomic)`. The `.atomic` option writes to a temp file then renames, which is the standard Foundation atomic write.

**Data protection:** When creating the cache directory, set the `FileProtectionType` attribute. When writing files, set `.completeFileProtection` (or the configured class) via file attributes after write, or use `FileManager` to set the attribute on the directory so it is inherited.

Actually, more precisely: set the protection attribute on the written file after the atomic write using `FileManager.default.setAttributes([.protectionKey: config.dataProtectionClass], ofItemAtPath:)`. Also set it on the directory at creation time.

**API implementations:**

`add(key:data:)`:
1. Acquire serial queue (sync)
2. If key exists in index: remove old file (move to tmp/)
3. Generate UUID fileName
4. Write data atomically to `<cacheDir>/<fileName>`
5. Set data protection attribute on the file
6. Upsert index entry with current date, byte size
7. Update `totalBytes`
8. Call `index.save()` immediately
9. Schedule eviction (debounced via `DispatchWorkItem` on background queue)

`update(key:data:)` — calls `add(key:data:)` directly.

`modify(key:data:)`:
1. Acquire serial queue (sync)
2. Look up key in index — if absent, throw `.keyNotFound`
3. Move old file to tmp/ (replace in place by writing new UUID file, then move old to tmp/)
4. Generate new UUID fileName
5. Write new data atomically
6. Set data protection attribute
7. Update index entry (new fileName, new byteSize, update lastAccessedDate)
8. Update `totalBytes`
9. Call `index.save()` immediately
10. Schedule eviction

`get(key:) -> Data?`:
1. Acquire serial queue (sync)
2. Look up key in index — if absent, return nil
3. Construct file URL from `entry.fileName`
4. Attempt `Data(contentsOf:)` — if file is missing, self-heal: remove from index, call `index.save()` immediately, return nil
5. Update `entry.lastAccessedDate` to now
6. Schedule debounced `index.save()`
7. Return data

`promote(key:)`:
1. Acquire serial queue (sync)
2. Look up key in index — if absent, throw `.keyNotFound`
3. Update `entry.lastAccessedDate` to now
4. Schedule debounced `index.save()`

**Eviction:**

A private `scheduleEviction()` method cancels any pending eviction `DispatchWorkItem` and schedules a new one after `config.evictionDebounceInterval` on a background queue. The work item, when it fires:

1. Dispatches `sync` back onto the serial queue to compute which entries need eviction (calls `index.entriesExceedingLimits(...)`) — this is fast and just reads in-memory state
2. Returns the list of entries to evict
3. For each entry: move `<cacheDir>/<fileName>` to `FileManager.default.temporaryDirectory/<fileName>`. Handle collisions by appending a UUID suffix if a file already exists at the tmp destination.
4. Dispatches `sync` back onto the serial queue to remove the evicted entries from the index, update `totalBytes`, and call `index.save()` immediately

This design means the serial queue is only held briefly (for index reads/writes), not during the actual file-move I/O.

**Tmp collision handling:** Before moving to tmp, check if `tmpDir/<fileName>` exists. If so, use `tmpDir/<UUID>_<fileName>` as the destination. Since `fileName` is itself a UUID, collisions are already rare, but the check guarantees correctness.

---

### Key Design Decisions and Trade-offs

**Why synchronous public API?** Avoids async complexity for callers that do not need it. File writes for typical cache entries (images, small blobs) complete in under a millisecond. The serial queue ensures thread safety. Callers who want non-blocking behavior can dispatch to their own queue.

**Why UUID filenames?** Cache keys may be arbitrary strings (URLs, identifiers) with characters that are problematic in file paths. UUID filenames are always safe, short, and unique.

**Why move to tmp/ instead of delete?** Per the spec. The OS reclaims tmp/ files automatically. Moving is also faster than deleting in some file systems and reduces the chance of data loss if the caller holds a reference to the data.

**Why JSON for index persistence?** Human-readable for debugging, `Codable` makes it trivial to implement. The index is small (entry count × ~100 bytes). For very large caches (tens of thousands of entries) a binary format (e.g., `PropertyListEncoder` with binary format) would be faster, but JSON is fine for iOS cache use cases.

**Why check `fileExists` before every write instead of once at init?** The spec requires handling the case where the directory is deleted externally at any time. Checking on every write is the only correct approach. The `fileExists` call is cheap.

**Debounced index save for reads:** Without debouncing, a hot read path (e.g. scrolling through a list, triggering hundreds of `get` calls per second) would thrash the disk writing the index on every access. The debounce collapses this to one write per debounce window.

**Immediate index save for mutations:** Mutations change the ground truth (what files exist, their sizes). Losing this on crash could leave orphaned files or incorrect byte counts. The cost is one small JSON write per mutation, which is acceptable.

---

### File Structure

```
Sources/LRUFileCache/
    LRUFileCacheConfig.swift
    LRUFileCacheError.swift
    LRUFileCacheIndex.swift
    LRUFileCache.swift
```

No Package.swift or Xcode project boilerplate is strictly required by the spec, but the sources are organized as a standalone Swift module.

---

### Critical Files for Implementation

- `/workspace/Sources/LRUFileCache/LRUFileCache.swift` — Core public API: all five cache methods, eviction scheduling, directory recreation, atomic writes, data protection
- `/workspace/Sources/LRUFileCache/LRUFileCacheIndex.swift` — In-memory index, Codable persistence, debounced save, eviction candidate selection
- `/workspace/Sources/LRUFileCache/LRUFileCacheConfig.swift` — Configuration struct, foundation for all per-cache settings
- `/workspace/Sources/LRUFileCache/LRUFileCacheError.swift` — Error type used by `modify` and `promote`