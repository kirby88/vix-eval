# LRU File Cache — Swift Implementation Plan

## Context

Greenfield Swift Package implementing a disk-backed LRU file cache for iOS. Multiple independently named instances are supported. The spec requires fast start (no blocking I/O on init), async eviction that moves files to `tmp/` rather than deleting, atomic writes, and a durable index that degrades gracefully on corruption.

---

## Package Layout

```
/workspace/
├── Package.swift
└── Sources/
    └── LRUFileCache/
        ├── CacheError.swift          # Error enum
        ├── CacheConfiguration.swift  # Config struct
        ├── CacheIndex.swift          # CacheEntry + CacheIndex (Codable)
        ├── AtomicWriter.swift        # Atomic write helper (tmp + rename)
        ├── Debouncer.swift           # Actor-based debouncer
        └── LRUFileCache.swift        # Public actor — all API methods
```

No test target in initial scaffold (spec does not request tests), but the design notes where tests would go.

**Package.swift**:
- `swift-tools-version: 5.9`
- Platform: `.iOS(.v16)`
- One library product `LRUFileCache`, one source target
- No external dependencies (Foundation only)

---

## Key Types

### `CacheConfiguration` (struct, Sendable)
```swift
public struct CacheConfiguration: Sendable {
    public var name: String
    public var maxEntryCount: Int           // 0 = unlimited
    public var maxTotalBytes: Int           // 0 = unlimited
    public var evictionDebounceInterval: Duration
    public var dataProtectionClass: FileProtectionType
    public var _baseURL: URL?               // internal; injectable for tests
}
```
`name` is used as the subdirectory name under `NSCachesDirectory`. Default `_baseURL` is nil → uses `NSCachesDirectory`.

### `CacheEntry` (struct, Codable, Sendable)
```swift
struct CacheEntry: Codable, Sendable {
    let key: String
    var filename: String      // UUID().uuidString + ".bin"; stable after creation
    var byteCount: Int
    var lastAccessedAt: Date
    var createdAt: Date
}
```
Filename is assigned once at `add` time and never changes — decouples cache key from filesystem path.

### `CacheIndex` (struct, Codable, Sendable)
```swift
struct CacheIndex: Codable, Sendable {
    var entries: [String: CacheEntry]   // O(1) lookup by key
    var version: Int = 1
}
```
LRU order is derived on demand by sorting `entries.values` by `lastAccessedAt`; not maintained inline (only needed at eviction time).

### `CacheError` (enum, public)
```swift
public enum CacheError: Error, Sendable {
    case keyNotFound(String)
    case writeFailure(underlying: Error)
    case indexSerializationFailure(underlying: Error)
    case directoryCreationFailure(underlying: Error)
}
```

---

## Thread-Safety: `actor LRUFileCache`

Use Swift `actor` (not DispatchQueue) for compile-time concurrency safety (Swift 6 strict concurrency mode). The actor serialises all state mutations to the in-memory `CacheIndex`. File I/O for eviction is handed off to a fire-and-forget `Task` after updating the index.

### `async init`
Load index from disk inside an async init so the init itself is non-blocking. On decode failure (corruption), degrade to `CacheIndex(entries: [:])` silently.

---

## Directory Structure on Disk

```
<NSCachesDirectory>/
└── <name>/
    ├── index.json       ← serialized CacheIndex (JSONEncoder, .secondsSince1970)
    ├── <uuid1>.bin      ← payload
    └── ...
<NSTemporaryDirectory>/
    └── <uuid>-evicted.bin   ← evicted files (OS cleans automatically)
```

Cache directory is created (with `dataProtectionClass`) lazily on first write and recreated if externally deleted.

---

## Atomic Writes (`AtomicWriter`)

For payload files and the index:
1. Write data to `tmp/<uuid>.tmp` via `Data.write(to:options:.atomic)` (extra safety)
2. Set `FileProtectionType` attribute on the tmp file
3. `FileManager.replaceItem(at: destination, withItemAt: tmpURL)` — atomic replacement even when destination already exists (handles `add` replace case)

