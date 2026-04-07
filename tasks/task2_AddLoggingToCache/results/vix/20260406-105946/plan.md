## Implementation Plan: Distributed Tracing with Context Propagation

### Overview

The library is a Swift iOS cache library (`Track`) composed of three layers: `Cache` (facade), `MemoryCache`, and `DiskCache`. All three expose both sync and async public methods. The plan adds a swappable tracing abstraction and instruments every public method without introducing any hard SDK dependency.

---

### Architectural Decisions

**1. Protocol-based tracer abstraction (no SDK hard-dependency)**

Define a `TraceSpan` protocol and a `Tracer` protocol in a new file `Track/Tracing.swift`. The library ships a `NoOpTracer` as the default implementation. Callers inject their own backend (e.g., OpenTelemetry, Datadog) by conforming to `Tracer` and assigning it on a global `TraceConfig` registry. No import of any tracing SDK appears anywhere in the library source.

**2. Explicit context passing, not thread-local storage**

Swift's `DispatchQueue` does not have reliable thread-local storage that survives `async` hops, and the library's concurrent queues dispatch work onto arbitrary threads. Passing `TraceContext?` explicitly as an optional parameter on every public method is the only safe approach. This makes context flow visible, prevents leakage between concurrent operations, and requires no runtime magic.

The async overloads already have completion callbacks. Adding `context: TraceContext? = nil` as a defaulted parameter to every public method preserves full source compatibility for existing callers (they pass nothing and get no-op behavior).

**3. Child span lifecycle**

Each public method:
1. Calls `TraceConfig.tracer.startSpan(name:parent:attributes:)` at entry, passing the caller-supplied `TraceContext?` as parent.
2. Executes its work.
3. Records outcome and byte-size attributes on the span.
4. Calls `span.end()` before returning (sync path) or inside the completion closure (async path).

For async methods the span is captured in the closure; it must be ended on all exit paths including the `guard let strongSelf` early-return branches.

**4. Async eviction context propagation**

`MemoryCache._unsafeTrim` and `DiskCache._unsafeTrim` are called both directly from setters (under lock) and from limit-setter property observers. The trim operations that evict entries are driven by `_costLimit`/`_countLimit` checks at the end of `set(object:forKey:)`. Since eviction is triggered inside the same call that holds the originating span, the `TraceContext` captured from the `set` call's parameter is passed into the trim helpers. This avoids any global mutable state for context propagation.

---

### Files to Create/Modify

**New file: `/workspace/Track/Tracing.swift`**

Contains:

```
public protocol TraceSpan: AnyObject {
    func setAttribute(key: String, value: String)
    func setAttribute(key: String, value: Int)
    func end()
}

public struct TraceContext {
    public let span: TraceSpan
    public init(span: TraceSpan) { self.span = span }
}

public protocol Tracer {
    func startSpan(name: String, parent: TraceContext?, attributes: [String: String]) -> TraceSpan
}

public final class NoOpSpan: TraceSpan {
    public func setAttribute(key: String, value: String) {}
    public func setAttribute(key: String, value: Int) {}
    public func end() {}
}

public final class NoOpTracer: Tracer {
    public func startSpan(name: String, parent: TraceContext?, attributes: [String: String]) -> TraceSpan {
        return NoOpSpan()
    }
}

public enum TraceConfig {
    public static var tracer: Tracer = NoOpTracer()
}
```

`TraceConfig.tracer` is the single injection point. The consumer sets it once at app startup.

---

**Modified file: `/workspace/Track/Cache.swift`**

Changes:

1. Add `context: TraceContext? = nil` parameter to every public method in the `Cache` public extension (both sync and async variants): `set(object:forKey:context:completion:)`, `set(object:forKey:context:)`, `object(forKey:context:completion:)`, `object(forKey:context:)`, `removeObject(forKey:context:completion:)`, `removeObject(forKey:context:)`, `removeAllObjects(_:context:)`, `removeAllObjects(context:)`.

2. In each method, open a child span:
```swift
let span = TraceConfig.tracer.startSpan(
    name: "Cache.\(#function)",
    parent: context,
    attributes: ["cache.name": name, "cache.layer": "unified"]
)
```

3. Set `cache.key` attribute where a key is present.

4. For `object(forKey:)`: set `cache.outcome` to `"hit"` or `"miss"`.

5. For `set(object:forKey:)`: after writing, set `cache.bytes` by attempting `(object as? Data)?.count` or falling back to a keyed-archiver size estimate.

6. Call `span.end()` at every exit point.

7. Pass `context` down into `memoryCache.set(...)`, `diskCache.set(...)`, etc. so sub-cache spans are children of the same parent, not children of the Cache span. This preserves the caller's context as the common root across all layers for one logical operation.

8. The async overloads capture `span` in the closure and call `span.end()` inside the completion wrapper.

---

**Modified file: `/workspace/Track/MemoryCache.swift`**

Changes:

1. Add `context: TraceContext? = nil` to all public methods in the `MemoryCache` public extension: `set`, `object`, `removeObject`, `removeAllObjects`, `trim(toCount:)`, `trim(toCost:)`, `trim(toAge:)` — both sync and async forms.

