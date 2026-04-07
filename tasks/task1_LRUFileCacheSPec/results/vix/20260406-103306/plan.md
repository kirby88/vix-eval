## Implementation Plan: LRU File Cache in Swift

### Overview

This is a greenfield Swift package. The workspace has no existing source files, so we will create a Swift Package Manager library target with no external dependencies. The design uses a single actor for all in-memory state to avoid data races, a background-dispatched eviction task, and a debounced index flush for read-path access updates.

---

### Architecture Decisions

**Concurrency model**: A Swift `actor` (`DiskCache`) serializes all access to the in-memory index. This eliminates the need for manual locking and integrates cleanly with Swift's structured concurrency. The public API is `async`.

**Index representation**: A `[String: CacheEntry]` dictionary keyed by the user-supplied key. Each entry holds the filename on disk, byte size, and last-accessed timestamp. On init, the actor loads the index asynchronously (off the calling context) via a `Task` before surfacing availability, but the actor itself is immediately usable — reads during index load return nil, writes proceed and will be reconciled.

Actually, per the "Fast start: cache must be usable immediately after init with no blocking I/O on the hot path" requirement, init is synchronous and non-blocking. The index load is kicked off as a detached background `Task` inside `init`. A simple `isReady` flag (actor-isolated) gates nothing — the index simply starts empty and is populated by the background task. This is the correct interpretation: operations before the index loads behave as if the cache is empty, which is safe.

**Eviction**: Triggered after every mutation. A debounce mechanism (a stored `Task` that is cancelled and re-created) defers eviction by the configured interval. Eviction moves excess files to `FileManager.default.temporaryDirectory`, handling collisions by appending a UUID suffix when a filename already exists in `tmp/`.

**Debounced index flush for reads**: Same debounce pattern — a separate stored `Task` for read-path flushes. Mutations cancel the debounced task and write immediately.

**Atomic writes**: Use `FileManager` `replaceItemAt` or write to a temp file then rename via `FileManager.moveItem`, which is atomic on the same volume. Specifically: write `Data` to a temp path in the cache directory, then `try FileManager.default.moveItem(at: tmpURL, to: finalURL)`. On iOS, writing to the same volume guarantees atomicity of the rename.

**Multiple named caches**: `DiskCache` is a standalone actor. Callers create as many instances as they need, each with its own `CacheConfiguration`. No shared global state.

**Data protection**: Set on the directory using `FileManager.default.setAttributes([.protectionKey: config.dataProtection], ofItemAtPath:)` when creating the cache directory.

---

### File Structure

```
/workspace/
  Package.swift
  Sources/
    DiskCache/
      CacheConfiguration.swift
      CacheEntry.swift
      CacheError.swift
      DiskCache.swift
  Tests/
    DiskCacheTests/
      DiskCacheTests.swift
```

---

### Step-by-Step Implementation

#### Step 1: `Package.swift`

Standard SPM manifest. One library target `DiskCache`, one test target `DiskCacheTests` depending on `DiskCache`. Platform minimum `.iOS(.v16)` to ensure Swift concurrency and `actor` support with no back-deployment complexity.

#### Step 2: `CacheConfiguration.swift`

A plain `struct` with no behavior:

```swift
public struct CacheConfiguration {
    public let name: String
    public let maxEntryCount: Int
    public let maxTotalBytes: Int
    public let evictionDebounce: Duration
    public let dataProtection: FileProtectionType
    public init(...)
}
```

`Duration` (Swift 5.7+) is used for `evictionDebounce` to pair naturally with `Task.sleep(for:)`.

#### Step 3: `CacheEntry.swift`

Internal `struct`, `Codable` for persistence:

```swift
struct CacheEntry: Codable {
    let filename: String       // UUID-based, stable after first write
    var byteSize: Int
    var lastAccessed: Date
}
```

The key is stored as the dictionary key in the index, not inside the entry, keeping the entry lean.

#### Step 4: `CacheError.swift`

Public `enum CacheError: Error`:
- `keyNotFound(String)` — thrown by `modify` and `promote` when key is absent
- `fileSystemError(underlying: Error)` — wraps I/O errors

#### Step 5: `DiskCache.swift` — the core

This is the main file. Structure:

**Properties (actor-isolated)**
- `private let config: CacheConfiguration`
- `private let cacheDirectory: URL`
- `private let indexURL: URL`
- `private var index: [String: CacheEntry] = [:]`
- `private var totalBytes: Int = 0`
- `private var evictionTask: Task<Void, Never>?`
- `private var indexFlushTask: Task<Void, Never>?`
- `private var indexLoaded: Bool = false`

**`init(configuration:baseDirectory:)`**

Takes a `CacheConfiguration` and a `baseDirectory: URL` (defaults to `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]`). Computes `cacheDirectory = baseDirectory.appendingPathComponent(config.name)`. Does NOT perform any I/O. Kicks off a detached `Task` that calls `private func loadIndex()`.

**`private func loadIndex()`**

