## Implementation Plan: Distributed Tracing with Context Propagation

### Architectural Overview

The core challenge is designing a tracing abstraction that:
1. Has zero hard dependencies on any tracing SDK (OpenTelemetry, Datadog, etc.)
2. Threads trace context explicitly through every public call path
3. Propagates context into async background work (eviction, completion callbacks)
4. Does not leak context between concurrent operations sharing the same `DispatchQueue`

The key insight about context leakage: the library uses shared `DispatchQueue` instances with `async` blocks. Thread-local storage is unreliable here because GCD can reuse threads across unrelated operations. Context must be **captured explicitly at call site** and **passed explicitly into closures** — never read from ambient thread-local state.

---

### Design Decisions

#### 1. Tracer Protocol (the swappable backend)

A `CacheTracer` protocol with a `Span` protocol nested within. The library only imports Foundation — no SDK dependency.

```
public protocol CacheSpan {
    func setAttribute(key: String, value: String)
    func setAttribute(key: String, value: Int)
    func setAttribute(key: String, value: Bool)
    func end()
}

public protocol CacheTracer {
    func startSpan(name: String, context: CacheSpanContext?) -> (span: CacheSpan, context: CacheSpanContext)
}

public struct CacheSpanContext {
    // Opaque bag: the tracer implementation stores whatever it needs here
    public let storage: AnyObject
    public init(storage: AnyObject)
}
```

`CacheSpanContext` is an opaque value type wrapping an `AnyObject`. The library never inspects its contents — it only captures, passes, and threads it through. This means any SDK (OTel, Datadog, custom) can wrap its own span/context reference inside `storage`.

A `NoOpCacheTracer` is provided as the default so the library works out-of-the-box without any configuration.

#### 2. Context is always explicit, never ambient

Every public method gains an **optional** `traceContext: CacheSpanContext?` parameter with a default of `nil`. This is backward-compatible: all existing call sites continue to compile unchanged. When `nil`, the `NoOpCacheTracer` produces no-op spans with negligible overhead.

The tracer is injected at construction time and stored on `Cache`, `MemoryCache`, and `DiskCache`.

#### 3. Span attribute names (constants)

Defined in the new `Tracing.swift` file as internal constants:
- `"cache.name"` — the cache instance name
- `"cache.key"` — the key being operated on
- `"cache.outcome"` — `"hit"`, `"miss"`, `"set"`, `"removed"`, `"evicted"`
- `"cache.bytes"` — byte size of object (when known)
- `"cache.backend"` — `"memory"` or `"disk"`

#### 4. Async eviction context propagation

When `_unsafeTrim` methods dispatch to evict entries, they must capture the calling span context at the moment the trim is triggered. In `MemoryCache.set(object:forKey:cost:)` and the `costLimit`/`countLimit` setters, after the lock is taken but before async trim is called, the current `CacheSpanContext` is captured into the closure. Same for `DiskCache`.

---

### File-by-File Plan

#### New file: `/workspace/Track/Tracing.swift`

This is the only new file. It contains:

1. `public protocol CacheSpan` — lifecycle methods (`setAttribute`, `end`)
2. `public struct CacheSpanContext` — opaque wrapper for `AnyObject`
3. `public protocol CacheTracer` — `startSpan(name:context:) -> (CacheSpan, CacheSpanContext)`
4. `internal final class NoOpSpan: CacheSpan` — all methods are empty
5. `internal final class NoOpCacheTracer: CacheTracer` — returns `NoOpSpan` instances
6. `internal enum SpanAttribute` — string constants for attribute keys
7. `internal enum SpanOutcome` — string constants for outcome values (`hit`, `miss`, `set`, `removed`, `evicted`)

#### Modified file: `/workspace/Track/MemoryCache.swift`

Changes:

1. **Add `tracer` property**: `internal var tracer: CacheTracer = NoOpCacheTracer()`

2. **Add `cacheName` property**: stored at init, defaulting to `"MemoryCache"`, overridable — used in span attributes.

3. **All public sync methods** gain `traceContext: CacheSpanContext? = nil` parameter:
   - `set(object:forKey:cost:traceContext:)` — starts span `"cache.memory.set"`, records `cache.name`, `cache.key`, `cache.outcome = "set"`, `cache.bytes = cost`, ends span
   - `object(forKey:traceContext:)` — starts span `"cache.memory.get"`, records `cache.outcome = "hit"` or `"miss"`, ends span
   - `removeObject(forKey:traceContext:)` — starts span `"cache.memory.remove"`, records outcome
   - `removeAllObjects(traceContext:)` — starts span `"cache.memory.removeAll"`
   - `trim(toCount:traceContext:)`, `trim(toCost:traceContext:)`, `trim(toAge:traceContext:)` — starts span `"cache.memory.trim"`

4. **All public async methods** gain `traceContext: CacheSpanContext? = nil` parameter and **capture the context** into the closure before dispatching:
   ```swift
   func set(object:AnyObject, forKey key:String, cost:UInt=0, traceContext: CacheSpanContext? = nil, completion: MemoryCacheAsyncCompletion?) {
       let capturedContext = traceContext  // captured explicitly, not read from thread
       _queue.async { [weak self] in
           guard let strongSelf = self else { ... }
           strongSelf.set(object: object, forKey: key, cost: cost, traceContext: capturedContext)
           completion?(...)
       }
   }
   ```

5. **Eviction in `_unsafeSet`**: When `_unsafeTrim` is called inline (not async), it is called from within the same sync path that already holds a span — no additional span needed for eviction at this level since it is synchronous. The trim methods will be called with `traceContext: nil` here because eviction is an internal side effect; however, if eviction is triggered by the setter, it creates a child span `"cache.memory.evict"` recording `cache.outcome = "evicted"` and the count/cost trimmed.

