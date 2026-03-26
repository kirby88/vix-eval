Now I have a precise understanding of the entire codebase. Here is the implementation plan.

---

## Implementation Plan: Distributed Tracing with Context Propagation

### Overview of Design Decisions

**Backend abstraction via protocol:** The library defines its own `TraceSpan` and `Tracer` protocols in a new file. No import of any third-party SDK appears anywhere in the library. Callers supply a conforming object. A no-op default is provided so callers who do not care pay zero overhead.

**Context propagation across `DispatchQueue.async` hops:** The library uses raw `DispatchQueue.async` dispatches (not Swift concurrency). Swift task-local values do not propagate across `DispatchQueue.async` boundaries. The correct mechanism for this concurrency model is to capture a `TraceContext?` value in the closure at the call site, before the dispatch, and thread it explicitly into every internal function that needs it. This is the only reliable way to prevent cross-operation leakage on a concurrent queue where multiple unrelated closures may be executing simultaneously.

**No public API signature changes for `completion` callbacks:** Rather than changing the completion callback signatures (which would be a breaking API change), context is passed as an additional `traceContext` parameter with a default of `nil` on every public method. Existing call sites that pass no context compile unchanged. This is the cleanest backwards-compatible extension.

**Span lifecycle:** Each public method that accepts a `traceContext` asks the injected tracer to start a child span at the very start of the operation (before any queue hop) and ends it in the same logical scope where the operation completes. For async methods, the span is ended inside the dispatch closure, after the operation, before the completion callback is invoked.

**Eviction span propagation:** Eviction is triggered inline within `set` operations (both sync and async). Because `_unsafeTrim` variants are called while already inside the operation's span scope, the eviction span becomes a child of that same span. No separate background dispatch is introduced for eviction — it is synchronous within the semaphore-held region. The `traceContext` carrying the parent span is passed explicitly to the trim helpers so they can create eviction child spans.

**Attribute names as constants:** All span attribute key strings are constants defined once in `Tracing.swift` to avoid stringly-typed scatter.

---

### Step 1: Create `/workspace/Track/Tracing.swift`

This new file contains the entire tracing abstraction. It must be created before any other file is modified.

#### 1a. `SpanOutcome` enum

```swift
public enum SpanOutcome: String {
    case hit       = "hit"
    case miss      = "miss"
    case set       = "set"
    case removed   = "removed"
    case evicted   = "evicted"
    case trimmed   = "trimmed"
}
```

#### 1b. `TraceSpan` protocol

```swift
public protocol TraceSpan: AnyObject {
    func setAttribute(key: String, value: String)
    func setAttribute(key: String, value: UInt)
    func end()
}
```

`AnyObject` constraint is required so the protocol can be stored and passed without value-type copying semantics.

#### 1c. `Tracer` protocol

```swift
public protocol Tracer: AnyObject {
    /// Start a child span under `context`, or a root span if context is nil.
    func startSpan(named name: String, context: TraceContext?) -> TraceSpan
}
```

#### 1d. `TraceContext` value type

`TraceContext` is a lightweight value type that wraps a `TraceSpan`. It is captured by value in closures, which is exactly what prevents leakage: each closure captures its own copy of the context that was current when the async dispatch was scheduled.

```swift
public struct TraceContext {
    public let span: TraceSpan
    public init(span: TraceSpan) { self.span = span }
}
```

#### 1e. No-op implementations

```swift
final class NoOpSpan: TraceSpan {
    func setAttribute(key: String, value: String) {}
    func setAttribute(key: String, value: UInt) {}
    func end() {}
}

final class NoOpTracer: Tracer {
    static let shared = NoOpTracer()
    func startSpan(named name: String, context: TraceContext?) -> TraceSpan {
        return NoOpSpan()
    }
}
```

#### 1f. Span attribute key constants

```swift
enum TraceAttribute {
    static let cacheName  = "cache.name"
    static let cacheKey   = "cache.key"
    static let outcome    = "cache.outcome"
    static let byteSize   = "cache.byte_size"
    static let layer      = "cache.layer"     // "memory" or "disk"
}
```