2. In each public sync method, create a child span:
```swift
let span = TraceConfig.tracer.startSpan(
    name: "MemoryCache.\(operationName)",
    parent: context,
    attributes: ["cache.name": "MemoryCache", "cache.key": key]
)
defer { span.end() }
```

3. For `object(forKey:context:)`: after the lookup, set `cache.outcome` (`"hit"` or `"miss"`).

4. For `set(object:forKey:cost:context:)`: set `cache.bytes` using `cost` if non-zero, otherwise skip.

5. For async methods: the span is started before the `_queue.async` dispatch, and the `TraceContext` wrapping that span is passed explicitly into the closure. The span is ended inside the closure at every exit branch (including the `guard` early return).

6. For `_unsafeTrim` calls triggered from within `_unsafeSet`: the trim helpers accept an optional `TraceContext?` parameter and create child trim spans parented to the set operation's context.

7. Internal `_unsafeTrim(toCount:context:)`, `_unsafeTrim(toCost:context:)`, `_unsafeTrim(toAge:context:)` each record `cache.eviction_reason` and `cache.evicted_count` attributes.

---

**Modified file: `/workspace/Track/DiskCache.swift`**

Changes mirror `MemoryCache.swift` exactly:

1. Add `context: TraceContext? = nil` to all public methods.

2. Sync methods use `defer { span.end() }`.

3. Async methods start the span before dispatch, capture it in the closure, end it inside the closure.

4. `set(object:forKey:context:)`: after the `NSKeyedArchiver.archiveRootObject` call succeeds and `fileSize` is computed, set `cache.bytes` with the actual file size.

5. `_unsafeTrim` variants accept and forward context, record eviction count.

6. The init-time `_queue.async { _loadFilesInfo() }` block does not produce user-visible spans (it is internal setup, not a public method call).

---

### Span Attribute Contract

Every span records a consistent set of attributes:

| Attribute key         | Type   | Set by                | Notes                                  |
|-----------------------|--------|-----------------------|----------------------------------------|
| `cache.name`          | String | all methods           | value from `self.name` or class name   |
| `cache.layer`         | String | all methods           | `"memory"`, `"disk"`, or `"unified"`   |
| `cache.operation`     | String | all methods           | `"set"`, `"get"`, `"remove"`, `"trim"` |
| `cache.key`           | String | key-based methods     | omitted on removeAll/trim              |
| `cache.outcome`       | String | get methods           | `"hit"` or `"miss"`                    |
| `cache.bytes`         | Int    | set, disk read        | byte count of stored/read value        |
| `cache.evicted_count` | Int    | trim methods          | number of entries evicted              |
| `cache.eviction_reason` | String | trim methods        | `"count"`, `"cost"`, or `"age"`        |

---

### Context Isolation Across Concurrent Operations

The library's queues are concurrent (`DispatchQueue.Attributes.concurrent`). Two simultaneous calls to `cache.set(...)` each supply their own `TraceContext?`. Because context is a value type (`struct TraceContext`) passed as a local parameter, each closure captures its own independent copy. There is no shared mutable context state anywhere in the library. This is the key reason thread-local or task-local storage is deliberately avoided.

---

### Async Eviction Propagation Detail

In `DiskCache.set(object:forKey:context:)` (sync), the sequence is:
1. Span started from `context`.
2. File written.
3. `_cache.set(...)` updates LRU.
4. If `_cache.cost > _costLimit`, `_unsafeTrim(toCost:_costLimit, context: TraceContext(span: span))` is called — eviction becomes a child of the set span.

In `MemoryCache.set(object:forKey:cost:context:)`, same pattern through `_unsafeSet`.

For the async `trim(toCount:completion:context:)` public methods, the span is started before dispatch and the `TraceContext(span: span)` is passed into the async block explicitly.

---

### Source Compatibility

All new parameters use `= nil` defaults. No existing call site requires modification. The `NoOpTracer` is the default, so with no configuration the library behaves identically to today.

---

### Implementation Sequence

1. Create `/workspace/Track/Tracing.swift` with the protocol hierarchy and `NoOpTracer`.
2. Modify `/workspace/Track/MemoryCache.swift`: add context parameters to public methods, instrument spans, thread context into `_unsafeTrim`.
3. Modify `/workspace/Track/DiskCache.swift`: same as step 2; use actual `fileSize` for `cache.bytes`.
4. Modify `/workspace/Track/Cache.swift`: add context parameters to public facade methods, create spans, pass caller's context (not a new child context) down into sub-cache calls.

---

### Critical Files for Implementation

- `/workspace/Track/Tracing.swift` - New file: defines `TraceSpan`, `TraceContext`, `Tracer` protocols and `NoOpTracer`/`NoOpSpan` defaults; the only place tracing abstractions live
- `/workspace/Track/MemoryCache.swift` - Core logic to modify: all public sync/async methods need context parameters and span instrumentation; `_unsafeTrim` needs context threading for eviction propagation
- `/workspace/Track/DiskCache.swift` - Core logic to modify: mirrors MemoryCache changes; provides actual byte sizes from file system metadata; same eviction propagation pattern
- `/workspace/Track/Cache.swift` - Facade to modify: public API entry point that must add context parameters and forward the caller's context to sub-cache calls without creating an intermediate span layer