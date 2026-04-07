# Plan: Distributed Tracing with Context Propagation for Track Cache

## Context

Track is a GCD-based Swift 5 two-tier (memory + disk) LRU cache with no existing observability. The goal is to add distributed tracing: every public method creates a child span under the caller's context (if provided), records structured attributes, async evictions propagate their originating context, and the tracing backend is fully swappable via a protocol.

Concurrency model: concurrent `DispatchQueue` + `DispatchSemaphore`. No Swift actors. Callback-based async.

---

## Files to Create / Modify

| File | Action |
|------|--------|
| `Track/Tracing.swift` | **Create** — all protocol abstractions and no-op implementations |
| `Track/MemoryCache.swift` | **Modify** — add traceContext to all public methods, eviction spans |
| `Track/DiskCache.swift` | **Modify** — add traceContext to all public methods |
| `Track/Cache.swift` | **Modify** — add traceContext, thread context through 3-level async chain |

---

## Step 1 — Create `Track/Tracing.swift`

### Protocols

```swift
public protocol TrackSpanContext: AnyObject {}

public protocol TrackSpan: AnyObject {
    func setAttribute(_ key: String, value: TrackSpanValue)
    func end(outcome: TrackSpanOutcome)
}

// Conforming TrackSpan implementations also conform to this to enable parent-child linking
public protocol TrackSpanContextSource: AnyObject {
    var context: TrackSpanContext? { get }
}

public protocol TrackTracer: AnyObject {
    func startSpan(operation: String, parent: TrackSpanContext?) -> TrackSpan
}
```

### Value and Outcome Types

```swift
public enum TrackSpanValue {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
}

public enum TrackSpanOutcome: String {
    case hit, miss, set, removed, trimmed, evicted, error
}
```

### No-op Implementations (default; zero allocations via shared singletons)

```swift
public final class NoOpSpan: TrackSpan {
    public static let shared = NoOpSpan()
    private init() {}
    public func setAttribute(_ key: String, value: TrackSpanValue) {}
    public func end(outcome: TrackSpanOutcome) {}
}

public final class NoOpTracer: TrackTracer {
    public static let shared = NoOpTracer()
    private init() {}
    public func startSpan(operation: String, parent: TrackSpanContext?) -> TrackSpan { NoOpSpan.shared }
}
```

### Global Configuration

```swift
public final class TrackTracing {
    // Set once at app startup before any cache use. Not locked — write-once contract.
    public static var tracer: TrackTracer = NoOpTracer.shared
}
```

### Operation Name and Attribute Key Constants

```swift
public enum TrackTracingOperation {
    public static let memorySet       = "track.memory_cache.set"
    public static let memoryGet       = "track.memory_cache.get"
    public static let memoryRemove    = "track.memory_cache.remove"
    public static let memoryRemoveAll = "track.memory_cache.remove_all"
    public static let memoryTrimCount = "track.memory_cache.trim.count"
    public static let memoryTrimCost  = "track.memory_cache.trim.cost"
    public static let memoryTrimAge   = "track.memory_cache.trim.age"
    public static let diskSet         = "track.disk_cache.set"
    public static let diskGet         = "track.disk_cache.get"
    public static let diskRemove      = "track.disk_cache.remove"
    public static let diskRemoveAll   = "track.disk_cache.remove_all"
    public static let diskTrimCount   = "track.disk_cache.trim.count"
    public static let diskTrimCost    = "track.disk_cache.trim.cost"
    public static let diskTrimAge     = "track.disk_cache.trim.age"
    public static let cacheSet        = "track.cache.set"
    public static let cacheGet        = "track.cache.get"
    public static let cacheRemove     = "track.cache.remove"
    public static let cacheRemoveAll  = "track.cache.remove_all"
}

public enum TrackTracingAttribute {
    public static let cacheName       = "cache.name"
    public static let cacheKey        = "cache.key"
    public static let cacheOutcome    = "cache.outcome"        // set by end(outcome:)
    public static let objectBytes     = "cache.object_bytes"
    public static let totalCostBytes  = "cache.total_cost_bytes"
    public static let evictionTrigger = "cache.eviction_trigger" // "memory_warning" | "app_background"
    public static let trimLimit       = "cache.trim_limit"
    public static let trimType        = "cache.trim_type"        // "count" | "cost" | "age"
}
```

---

## Step 2 — Core GCD Context-Propagation Pattern

**Key rule**: pass context explicitly via closure capture, never via thread-local or queue-specific storage. Each async block captures its own `span` reference — no sharing between concurrent operations.

