# LRU File Cache — Swift Implementation Plan

## Context

Greenfield Swift Package for iOS. No existing code. Implements a disk-backed LRU file cache per the provided spec: multiple named instances, non-blocking init, async eviction to `tmp/`, atomic writes, persistent index with graceful corruption handling.

---

## Package Layout

```
Package.swift
Sources/LRUFileCache/
  CacheConfiguration.swift   # Value type: name, limits, debounce, protection class
  CacheEntry.swift           # In-memory CacheEntry + Codable CacheEntryRecord
  CacheError.swift           # Public error enum
  CacheState.swift           # Actor: in-memory state + readiness signaling
  TaskScheduler.swift        # Actor: debounced Task slots (eviction, index persist)
  DiskOperations.swift       # Static helpers: atomic write, moveToTmp, ensureDir, read
  IndexSerializer.swift      # JSON encode/decode for index.json
  LRUFileCache.swift         # Public API class, coordinates I/O + actors
Tests/LRUFileCacheTests/
  LRUFileCacheTests.swift    # Integration: full API + restart round-trips
  CacheStateTests.swift      # Unit: eviction candidate logic, readiness signaling
  DiskOperationsTests.swift  # Unit: atomic write, moveToTmp collision handling
```

---

## Key Types

### `CacheConfiguration` (struct, Sendable)
```swift
public struct CacheConfiguration: Sendable {
    public let name: String
    public let maxEntryCount: Int
    public let maxTotalByteSize: Int
    public let evictionDebounceInterval: Duration
    public let fileProtectionClass: FileProtectionType
}
```

### `CacheEntry` (internal struct)
```swift
struct CacheEntry {
    let key: String
    var filename: String       // UUID-based, not key-derived (safe, collision-free)
    var byteSize: Int
    var lastAccessedDate: Date
}
```
Persisted as `CacheEntryRecord: Codable` in `index.json`.

### `CacheError` (public enum)
```swift
public enum CacheError: Error, Sendable {
    case keyNotFound(String)
    case invalidCacheName(String)
    case writeFailed(underlying: Error)
    case readFailed(underlying: Error)
}
// indexCorrupted is caught internally — never surfaced to callers
```

---

## `CacheState` Actor

Holds all mutable in-memory state. Readiness signaling via stored continuations (one-shot broadcast):

```swift
func waitForReady() async        // suspends until markReady called; returns immediately after
func markReady(with: [CacheEntry])  // called once from background init task
func insert(_ entry: CacheEntry)
func remove(key: String) -> CacheEntry?
func entry(for key: String) -> CacheEntry?
func updateAccessDate(for key: String, to date: Date)
func allEntries() -> [CacheEntry]
// Eviction: sort by lastAccessedDate ASC, pop LRU until within both limits
func entriesExceeding(maxCount: Int, maxSize: Int) -> [CacheEntry]
```

---

## `TaskScheduler` Actor

Two debounced slots. Cancel previous task, create new one with sleep:

```swift
func scheduleEviction(debounce: Duration, work: @escaping @Sendable () async -> Void)
func scheduleIndexPersist(debounce: Duration, work: @escaping @Sendable () async -> Void)
func cancelAll()
```

Pattern:
```swift
slot?.cancel()
slot = Task {
    try? await Task.sleep(for: debounce)
    guard !Task.isCancelled else { return }
    await work()
}
```

---

## `DiskOperations` (static functions)

- **`atomicWrite(data:to:fileProtection:)`** — write to `.<uuid>.tmp` sibling, then `FileManager.replaceItem(at:withItemAt:)` (atomic rename on APFS/HFS+)
- **`moveToTmp(url:)`** — move to `FileManager.default.temporaryDirectory`; on name collision append UUID suffix
- **`ensureDirectory(at:fileProtection:)`** — `createDirectory(withIntermediateDirectories: true)` + protection attribute
- **`readFile(at:)`** — returns `Data?`; ENOENT → `nil`, other errors → throw `readFailed`

---

## `IndexSerializer` (static)

JSON format with `version` field, ISO 8601 dates. Decode failure → throw (caught by caller, degrades to empty cache). Index file itself written via `atomicWrite`.

---

## `LRUFileCache` Public Class

```
<Application Support>/LRUFileCache/<config.name>/
  index.json
  <uuid1>   (data files, UUID filenames)
  <uuid2>
  ...
```

**Init** (synchronous):
1. Validate `config.name` (non-empty, no `/`), throw `invalidCacheName` if bad
2. Compute paths, create `CacheState` + `TaskScheduler`
3. Fire `Task { await self.loadIndex() }` — returns immediately

**`loadIndex()`** (private async):
1. `ensureDirectory`
2. Read + parse `index.json`; on any error → `state.markReady(with: [])` (graceful degradation)
3. Self-heal: for each parsed entry, verify file exists on disk; drop missing entries
4. `state.markReady(with: healedEntries)`

**All public methods** begin with `await state.waitForReady()`.

### Operation flow

| Op | Key check | Write file | State update | Index persist | Eviction |
|---|---|---|---|---|---|
| `add`/`update` | — | atomic write | upsert | immediate | debounced |
| `modify` | absent → throw | atomic write | update | immediate | debounced |
| `get` (hit) | — | — | updateAccessDate | debounced | — |
| `get` (miss on disk) | — | — | remove | immediate | — |
| `get` (not in index) | — | — | — | — | — |
| `promote` | absent → throw | — | updateAccessDate | debounced | — |
| eviction | — | moveToTmp | remove | immediate | — |

For `add` with existing key: write new file first (new UUID), then move old file to tmp, then update state. No window where data is absent.

**`persistIndexImmediately()`** (private):
1. `ensureDirectory` (handles externally-deleted cache dir)
2. Snapshot entries from `state`
3. `IndexSerializer.encode` → `DiskOperations.atomicWrite` to `indexURL`

**Eviction** (runs in debounced task):
```
candidates = await state.entriesExceeding(maxCount:maxSize:)
for each: state.remove → DiskOperations.moveToTmp (best-effort, non-fatal)
if any removed: persistIndexImmediately()
```

---

## Concurrency Model

`LRUFileCache` is `Sendable` — all stored properties are `Sendable` (value types or actors). No `DispatchQueue`, no `NSLock`. All synchronization via actor isolation. `DiskOperations` are free functions on the cooperative thread pool.

---

## Verification

1. `swift build` — no warnings
2. `swift test` — all tests pass
3. Integration test: create cache, `add` 3 entries, re-init, verify all 3 readable
4. Integration test: exceed `maxEntryCount`, verify LRU entry evicted (file moved to tmp)
5. Integration test: corrupt `index.json`, re-init, verify empty cache (no crash)
6. Integration test: `modify`/`promote` on absent key → `keyNotFound` thrown
7. Integration test: delete cache directory externally, call `add`, verify directory recreated and entry readable
