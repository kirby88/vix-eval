# LRU File Cache — Swift Implementation Plan

## Context
Greenfield iOS Swift Package implementing a disk-backed LRU file cache per the spec. Multiple named cache instances, fast non-blocking init, async eviction to `tmp/`, atomic writes, debounced index persistence on reads, immediate persistence on mutations, and graceful degradation on corrupt/missing index.

---

## Project Structure

```
LRUFileCache/
├── Package.swift
├── Sources/LRUFileCache/
│   ├── LRUFileCache.swift          # Public façade (final class, Sendable)
│   ├── CacheConfiguration.swift    # Public config struct (Sendable)
│   ├── CacheError.swift            # Public error enum
│   ├── CacheIndex.swift            # actor — in-memory LRU index + eviction
│   ├── IndexNode.swift             # Internal Codable struct per entry
│   ├── LinkedList.swift            # Doubly-linked list (LRU ordering, O(1))
│   ├── DiskStore.swift             # All FileManager operations
│   ├── IndexPersistence.swift      # Encode/decode index to binary plist
│   └── Debouncer.swift             # Actor-isolated debounce helper
└── Tests/LRUFileCacheTests/
    ├── LRUFileCacheTests.swift
    ├── CacheIndexTests.swift
    ├── LinkedListTests.swift
    ├── DiskStoreTests.swift
    ├── IndexPersistenceTests.swift
    └── DebouncerTests.swift
```

---

## Package.swift

Swift 6.0 tools version, platforms `.iOS(.v16)`, strict concurrency enabled via `swiftSettings`.

---

## Public API (`LRUFileCache.swift`)

```swift
public final class LRUFileCache: Sendable {
    public init(configuration: CacheConfiguration)
    public func warmUp() async                         // pre-loads index without blocking init

    public func add(key: String, data: Data) async throws
    public func update(key: String, data: Data) async throws   // alias for add
    public func modify(key: String, data: Data) async throws   // throws keyNotFound if absent

    public func get(key: String) async -> Data?        // nil if absent or file missing on disk
    public func promote(key: String) async throws      // throws keyNotFound if absent

    // Diagnostics / test support
    public func entryCount() async -> Int
    public func totalByteSize() async -> Int
    public func orderedKeys() async -> [String]        // LRU → MRU
}
```

---

## Configuration (`CacheConfiguration.swift`)

```swift
public struct CacheConfiguration: Sendable {
    public var name: String
    public var maxEntryCount: Int
    public var maxTotalByteSize: Int
    public var evictionDebounceInterval: TimeInterval  // also used as read-persistence debounce
    public var dataProtectionClass: FileProtectionType
    public var rootDirectory: URL?                     // defaults to .cachesDirectory
}
```

---

## Error Types (`CacheError.swift`)

```swift
public enum CacheError: Error, Sendable {
    case keyNotFound(String)          // thrown by modify, promote
    case writeFailed(key: String, underlying: Error)  // thrown by add, modify
    case indexCorrupted(underlying: Error)  // internal only; logged, not thrown
    case fileMissingOnDisk(key: String)     // internal only; self-heals, not thrown
}
```

---

## Internal Data Structures

### `IndexNode` (struct, Codable, Sendable)
Fields: `key: String`, `filename: String` (UUID, never derived from key), `byteSize: Int`, `lastAccessedDate: Date`.

### `LRULinkedList` (final class, actor-private)
Doubly-linked list; `head` = LRU, `tail` = MRU. Operations: `append`, `moveToTail`, `remove`, `popHead`, `orderedValues`. All O(1). NOT Sendable — lives entirely inside `CacheIndex` actor.

### `CacheIndex` actor internal state
```
map:  [String: LRULinkedList.ListNode]   // O(1) lookup
list: LRULinkedList                      // O(1) LRU ordering
totalByteSize: Int
isLoaded: Bool
```

---

## Concurrency Design

**All mutable state is isolated to `CacheIndex` actor.** `LRUFileCache` is a stateless `Sendable` façade.

Disk I/O always runs **off-actor** via `Task.detached` or suspension points, so the actor is not blocked during file operations. Concurrent reads on other keys can proceed while a write is in progress.

### `add` flow
1. Enter `CacheIndex` actor → `ensureLoaded()`
2. Generate UUID filename; **suspend** → `DiskStore.ensureDirectoryExists()` + `atomicWrite`
3. Resume on actor → update `map`, `list`, `totalByteSize`
4. `IndexPersistence.save(snapshot())` — **immediate** (within actor, fast plist write)
5. `scheduleEvictionIfNeeded()` → fires `Task.detached` if over limits

### `get` flow
1. Enter actor → `ensureLoaded()` → lookup node (get filename)
2. **Suspend** → `DiskStore.read(filename)`
   - If missing: remove from map+list, `persistence.save()` immediately, return nil