```swift
// Pattern for every async method:
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         traceContext: TrackSpanContext? = nil,
         completion: MemoryCacheAsyncCompletion?) {
    // 1. Start span BEFORE dispatch (captures calling context)
    let span = TrackTracing.tracer.startSpan(operation: TrackTracingOperation.memorySet, parent: traceContext)
    // 2. Dispatch; capture span (not traceContext) by reference in the block
    _queue.async { [weak self, span] in
        guard let strongSelf = self else {
            span.end(outcome: .error)
            completion?(nil, key, object)
            return
        }
        strongSelf.set(object: object, forKey: key, cost: cost) // calls sync (no span)
        span.setAttribute(TrackTracingAttribute.cacheName, value: .string("memory"))
        span.setAttribute(TrackTracingAttribute.cacheKey, value: .string(key))
        span.setAttribute(TrackTracingAttribute.objectBytes, value: .int(Int(cost)))
        span.setAttribute(TrackTracingAttribute.totalCostBytes, value: .int(Int(strongSelf.totalCost)))
        span.end(outcome: .set)
        completion?(strongSelf, key, object)
    }
}
```

For sync methods the pattern is simpler — start span, lock, work, capture metrics, unlock, set attributes, end span.

---

## Step 3 — Modify `MemoryCache.swift`

### Signature Changes

Add `traceContext: TrackSpanContext? = nil` to **all** public methods:

- **Async**: insert before `completion:` parameter
- **Sync**: add as the last (defaulted) parameter
- `removeAllObjects(_:)` keeps its unlabeled first param and gains `traceContext:` after it — **no source break**: `removeAllObjects(_ completion: MemoryCacheAsyncCompletion?, traceContext: TrackSpanContext? = nil)`

### Async methods
Each starts a span before dispatch, captures `span` in the block, sets attributes, ends with appropriate outcome. Sync methods called from async blocks do **not** start additional spans — they are the implementation, not the API surface.

### Sync methods
Start span → `_lock()` → work → capture metrics (cost, count) → `_unlock()` → set attributes → `span.end(outcome:)`.

For `object(forKey:)` sync: the found object's cost is available as `_cache.object(forKey: key)?.cost` (type is `MemoryCacheObject`) — capture inside the lock.

### System Event Evictions

The notification handlers (`_didReceiveMemoryWarningNotification`, `_didEnterBackgroundNotification`) currently call `removeAllObjects(nil)`. Change them to:
1. Add a private `_removeAllObjectsInternal()` that does just the lock/clear work without creating a span
2. Notification handlers create **root spans** (parent: nil) with `cache.eviction_trigger` attribute and outcome `.evicted`, dispatch a block that calls `_removeAllObjectsInternal()`, then ends the span

This avoids double-spanning and correctly marks these as evictions vs. explicit removes.

---

## Step 4 — Modify `DiskCache.swift`

Same pattern as MemoryCache. Key specifics:

- **`set` sync**: `fileSize` is computed inside the lock from `URLResourceKey.totalFileAllocatedSizeKey`. Capture it as a local `var fileSize: UInt = 0` and also `let totalCostAfter = _cache.cost` before `_unlock()`. Set `cache.object_bytes` and `cache.total_cost_bytes` after unlock.