`NSTemporaryDirectory` and `NSCachesDirectory` are on the same APFS volume on iOS, so `replaceItem`/`moveItem` is an O(1) rename (no copy).

---

## Debouncer (`actor Debouncer`)

```swift
actor Debouncer {
    private var pendingTask: Task<Void, Never>?
    func schedule(_ action: @Sendable @escaping () async -> Void)
    func flush()   // cancel pending task without firing
}
```

`schedule` cancels any prior pending task and starts a new one that sleeps for `evictionDebounceInterval` then calls `action`. `flush` is called on mutations to cancel any stale debounced index write.

---

## API Methods (on `actor LRUFileCache`)

### `add(key:data:)` / `update(key:data:)` (alias)
1. Ensure cache directory exists (recreate if absent)
2. If key exists → reuse filename; else → new UUID filename
3. `AtomicWriter.write(data, to: cacheDir/filename)`
4. Upsert `CacheEntry` in index (`lastAccessedAt = Date()`)
5. `persistIndex()` immediately
6. `await indexDebouncer.flush()`
7. `evictIfNeeded()`

### `modify(key:data:)`
Guard `index.entries[key] != nil` else throw `CacheError.keyNotFound(key)`. Then identical to `add`.

### `get(key:) -> Data?`
1. Guard entry exists else return nil
2. Read file; if missing → remove key from index, schedule debounced persist, return nil (self-heal)
3. Update `lastAccessedAt`
4. Schedule debounced `persistIndex()`
5. Return data

### `promote(key:)`
Guard entry exists else throw `CacheError.keyNotFound`. Update `lastAccessedAt`, schedule debounced persist.

### `persistIndex()` (private)
JSON-encode `index`, `AtomicWriter.write` to `index.json`. Errors swallowed (in-memory state remains correct).

---

## Eviction

Triggered synchronously inside the actor after every `add`/`modify`. Victim selection is in-actor; file moves are off-actor.

**Victim selection**:
- Sort `entries.values` by `lastAccessedAt` ascending
- Greedily pop oldest until `count ≤ maxEntryCount` AND `totalBytes ≤ maxTotalBytes`
- (0 = unlimited → treat as `Int.max`)

**After selection**:
1. Remove victims from `index.entries`
2. `persistIndex()` immediately
3. `await indexDebouncer.flush()`
4. Fire `Task(priority: .utility)` to move victim files: `FileManager.moveItem(src, to: tmp/<UUID>-evicted.bin)` — UUID destination avoids collisions

---

## Constraints Checklist

| Constraint | How satisfied |
|---|---|
| Fast start | `async init` loads index off caller's hot path |
| No blocking on hot path | Actor queues all work; file I/O is small/fast |
| Eviction non-blocking | Victim selection in-actor; file moves in detached Task |
| Eviction moves to `tmp/` | `FileManager.moveItem` to `tmp/<UUID>-evicted.bin` |
| Atomic writes | `AtomicWriter`: tmp write + `replaceItem` |
| Index survives restarts | `index.json` written on every mutation |
| Corrupted index | `try?` decode in init → empty cache |
| Missing file at `get` | Self-heal: remove from index, return nil |
| Deleted cache dir | Recreated before every write |
| `modify` fails if absent | Explicit guard → `keyNotFound` |
| `get`/`promote` update LRU | `lastAccessedAt = Date()` in both |
| Mutation persist immediate | Direct `persistIndex()` call + debouncer flush |
| Read persist debounced | `indexDebouncer.schedule { persistIndex() }` |
| Multiple named caches | Each actor has its own subdirectory |

---

## Implementation Order

1. `CacheError.swift`
2. `CacheConfiguration.swift`
3. `CacheIndex.swift`
4. `AtomicWriter.swift`
5. `Debouncer.swift`
6. `LRUFileCache.swift`
7. `Package.swift`

---

## Verification

After implementation, verify by:
1. `swift build` from `/workspace` — must compile with zero errors/warnings
2. Manually inspect that all 5 public API methods are present with correct signatures
3. Confirm `Package.swift` declares correct platforms, product, and target
4. Inspect `index.json` on disk after a few `add` calls to confirm JSON structure
