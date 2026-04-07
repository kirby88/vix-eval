# LRU Disk Cache — Swift Implementation Plan

## Context

Greenfield iOS Swift Package implementing a disk-backed LRU file cache. The workspace is empty. The cache must support multiple independent named instances, survive restarts, evict asynchronously without blocking callers, and expose a clear async/throws API. All requirements come from the spec in the conversation.

---

## Package Structure

```
DiskCache/
├── Package.swift
├── Sources/DiskCache/
│   ├── DiskCache.swift           # Public facade (struct, Sendable)
│   ├── CacheConfiguration.swift  # Config value type + DataProtectionClass enum
│   ├── CacheError.swift          # Public error enum
│   ├── CacheActor.swift          # Internal actor — owns all mutable state
│   ├── CacheIndex.swift          # In-memory index (value type) + Codable snapshot
│   ├── CacheEntry.swift          # Per-entry metadata (Codable struct)
│   ├── AtomicWriter.swift        # Static helper: write-to-tmp + rename
│   ├── Debouncer.swift           # Generic actor-based debounce
│   └── FileProtectionMapper.swift # Maps DataProtectionClass → URLFileProtection
└── Tests/DiskCacheTests/
    ├── DiskCacheTests.swift       # Core API tests
    ├── EvictionTests.swift        # LRU ordering + eviction tests
    ├── PersistenceTests.swift     # Index survives restart + corruption recovery
    ├── ConcurrencyTests.swift     # Race safety
    ├── AtomicWriterTests.swift    # Atomic write correctness
    └── Helpers/TestCacheFactory.swift
```

**`Package.swift`**: swift-tools-version 5.9, platform iOS 16+, strict concurrency enabled, one library target + one test target.

---

## On-Disk Layout (per cache named `<N>`)

```
<AppSupport>/DiskCache/<N>/
├── index.json      # Persisted LRU index
└── entries/
    └── <16-hex>    # Raw payload, named SHA-256(key).prefix(16)
```

Evicted files move to `FileManager.temporaryDirectory/<filename>-<UUID>` (UUID prevents collisions).

---

## Types

### `CacheConfiguration` (public struct, Sendable)
- `name: String`
- `maxEntryCount: Int` (0 = unlimited)
- `maxTotalBytes: Int` (0 = unlimited)
- `evictionDebounceInterval: TimeInterval` (default 2.0)
- `indexSaveDebounceInterval: TimeInterval` (default 5.0)
- `dataProtectionClass: DataProtectionClass` (default `.completeUnlessOpen`)

### `DataProtectionClass` (public enum, Sendable)
`.none | .complete | .completeUnlessOpen | .completeUntilFirstUserAuthentication`

### `CacheError` (public enum: Error)
`.keyNotFound(String) | .fileSystemError(Error) | .atomicWriteFailed(Error) | .directoryCreationFailed(Error) | .indexCorrupted`

### `CacheEntry` (internal struct, Codable, Sendable)
`key, filename, fullHash, byteSize: Int, lastAccessedDate: Date, insertedDate: Date`

### `CacheIndex` (internal struct, Sendable)
- Owns `[String: CacheEntry]` + `totalBytes: Int`
- `mutating insert/remove/touch`
- `entriesSortedByLRU() -> [CacheEntry]` (ascending lastAccessedDate)
- `needsEviction(config:) -> Bool`
- Serializes via `CacheIndexSnapshot` (versioned Codable wrapper, version=1)

### `CacheActor` (internal actor)
Owns: `index: CacheIndex`, `config`, `cacheDir`, `indexURL`, `evictionDebouncer`, `indexSaveDebouncer`

Public-forwarded methods: `add`, `update`, `modify`, `get`, `promote`

Private helpers: `writeEntry`, `readPayload`, `runEviction`, `persistIndex(immediate:)`, `ensureDirectoryExists`, `moveToTmp`

### `DiskCache` (public struct, Sendable)
Thin pass-through holding a `CacheActor` reference. All methods `async throws`. `init(configuration:)` is `async throws` (loads index).

### `AtomicWriter` (internal struct)
```swift
static func write(_ data: Data, to: URL, protection: URLFileProtection) throws
```
Algorithm: write to sibling `.tmp` file → set protection attributes → `FileManager.moveItem` (POSIX rename, atomic same-volume).