- **`object` sync**: `_unsafeObject(forKey:)` is called inside the lock. Capture `objectCost = _cache.object(forKey: key)?.cost ?? 0` (where `DiskCacheObject` is accessible since it's in the same file) inside the lock for the `cache.object_bytes` attribute.

- **`trim` sync methods**: The `countLimit == 0` / `costLimit == 0` / `ageLimit <= 0` paths call `removeAllObjects()`. Add a private `_removeAllObjectsSync()` that does the work directly, and have these paths call it — avoids a nested span under the trim span.

- **`removeAllObjects`**: same signature approach as MemoryCache (`_ completion:` keeps unlabeled, `traceContext:` added after).

---

## Step 5 — Modify `Cache.swift`

### Signature Changes

Add `traceContext: TrackSpanContext? = nil` to all public methods. `removeAllObjects` same treatment.

### `Cache.set` (sync)

```swift
func set(object: NSCoding, forKey key: String, traceContext: TrackSpanContext? = nil) {
    let span = TrackTracing.tracer.startSpan(operation: TrackTracingOperation.cacheSet, parent: traceContext)
    let childCtx = (span as? TrackSpanContextSource)?.context
    memoryCache.set(object: object, forKey: key, traceContext: childCtx)
    diskCache.set(object: object, forKey: key, traceContext: childCtx)
    span.setAttribute(TrackTracingAttribute.cacheName, value: .string(name))
    span.setAttribute(TrackTracingAttribute.cacheKey, value: .string(key))
    span.end(outcome: .set)
}
```

### `Cache.object(forKey:)` async — 3-level context chain

This is the most complex propagation. The `Cache` span starts before the outer dispatch; its context is passed as parent to both `memoryCache.object` and `diskCache.object` child calls. The cache-level span ends **once**, inside whichever completion fires last:

```swift
func object(forKey key: String, traceContext: TrackSpanContext? = nil, completion: CacheAsyncCompletion?) {
    let span = TrackTracing.tracer.startSpan(operation: TrackTracingOperation.cacheGet, parent: traceContext)
    let childCtx = (span as? TrackSpanContextSource)?.context

    _queue.async { [weak self, span, childCtx] in
        guard let strongSelf = self else { span.end(outcome: .error); return }

        strongSelf.memoryCache.object(forKey: key, traceContext: childCtx) { [weak self, span, childCtx] (_, memKey, memObject) in
            guard let strongSelf = self else { span.end(outcome: .error); return }
            if memObject != nil {
                span.setAttribute(...name...) ; span.setAttribute(...key...)
                span.end(outcome: .hit)
                strongSelf._queue.async { [weak self] in completion?(self, memKey, memObject) }
            } else {
                strongSelf.diskCache.object(forKey: key, traceContext: childCtx) { [weak self, span, childCtx] (diskCache, diskKey, diskObject) in
                    guard let strongSelf = self else { span.end(outcome: .error); return }
                    if let dk = diskKey, let dc = diskCache {
                        strongSelf.memoryCache.set(object: dc, forKey: dk, traceContext: childCtx, completion: nil)
                    }
                    span.setAttribute(...name...) ; span.setAttribute(...key...)
                    span.end(outcome: diskObject != nil ? .hit : .miss)
                    strongSelf._queue.async { [weak self] in completion?(self, diskKey, diskObject) }
                }
            }
        }
    }
}
```

The `span` is captured by reference in each nested closure but is ended **exactly once** — at the memory-hit branch or at the disk-result branch. No leak: each concurrent call has its own `span` and `childCtx` captured independently.

---

## Private Helpers Summary

| Helper | Class | Purpose |
|--------|-------|---------|
| `_removeAllObjectsInternal()` | `MemoryCache` | Lock/clear without a span, used by eviction handlers |
| `_removeAllObjectsSync()` | `DiskCache` | Lock/clear without a span, used by trim zero-limit paths |

---

## Attribute Reference

| Key | Type | Methods |
|-----|------|---------|
| `cache.name` | string | all |
| `cache.key` | string | set, get, remove |
| `cache.object_bytes` | int | set (cost/file size), get (found object's cost) |
| `cache.total_cost_bytes` | int | set, trim, removeAll |
| `cache.eviction_trigger` | string | memory/background event spans |
| `cache.trim_limit` | int/double | trim spans |
| `cache.trim_type` | string | trim spans ("count"/"cost"/"age") |

---

## Verification

### SpyTracer (test helper, not shipped)

```swift
class SpySpan: TrackSpan, TrackSpanContextSource {
    let operation: String; let parent: TrackSpanContext?
    var attributes: [String: TrackSpanValue] = [:]
    var endedOutcome: TrackSpanOutcome?
    var context: TrackSpanContext? { SpyContext() }
    func setAttribute(_ key: String, value: TrackSpanValue) { attributes[key] = value }
    func end(outcome: TrackSpanOutcome) { endedOutcome = outcome }
}
class SpyTracer: TrackTracer {
    var spans: [SpySpan] = []
    func startSpan(operation: String, parent: TrackSpanContext?) -> TrackSpan {
        let s = SpySpan(operation: operation, parent: parent); spans.append(s); return s
    }
}
```

### Test Cases

1. **`memorySet`** → 1 span, operation = `track.memory_cache.set`, outcome = `.set`, `cache.key` correct
2. **`memoryGet` hit** → outcome = `.hit`, `cache.object_bytes` > 0
3. **`memoryGet` miss** → outcome = `.miss`
4. **`diskSet`** → `cache.object_bytes` = actual file size (non-zero)
5. **`Cache.object` disk-hit** → 3 spans (cache, memory, disk); all share same parent lineage; memory = `.miss`, disk = `.hit`, cache = `.hit`
6. **Concurrent operations do not cross-contaminate** → two concurrent `memoryCache.object` calls with distinct contexts; each span's parent is the corresponding context
7. **Memory warning eviction** → post `UIApplication.didReceiveMemoryWarningNotification`; a span appears with `cache.eviction_trigger = "memory_warning"`, parent = nil, outcome = `.evicted`
8. **NoOpTracer** → zero spans created, zero heap allocations (measure block passes)
9. **Span always ends** → no early-return path (guard let failure) leaves a span open; verify via deinit assert on spy span

### SDK Integration Example (not part of the library)

```swift
// AppDelegate:
TrackTracing.tracer = MyOpenTelemetryTrackTracer()

// Usage:
let ctx = MyOtelContextAdapter(tracer.activeSpan.context)
Cache.shareInstance.object(forKey: "img_123", traceContext: ctx) { _, _, obj in ... }
```