#### 1g. `_withSpan` helper (internal, not public)

A convenience function used by all instrumented methods so span open/close boilerplate is not repeated inline:

```swift
@discardableResult
func _withSpan<R>(
    tracer: Tracer,
    named operationName: String,
    context: TraceContext?,
    body: (TraceSpan) -> R
) -> R {
    let span = tracer.startSpan(named: operationName, context: context)
    let result = body(span)
    span.end()
    return result
}
```

This helper is used for sync code paths. For async paths, the span is managed manually (open before dispatch, close inside the block) to cover the full async operation lifetime.

---

### Step 2: Add `tracer` property to `MemoryCache`

In `/workspace/Track/MemoryCache.swift`, add a single stored property to the `MemoryCache` class:

```swift
/// Inject a Tracer to enable distributed tracing. Defaults to the no-op tracer.
public var tracer: Tracer = NoOpTracer.shared
```

This property is set after construction, so it must be `var`, not `let`. It does not need lock protection because it is set once before the cache is used (it is acceptable to document this usage contract).

---

### Step 3: Instrument all public methods on `MemoryCache`

Every public method in the `public extension MemoryCache` block gains an additional `traceContext: TraceContext? = nil` parameter. The default `nil` preserves all existing call sites.

**Async `set`:**

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         traceContext: TraceContext? = nil,
         completion: MemoryCacheAsyncCompletion?) {
    let span = tracer.startSpan(named: "MemoryCache.set", context: traceContext)
    span.setAttribute(key: TraceAttribute.cacheName, value: name ?? "memory")
    span.setAttribute(key: TraceAttribute.cacheKey, value: key)
    span.setAttribute(key: TraceAttribute.layer, value: "memory")
    let capturedContext = TraceContext(span: span)
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.miss.rawValue)
            span.end()
            completion?(nil, key, object)
            return
        }
        strongSelf._instrumentedSet(object: object, forKey: key, cost: cost,
                                    span: span, evictionContext: capturedContext)
        span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.set.rawValue)
        span.end()
        completion?(strongSelf, key, object)
    }
}
```

Key observations:
- The span is opened **before** the dispatch so it captures the caller's context.
- `capturedContext` wraps the new span so eviction triggered inside the sync `set` can create child spans under it.
- The span is ended **inside** the async block after the work finishes, so it measures the true async duration.
- The `completion` is called after `span.end()`.

**Sync `set`:**

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         traceContext: TraceContext? = nil) {
    _withSpan(tracer: tracer, named: "MemoryCache.set", context: traceContext) { span in
        span.setAttribute(key: TraceAttribute.cacheName, value: name ?? "memory")
        span.setAttribute(key: TraceAttribute.cacheKey, value: key)
        span.setAttribute(key: TraceAttribute.layer, value: "memory")
        _lock()
        _unsafeSet(object: object, forKey: key, cost: cost,
                   evictionContext: TraceContext(span: span))
        span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.set.rawValue)
        _unlock()
    }
}
```

**Async and sync `object(forKey:)`:**

```swift
// async
func object(forKey key: String, traceContext: TraceContext? = nil,
            completion: MemoryCacheAsyncCompletion?) {
    let span = tracer.startSpan(named: "MemoryCache.object", context: traceContext)
    span.setAttribute(key: TraceAttribute.cacheName, value: name ?? "memory")
    span.setAttribute(key: TraceAttribute.cacheKey, value: key)
    span.setAttribute(key: TraceAttribute.layer, value: "memory")
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.miss.rawValue)
            span.end()
            completion?(nil, key, nil)
            return
        }
        let obj = strongSelf.object(forKey: key)
        let outcome: SpanOutcome = obj != nil ? .hit : .miss
        span.setAttribute(key: TraceAttribute.outcome, value: outcome.rawValue)
        span.end()
        completion?(strongSelf, key, obj)
    }
}

// sync
func object(forKey key: String, traceContext: TraceContext? = nil) -> AnyObject? {
    var object: AnyObject? = nil
    _withSpan(tracer: tracer, named: "MemoryCache.object", context: traceContext) { span in
        span.setAttribute(key: TraceAttribute.cacheName, value: name ?? "memory")
        span.setAttribute(key: TraceAttribute.cacheKey, value: key)
        span.setAttribute(key: TraceAttribute.layer, value: "memory")
        _lock()
        let memoryObject: MemoryCacheObject? = _cache.object(forKey: key)
        memoryObject?.time = CACurrentMediaTime()
        object = memoryObject?.value
        _unlock()
        let outcome: SpanOutcome = object != nil ? .hit : .miss
        span.setAttribute(key: TraceAttribute.outcome, value: outcome.rawValue)
        if let cost = memoryObject?.cost {
            span.setAttribute(key: TraceAttribute.byteSize, value: cost)
        }
    }
    return object
}
```