3. Resume on actor → update `lastAccessedDate`, `list.moveToTail`
4. `debouncer.schedule { persistence.save(snapshot()) }` — **debounced**

### Eviction (`runEviction`, runs in `Task.detached`)
1. Enter actor → pop from `list.head` until `count ≤ max && bytes ≤ max`, collect evicted nodes
2. `persistence.save(snapshot())` — **immediate** (within actor)
3. **Exit actor** → `DiskStore.moveToTmp(filename)` for each evicted node (off-actor, non-blocking)

---

## Index Persistence

| Trigger | Timing |
|---|---|
| `add`, `modify`, `modify` key-not-found check | Immediate |
| Eviction (after trimming) | Immediate |
| `get`, `promote` (access) | Debounced by `evictionDebounceInterval` |
| Init with corrupt index | None (degrade to empty, write on first mutation) |

**Format:** Binary property list (`PropertyListEncoder`/`Decoder`). Faster than JSON; `Date` round-trips natively; human-inspectable via `plutil`. Written atomically (same `replaceItem` pattern as data files).

**On-disk path:** `<CachesDirectory>/LRUFileCache/<name>/index.plist`

---

## DiskStore Details

**Atomic write pattern:**
1. Write to `<cacheDir>/../.staging-<name>/<UUID>` (same volume as destination)
2. `FileManager.replaceItem(at: finalURL, withItemAt: stagingURL, ...)` — atomic rename on APFS/HFS+

**Eviction move to `tmp/`:**
1. Move to `FileManager.default.temporaryDirectory/<filename>`
2. On collision (file already exists in tmp): append `-<UUID>` suffix before moving

**Directory recreation:** `ensureDirectoryExists()` is called before every write; uses `withIntermediateDirectories: true`. Handles the "cache dir deleted externally" case transparently.

**Data protection:** Applied via `[.protectionKey: config.dataProtectionClass]` on directory creation. All files inherit it.

---

## Debouncer (`Debouncer.swift`)

```swift
actor Debouncer {
    init(interval: TimeInterval)
    func schedule(_ work: @escaping @Sendable () async -> Void)
    // Cancels any pending task, creates new Task that sleeps then calls work()
}
```

Used by `CacheIndex` to debounce index persistence after `get`/`promote`.

---

## Directory Layout

```
<CachesDirectory>/LRUFileCache/<name>/
    index.plist
    6BA7B810-9DAD-11D1-80B4-00C04FD430C8   ← payload file
    ...
<CachesDirectory>/LRUFileCache/.staging-<name>/
    <transient UUID files during atomic write>
```

---

## Key Constraints — Implementation Checklist

- [ ] `modify` throws `keyNotFound` before any disk I/O if key absent
- [ ] `promote` throws `keyNotFound` if key absent
- [ ] `get` returns nil (no throw) for missing key or missing file
- [ ] File missing at `get` time: remove from index + `persistence.save()` immediately
- [ ] `ensureLoaded()` is idempotent; concurrent calls converge (actor serializes them)
- [ ] Corrupt index at init → catch, log `CacheError.indexCorrupted`, continue with empty index
- [ ] Eviction `moveToTmp` failure → log only; entry already removed from index
- [ ] Index save failure → log only; in-memory state remains correct

---

## Test Plan

### Unit tests (isolated)
- `LinkedListTests`: append, moveToTail, remove, popHead, orderedValues, empty cases
- `IndexPersistenceTests`: round-trip empty/non-empty, corrupt data degrades, date precision
- `DiskStoreTests`: atomic write (create + overwrite), missing dir recreated, moveToTmp with/without collision, data protection attribute
- `DebouncerTests`: single fire, rapid calls fire once, cancel/replace behavior

### Integration tests (`LRUFileCacheTests`)
- add/get round-trip, update replaces, modify throws/succeeds
- promote throws on missing, promote updates LRU order
- get returns nil on missing key; returns nil + self-heals on missing file
- LRU eviction order (access A, B, C, get(A) → evict B first)
- Index survives simulated restart (new instance on same directory)
- Corrupt index.plist → new instance starts empty
- Cache dir deleted externally → recreated on next write
- Multiple named caches are independent (same key, different data)
- 100 concurrent adds → no data races (Swift 6 strict concurrency)
- Reads succeed while eviction is in progress

---

## Implementation Order

1. `IndexNode.swift`
2. `CacheError.swift`
3. `CacheConfiguration.swift`
4. `LinkedList.swift` + tests
5. `DiskStore.swift` + tests
6. `IndexPersistence.swift` + tests
7. `Debouncer.swift` + tests
8. `CacheIndex.swift` + tests
9. `LRUFileCache.swift` + integration tests
10. `Package.swift`