6. **`_unsafeSet` internal helper**: does NOT take a trace context (it is private/internal, not public). The span wraps the call to `_unsafeSet` from the public `set(...)` method.

7. **Memory warning / background eviction** (`_didReceiveMemoryWarningNotification`, `_didEnterBackgroundNotification`): These fire with no caller context. They call `removeAllObjects(nil)` with `traceContext: nil` — the no-op tracer handles this gracefully, meaning a span is created without a parent. This is correct behavior: system-initiated eviction has no caller trace context.

#### Modified file: `/workspace/Track/DiskCache.swift`

Mirrors MemoryCache changes:

1. **Add `tracer` property**: `internal var tracer: CacheTracer = NoOpCacheTracer()`

2. **All public sync methods** gain `traceContext: CacheSpanContext? = nil`:
   - `set(object:forKey:traceContext:)` — span `"cache.disk.set"`, records `cache.bytes` from `fileSize`
   - `object(forKey:traceContext:)` — span `"cache.disk.get"`, records hit/miss
   - `removeObject(forKey:traceContext:)` — span `"cache.disk.remove"`
   - `removeAllObjects(traceContext:)` — span `"cache.disk.removeAll"`
   - `trim(toCount:traceContext:)`, `trim(toCost:traceContext:)`, `trim(toAge:traceContext:)` — span `"cache.disk.trim"`

3. **All public async methods** capture context explicitly into closures.

4. **`_unsafeTrim` eviction loops**: These are called from within sync locked sections. When triggered by the `set` path, the parent span context is available. An internal `_unsafeTrim` overload is not created — instead, the eviction child span is created at the `set` method level, wrapping the entire lock block including trim calls.

5. **Init async load** (`_queue.async { _=self._createCacheDir(); _=self._loadFilesInfo() }`): This background work has no caller context. No tracing needed — it is infrastructure initialization, not a user-facing cache operation.

#### Modified file: `/workspace/Track/Cache.swift`

Changes:

1. **Add `tracer` property with `didSet`**: When set on `Cache`, it propagates to both `memoryCache.tracer` and `diskCache.tracer`:
   ```swift
   public var tracer: CacheTracer = NoOpCacheTracer() {
       didSet {
           memoryCache.tracer = tracer
           diskCache.tracer = tracer
       }
   }
   ```

2. **Add `cacheName` propagation**: The `name` property (already exists) is set on both sub-caches.

3. **All public sync methods** gain `traceContext: CacheSpanContext? = nil`:
   - `set(object:forKey:traceContext:)` — starts span `"cache.set"`, creates child context, passes child context to `memoryCache.set` and `diskCache.set`
   - `object(forKey:traceContext:)` — span `"cache.get"`, passes context down
   - `removeObject(forKey:traceContext:)` — span `"cache.remove"`
   - `removeAllObjects(traceContext:)` — span `"cache.removeAll"`

4. **All public async methods** capture context explicitly.

5. **Subscript**: Subscript cannot take a trace context (Swift limitation on subscript parameters). The subscript calls the underlying sync methods with `traceContext: nil`. This is acceptable — subscript is a convenience API and callers who need tracing should use the explicit methods.

6. **`CacheAsyncCompletion`**: The type alias signature does not change. The tracing is internal.

---

### Span Lifecycle Pattern (applied uniformly)

Every instrumented public method follows this exact pattern:

```swift
public func set(object: AnyObject, forKey key: String, traceContext: CacheSpanContext? = nil) {
    let (span, _) = tracer.startSpan(name: "cache.memory.set", context: traceContext)
    span.setAttribute(key: SpanAttribute.cacheName, value: cacheName)
    span.setAttribute(key: SpanAttribute.key, value: key)
    // ... perform operation ...
    span.setAttribute(key: SpanAttribute.outcome, value: SpanOutcome.set)
    span.end()
}
```

The child `CacheSpanContext` returned from `startSpan` is passed to any further nested cache calls (e.g., `Cache.set` passes its child context to `memoryCache.set` and `diskCache.set`). This creates a proper parent-child span tree.

---

### No-Leak Guarantee

Context leakage between concurrent operations is prevented because:
- No thread-local or task-local storage is used
- Each call captures its own `traceContext` on the stack before dispatching
- The `_queue.async` closure captures `capturedContext` by value (it is a struct)
- Two concurrent `set` operations on the same queue cannot access each other's context

---

### Backward Compatibility

All new `traceContext:` parameters have `= nil` defaults. No existing call sites break. The `NoOpCacheTracer` produces zero-overhead no-op spans by default. The library compiles and works identically to before unless a tracer is explicitly installed.

---

### Implementation Sequence

1. Create `/workspace/Track/Tracing.swift` with protocols, `NoOpCacheTracer`, and attribute/outcome constants
2. Modify `/workspace/Track/MemoryCache.swift` — add `tracer` and `cacheName`, instrument all public methods
3. Modify `/workspace/Track/DiskCache.swift` — add `tracer` and `cacheName`, instrument all public methods
4. Modify `/workspace/Track/Cache.swift` — add `tracer` with `didSet` propagation, instrument all public methods, pass child contexts down to sub-caches

---

### Critical Files for Implementation

- `/workspace/Track/Tracing.swift` - New file: defines the `CacheTracer`/`CacheSpan`/`CacheSpanContext` protocols, `NoOpCacheTracer`, and all span attribute/outcome constants
- `/workspace/Track/Cache.swift` - Top-level cache: add tracer injection with propagation to sub-caches, instrument all public sync/async methods
- `/workspace/Track/MemoryCache.swift` - Memory layer: add tracer property, instrument all public methods, handle eviction context propagation
- `/workspace/Track/DiskCache.swift` - Disk layer: add tracer property, instrument all public methods including file-size byte recording