**`removeObject`, `removeAllObjects`, all `trim` variants** follow the same pattern: open span before any dispatch, set attributes, close span after work.

---

### Step 4: Thread `evictionContext` through `_unsafeSet` and trim helpers on `MemoryCache`

`_unsafeSet` is the single internal entry point that can trigger eviction. Add a parameter:

```swift
func _unsafeSet(object: AnyObject, forKey key: String, cost: UInt = 0,
                evictionContext: TraceContext? = nil) {
    _cache.set(object: MemoryCacheObject(key: key, value: object, cost: cost), forKey: key)
    if _cache.cost > _costLimit {
        _unsafeTrim(toCost: _costLimit, evictionContext: evictionContext)
    }
    if _cache.count > _countLimit {
        _unsafeTrim(toCount: _countLimit, evictionContext: evictionContext)
    }
}
```

The `_unsafeTrim` helpers become:

```swift
fileprivate func _unsafeTrim(toCount countLimit: UInt, evictionContext: TraceContext? = nil) {
    // existing logic, but each removal creates a child span under evictionContext
    if let ctx = evictionContext {
        let evictSpan = tracer.startSpan(named: "MemoryCache.evict.count", context: ctx)
        evictSpan.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.evicted.rawValue)
        // run existing removal loop
        evictSpan.end()
    } else {
        // run existing removal loop without tracing
    }
}
```

The same pattern applies to `_unsafeTrim(toCost:)` and `_unsafeTrim(toAge:)`.

Note: `_unsafeTrim` for age is triggered only from the `trim(toAge:)` public method, so `evictionContext` there comes from the public method's span.

The existing call from `CacheGenerator.next()` (`_memoryCache._unsafeSet(object:forKey:)`) passes no context, which means it uses the `nil` default — correct, since the generator has no associated trace context.

---

### Step 5: Add `name` property to `MemoryCache`

`MemoryCache` currently has no `name` property. Add one:

```swift
public let name: String

public init(name: String = "memory") {
    self.name = name
    // existing notification observers
}
```

The `shareInstance` continues to work as before, using `"memory"` as its default name.

---

### Step 6: Add `tracer` property to `DiskCache` and instrument its public methods

In `/workspace/Track/DiskCache.swift`, add:

```swift
public var tracer: Tracer = NoOpTracer.shared
```

Every public method follows the same open-before-dispatch, close-after-work pattern established for `MemoryCache`. The `DiskCache` already has `name` and `cacheURL.path` available for attribute values.

**Key difference for `DiskCache.set` — eviction inside the semaphore lock:**

The sync `set` implementation:
1. Acquires the semaphore lock.
2. Writes the file.
3. Reads back file size from filesystem into `DiskCacheObject.cost`.
4. Calls `_unsafeTrim` if limits are exceeded.
5. Releases the lock.

The span for the `set` operation is opened before `_lock()` is called. The `byteSize` attribute is set from `fileSize` after the filesystem query resolves. The eviction context passed to `_unsafeTrim` is a `TraceContext` wrapping this same span.