Actor-isolated async method called from the detached init task:
1. Create `cacheDirectory` if needed (also sets data protection attribute)
2. Read `indexURL` data; if file missing, set `indexLoaded = true` with empty index and return
3. Decode `[String: CacheEntry]` from JSON; on any `DecodingError` or other error, log and treat as empty (graceful degradation)
4. Recompute `totalBytes` from loaded entries
5. Set `indexLoaded = true`

**`private func ensureCacheDirectory()`**

Creates `cacheDirectory` including intermediates if it does not exist. Called before every write. Sets data protection class attribute.

**`func add(key: String, data: Data) async throws`**

1. Call `ensureCacheDirectory()`
2. Look up existing entry; if found, note old byte size for accounting
3. Determine `filename`: reuse existing entry's filename if key exists, otherwise generate `UUID().uuidString`
4. Write atomically: write `data` to a temp URL in `cacheDirectory` (e.g. `filename + ".tmp"`), then `FileManager.moveItem` to final URL
5. Update `index[key]` with new `CacheEntry(filename:, byteSize: data.count, lastAccessed: Date())`
6. Update `totalBytes`
7. Call `persistIndexImmediately()`
8. Call `scheduleEviction()`

**`func update(key: String, data: Data) async throws`**

Calls `add(key:data:)`.

**`func modify(key: String, data: Data) async throws`**

1. Guard that `index[key] != nil`, else `throw CacheError.keyNotFound(key)`
2. Delegate to `add(key:data:)` — reuses filename, updates bytes, timestamps

**`func get(key: String) async throws -> Data?`**

1. Guard `index[key] != nil`; return `nil` if absent
2. Resolve `fileURL` from entry filename
3. Attempt `Data(contentsOf: fileURL)` — if throws (file missing), call `selfHeal(key:)` and return `nil`
4. Update `index[key].lastAccessed = Date()`
5. Schedule debounced index flush via `scheduleDebouncedIndexFlush()`
6. Return data

**`func promote(key: String) async throws`**

1. Guard `index[key] != nil`, else `throw CacheError.keyNotFound(key)`
2. Update `index[key].lastAccessed = Date()`
3. Schedule debounced index flush

**`private func selfHeal(key: String)`**

Removes `index[key]`, adjusts `totalBytes`, calls `persistIndexImmediately()`.

**`private func persistIndexImmediately()`**

Cancels `indexFlushTask`. Encodes `index` to JSON, writes atomically to `indexURL` (same tmp-then-move pattern).

**`private func scheduleDebouncedIndexFlush()`**

```swift
indexFlushTask?.cancel()
indexFlushTask = Task {
    try? await Task.sleep(for: config.evictionDebounce)
    guard !Task.isCancelled else { return }
    persistIndexImmediately()
}
```

**`private func scheduleEviction()`**

```swift
evictionTask?.cancel()
evictionTask = Task {
    try? await Task.sleep(for: config.evictionDebounce)
    guard !Task.isCancelled else { return }
    await evict()
}
```

**`private func evict()`**

1. Compute whether eviction is needed: `index.count > config.maxEntryCount || totalBytes > config.maxTotalBytes`
2. Sort entries by `lastAccessed` ascending (oldest first)
3. Remove entries until both constraints satisfied
4. For each removed entry: move file to `FileManager.default.temporaryDirectory`. Collision handling: check if destination exists; if so, append `"-" + UUID().uuidString` before the extension (or just as suffix)
5. Update `index` and `totalBytes`
6. Call `persistIndexImmediately()`

---

### Key Design Notes

**Why actor over DispatchQueue + lock**: The `actor` model guarantees exclusive access to all stored properties with no manual synchronization. It is the idiomatic Swift 5.5+ solution and eliminates a class of bugs.

**Why the index loads in the background**: The requirement explicitly states no blocking I/O on the hot path at init time. The consequence is that calls made before the background load completes see an empty cache, which is safe — they will not corrupt the index that is being loaded because the actor serializes access.

**Why eviction uses tmp/ move instead of delete**: As specified. The move is near-instant (same-volume rename where possible, otherwise copy+delete). The OS eventually clears tmp/.

**Why `modify` delegates to `add` after the key guard**: Code reuse; all write logic (atomic write, index update, byte accounting, persistence, eviction scheduling) lives in one place.

**Debounce for reads vs. immediate for writes**: Write operations (add/modify/eviction) call `persistIndexImmediately()` which also cancels any pending debounced flush. This ensures the index on disk is never stale after a mutation. Read-path updates (get/promote) only schedule a debounced flush, capping write amplification on hot-read workloads.

---

### Critical Files for Implementation

- `/workspace/Package.swift` - SPM manifest defining the library and test targets
- `/workspace/Sources/DiskCache/DiskCache.swift` - Core actor: all cache logic, eviction, index management
- `/workspace/Sources/DiskCache/CacheConfiguration.swift` - Per-cache configuration struct
- `/workspace/Sources/DiskCache/CacheEntry.swift` - Codable index entry model
- `/workspace/Tests/DiskCacheTests/DiskCacheTests.swift` - Tests covering all API methods and edge cases