### `Debouncer` (internal actor)
Cancels prior `Task`, schedules new `Task.sleep` + work closure. `fireNow()` cancels pending task (used before immediate saves).

---

## Key Algorithms

### Init (Fast Start)
1. Derive `cacheDir` + `indexURL` from config name
2. Attempt decode of `index.json`; on missing/corrupt → empty `CacheIndex` (no throw)
3. Create debouncer instances
4. Return — no blocking I/O after init completes

### `add` / `update`
1. `ensureDirectoryExists()`
2. Compute SHA-256(key); derive filename (first 16 hex chars)
3. `AtomicWriter.write` to `entries/<filename>`
4. `index.insert(entry)` (upsert — replaces if key exists)
5. `persistIndex(immediate: true)` + cancel indexSaveDebouncer
6. Schedule eviction debouncer

### `modify`
Same as `add` but step 4 checks key exists first — throws `.keyNotFound` if absent.

### `get`
1. Look up entry in index → nil if absent
2. Read file from `entries/<filename>`; if file missing → remove from index, `persistIndex(immediate: true)`, return nil
3. `index.touch(key, date: .now)`
4. Schedule `indexSaveDebouncer`
5. Return data

### `promote`
1. Look up entry → throw `.keyNotFound` if absent
2. `index.touch(key, date: .now)`
3. Schedule `indexSaveDebouncer`

### Eviction (`runEviction`)
1. Check `index.needsEviction(config:)` → return if not needed
2. `index.entriesSortedByLRU()` (ascending = LRU first)
3. Walk from index 0, collect entries to evict until both constraints satisfied
4. For each: `moveToTmp` → `index.remove`
5. `persistIndex(immediate: true)`

### `moveToTmp(entry:)`
`FileManager.moveItem(at: cacheDir/<filename>, to: tmp/<filename>-<UUID>)`. Ignore `NSFileNoSuchFileError` silently.

### Index Persistence
- **Immediate** (mutations + eviction): serialize `CacheIndex` to JSON, `AtomicWriter.write` to `indexURL`, cancel `indexSaveDebouncer`
- **Debounced** (get/promote): `indexSaveDebouncer.schedule { persistIndex(immediate: false) }`

### Directory Recreation
`ensureDirectoryExists()` called at the top of every write. Creates `entries/` dir with protection attributes if absent.

---

## Concurrency Model

- `CacheActor` serial executor serializes all state mutations — no locks needed
- `Debouncer` is also an actor; hop cost is negligible
- Both debouncers run on the cooperative thread pool via `Task.sleep + cancel`
- File I/O runs on the actor's executor; acceptable for single-app workloads
- All public types conform to `Sendable`

---

## Index JSON Schema

```json
{
  "version": 1,
  "entries": [
    {
      "key": "https://example.com/img.png",
      "filename": "a3f1b2c4d5e6f708",
      "fullHash": "<64 hex chars>",
      "byteSize": 204800,
      "lastAccessedDate": 756864000.0,
      "insertedDate": 756777600.0
    }
  ]
}
```

Dates as `TimeInterval` (seconds since reference date). Unknown `version` → graceful empty-cache fallback.

---

## Test Strategy

**Framework**: Swift Testing (Swift 5.9+)

`TestCacheFactory`: creates caches in unique temp subdirs, with debounce intervals set to `0` to eliminate async delays in tests.

| File | Coverage |
|---|---|
| `DiskCacheTests` | add/get/update/modify/promote happy paths + error cases |
| `EvictionTests` | LRU ordering, count/byte limits, evicted files in tmp, rapid-insert debounce |
| `PersistenceTests` | Reinit restores index, corrupt JSON degrades to empty, missing index degrades to empty |
| `ConcurrencyTests` | Concurrent adds don't corrupt totalBytes; concurrent get+add no torn reads |
| `AtomicWriterTests` | Write produces correct file; failure leaves no tmp artifact; overwrite is atomic |

Each test uses a UUID-named cache for full isolation.

---

## Verification

```bash
# Build
swift build

# Run all tests
swift test

# Verify no data races (if available)
swift test --sanitize thread
```

Functional smoke test: init cache, add 3 entries, reinit from same directory, verify all 3 accessible, verify LRU entry evicted after adding beyond maxEntryCount.