```swift
func set(object: NSCoding, forKey key: String, traceContext: TraceContext? = nil) {
    guard let fileURL = _generateFileURL(key, path: cacheURL) else { return }
    let filePath = fileURL.path
    let span = tracer.startSpan(named: "DiskCache.set", context: traceContext)
    span.setAttribute(key: TraceAttribute.cacheName, value: name)
    span.setAttribute(key: TraceAttribute.cacheKey, value: key)
    span.setAttribute(key: TraceAttribute.layer, value: "disk")
    let evictionContext = TraceContext(span: span)
    _lock()
    if NSKeyedArchiver.archiveRootObject(object, toFile: filePath) == true {
        do {
            // ... existing date/size logic ...
            span.setAttribute(key: TraceAttribute.byteSize, value: fileSize)
        } catch {}
    }
    span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.set.rawValue)
    if _cache.cost > _costLimit { _unsafeTrim(toCost: _costLimit, evictionContext: evictionContext) }
    if _cache.count > _countLimit { _unsafeTrim(toCount: _countLimit, evictionContext: evictionContext) }
    _unlock()
    span.end()
}
```

Span ends **after** `_unlock()` to cover the full sync duration including eviction.

**Async `DiskCache.set`:**

```swift
func set(object: NSCoding, forKey key: String,
         traceContext: TraceContext? = nil,
         completion: DiskCacheAsyncCompletion?) {
    let span = tracer.startSpan(named: "DiskCache.set", context: traceContext)
    span.setAttribute(key: TraceAttribute.cacheName, value: name)
    span.setAttribute(key: TraceAttribute.cacheKey, value: key)
    span.setAttribute(key: TraceAttribute.layer, value: "disk")
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.miss.rawValue)
            span.end()
            completion?(nil, key, object)
            return
        }
        strongSelf.set(object: object, forKey: key)  // calls sync variant without context
        // attributes already set by sync variant on its own span — but we have the outer span:
        span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.set.rawValue)
        span.end()
        completion?(strongSelf, key, object)
    }
}
```

Wait — there is an important subtlety here. The async variant dispatches to `_queue.async` and then calls the **sync** variant, which will create its **own** child span if a `traceContext` is passed. To avoid double-spanning the same operation, the async variant's span acts as the outer "async dispatch" span, and the sync variant is called with `traceContext: TraceContext(span: span)` so that its span becomes a child. Alternatively, the async variant can call an internal non-tracing sync body directly. The cleaner approach:

**Preferred async-over-sync pattern:** The async method opens a span, passes a `TraceContext` wrapping that span to the sync method. The sync method creates its own child span for the actual I/O work. The outer async span covers total wall time including queue wait time; the inner sync span covers actual execution time.

This is accurate, not redundant, because the async span measures the time from when the caller enqueued the work to when it finished (including queue wait), while the sync span measures pure execution.

---

### Step 7: Instrument `_unsafeTrim` helpers on `DiskCache`

Same pattern as `MemoryCache`: add `evictionContext: TraceContext? = nil` parameter to all three `_unsafeTrim` overloads. Each creates a child span of the passed context, sets `outcome = .evicted`, and ends the span after the removal loop.

---

### Step 8: Add `tracer` and `traceContext` to `Cache` facade

In `/workspace/Track/Cache.swift`, add:

```swift
public var tracer: Tracer = NoOpTracer.shared {
    didSet {
        memoryCache.tracer = tracer
        diskCache.tracer = tracer
    }
}
```

Setting `tracer` on `Cache` automatically propagates it to both sub-caches so callers only need one injection point.

**`Cache` async `object(forKey:)` — the multi-hop case:**

This is the most complex method because it can hop through three async closures:
1. `Cache._queue.async`
2. `memoryCache.object(forKey:completion:)` internally dispatches to `MemoryCache._queue.async`
3. On cache miss, `diskCache.object(forKey:completion:)` dispatches to `DiskCache._queue.async`

The trace context must flow through all three hops without leaking.

The plan:

```swift
func object(forKey key: String,
            traceContext: TraceContext? = nil,
            completion: CacheAsyncCompletion?) {
    let span = tracer.startSpan(named: "Cache.object", context: traceContext)
    span.setAttribute(key: TraceAttribute.cacheName, value: name)
    span.setAttribute(key: TraceAttribute.cacheKey, value: key)
    let outerContext = TraceContext(span: span)
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.miss.rawValue)
            span.end()
            return
        }
        // Pass outerContext as parent so memory cache creates a child span
        strongSelf.memoryCache.object(forKey: key, traceContext: outerContext) { [weak self] (memCache, memKey, memObject) in
            guard let strongSelf = self else { return }
            if memObject != nil {
                span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.hit.rawValue)
                span.end()
                strongSelf._queue.async { [weak self] in
                    completion?(self, memKey, memObject)
                }
            } else {
                // Pass outerContext as parent for disk cache child span
                strongSelf.diskCache.object(forKey: key, traceContext: outerContext) { [weak self] (diskCache, diskKey, diskObject) in
                    guard let strongSelf = self else { return }
                    if let diskKey = diskKey, let diskCache = diskCache {
                        strongSelf.memoryCache.set(object: diskCache, forKey: diskKey, completion: nil)
                    }
                    let outcome: SpanOutcome = diskObject != nil ? .hit : .miss
                    span.setAttribute(key: TraceAttribute.outcome, value: outcome.rawValue)
                    span.end()
                    strongSelf._queue.async { [weak self] in
                        completion?(self, diskKey, diskObject)
                    }
                }
            }
        }
    }
}
```

The outer `Cache.object` span ends in exactly one place (either the memory-hit path or the disk-completion path). The `span` reference is captured by value in all closures — this is safe because it is a class (reference type), and each invocation of `Cache.object` creates a fresh span for that one operation only.

**No leakage guarantee:** `outerContext` is a local variable in the calling thread. It is captured by the closure dispatched to `_queue`. All concurrent operations on `_queue` that were dispatched by unrelated callers capture their own distinct `outerContext` values. There is zero shared mutable state between concurrent operations' trace contexts.

---

### Step 9: Handle `MemoryCache` system notification eviction

The `_didReceiveMemoryWarningNotification` and `_didEnterBackgroundNotification` handlers call `removeAllObjects(nil)`. These are system-initiated events and have no caller trace context. They should produce root spans (no parent), clearly labelled:

```swift
@objc fileprivate func _didReceiveMemoryWarningNotification() {
    if self.autoRemoveAllObjectWhenMemoryWarning {
        let span = tracer.startSpan(named: "MemoryCache.evict.memoryWarning", context: nil)
        span.setAttribute(key: TraceAttribute.cacheName, value: name)
        span.setAttribute(key: TraceAttribute.outcome, value: SpanOutcome.evicted.rawValue)
        removeAllObjects(nil)
        span.end()
    }
}
```

Same for background notification.

---

### Step 10: `DiskCache.init` background work

The `DiskCache.init?(name:path:)` dispatches `_createCacheDir` + `_loadFilesInfo` to `_queue.async` on construction. This is infrastructure work, not a user-facing cache operation. It should emit a root span (no parent):

```swift
public init?(name: String, path: String) {
    // existing guard
    self.name = name
    self.cacheURL = ...
    _lock()
    _queue.async {
        let span = self.tracer.startSpan(named: "DiskCache.init.loadFiles", context: nil)
        span.setAttribute(key: TraceAttribute.cacheName, value: self.name)
        _ = self._createCacheDir()
        _ = self._loadFilesInfo()
        span.end()
        self._unlock()
    }
}
```

At this point `tracer` is still `NoOpTracer.shared` because no one has had a chance to inject a custom tracer yet. This is acceptable: if the caller wants to trace initialisation, they can set `tracer` before the background block completes. However, since the background block runs asynchronously and `tracer` is set after construction returns, the practical approach is to capture the tracer reference at dispatch time. Because `tracer` is initially `NoOpTracer.shared`, this creates no spans until the caller injects a tracer, which will only take effect on subsequent operations.

---

### Step 11: `subscript` methods

The subscript setters/getters on `Cache`, `MemoryCache`, and `DiskCache` delegate entirely to the sync `set`/`object`/`removeObject` methods. Since subscript syntax cannot accept extra parameters, subscripts are left as-is: they call through to the sync methods without a trace context. This is correct — if callers want tracing on subscript-style access, they use the explicit method form. Document this limitation in a comment.

---

### Complete File Change Summary

#### New file: `/workspace/Track/Tracing.swift`

Contains:
- `public enum SpanOutcome`
- `public protocol TraceSpan`
- `public protocol Tracer`
- `public struct TraceContext`
- `final class NoOpSpan: TraceSpan` (internal)
- `final class NoOpTracer: Tracer` (internal, `shared` singleton)
- `internal enum TraceAttribute` (constants)
- `internal func _withSpan(...)` (helper)

#### Modified: `/workspace/Track/MemoryCache.swift`

- Add `public var name: String` stored property and update `init` to accept it.
- Add `public var tracer: Tracer = NoOpTracer.shared`.
- Add `traceContext: TraceContext? = nil` parameter to all 10 public methods (7 async + 3 sync non-subscript).
- Update `_unsafeSet` to accept and pass `evictionContext: TraceContext? = nil`.
- Update `_unsafeTrim(toCount:)`, `_unsafeTrim(toCost:)`, `_unsafeTrim(toAge:)` to accept and use `evictionContext: TraceContext? = nil`.
- Update `_didReceiveMemoryWarningNotification` and `_didEnterBackgroundNotification` to emit root spans.

#### Modified: `/workspace/Track/DiskCache.swift`

- Add `public var tracer: Tracer = NoOpTracer.shared`.
- Add `traceContext: TraceContext? = nil` parameter to all 10 public methods.
- Update `_unsafeTrim(toCount:)`, `_unsafeTrim(toCost:)`, `_unsafeTrim(toAge:)` to accept and use `evictionContext: TraceContext? = nil`.
- Update `init?(name:path:)` to emit a root span around the background `_loadFilesInfo` work.

#### Modified: `/workspace/Track/Cache.swift`

- Add `public var tracer: Tracer = NoOpTracer.shared` with `didSet` that propagates to `memoryCache.tracer` and `diskCache.tracer`.
- Add `traceContext: TraceContext? = nil` to all 8 public methods.
- Rewrite the multi-hop `object(forKey:completion:)` to thread `outerContext` through all three async hops.

#### Unchanged: `/workspace/Track/LinkedList.swift`

Internal data structure. No public API, no tracing required.

---

### Key Design Properties Satisfied

| Requirement | How Satisfied |
|---|---|
| Every public method creates a child span | `traceContext` parameter on every public method; span opened before dispatch, closed after work |
| Spans record cache name, key, outcome, byte sizes | `TraceAttribute` constants; set at attribute set points in each method |
| Async eviction propagates originating context | `evictionContext: TraceContext?` threaded through `_unsafeSet` to `_unsafeTrim` variants |
| Tracing backend is swappable | `Tracer` and `TraceSpan` protocols; `NoOpTracer` default; no SDK import |
| Context flows across actor (queue) hops | `TraceContext` is captured by value in each closure before `_queue.async`; each operation gets its own local `span` variable |
| No leakage between concurrent operations | Each invocation of a public method creates a fresh span + fresh local `TraceContext`; no shared mutable span state across closures |

---

### Critical Files for Implementation

- `/workspace/Track/Tracing.swift` - New file; defines all protocol, type, and no-op implementations that the rest of the plan depends on
- `/workspace/Track/MemoryCache.swift` - Core logic to modify; all public methods, eviction helpers, and notification handlers need instrumentation
- `/workspace/Track/DiskCache.swift` - Core logic to modify; same as MemoryCache plus init background work and file-size byte attribute
- `/workspace/Track/Cache.swift` - Facade to modify; tracer propagation to sub-caches and the complex multi-hop async `object(forKey:)` method