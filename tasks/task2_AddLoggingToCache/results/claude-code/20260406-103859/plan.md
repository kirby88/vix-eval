# Plan: Distributed Tracing with Context Propagation for Track Cache

## Context

Track is a Swift LRU two-tier cache library (MemoryCache + DiskCache + Cache wrapper). It has no observability at all today. The goal is to add distributed tracing with a swappable backend so integrators can plug in OpenTelemetry, Jaeger, or custom implementations without the library depending on any specific SDK. Every public operation must create a child span under the caller's context (opt-in per-call), record relevant attributes, and correctly propagate context into triggered evictions.

---

## Critical Files

- **New**: `/workspace/Track/TrackTracing.swift` — all tracing protocol/type definitions
- **Modified**: `/workspace/Track/MemoryCache.swift`
- **Modified**: `/workspace/Track/DiskCache.swift`
- **Modified**: `/workspace/Track/Cache.swift`
- `/workspace/Track/LinkedList.swift` — no changes needed

---

## Phase 1: New File — `TrackTracing.swift`

Define the entire tracing surface in one file with no imports beyond `Foundation`.

### `TrackSpanContext`
Empty protocol — Track never inspects it. The SDK integrator defines all internals.
```swift
public protocol TrackSpanContext {}
```

### `TrackSpanOutcome`
Extensible struct with static factory properties (not an enum, so integrators can add custom values):
```swift
public struct TrackSpanOutcome: Equatable {
    public let value: String
    public init(_ value: String) { self.value = value }
    public static let hit     = TrackSpanOutcome("hit")
    public static let miss    = TrackSpanOutcome("miss")
    public static let success = TrackSpanOutcome("success")
    public static let failure = TrackSpanOutcome("failure")
    public static let evicted = TrackSpanOutcome("evicted")
}
```

### `TrackSpanAttributes`
A struct (not a raw dictionary) that holds the fixed attribute set. All fields optional except `cacheName` and `operation`.
```swift
public struct TrackSpanAttributes {
    public var cacheName: String
    public var operation: String        // "set","get","remove","removeAll","trim"
    public var key: String?
    public var outcome: TrackSpanOutcome?
    public var valueByteSize: UInt?     // serialised bytes (DiskCache) or caller cost (MemoryCache)
    public var cost: UInt?
}
```

### `TrackSpan`
Class-bound protocol (span held alive across async closures):
```swift
public protocol TrackSpan: AnyObject {
    var spanContext: any TrackSpanContext { get }
    func setAttributes(_ attributes: TrackSpanAttributes)
    func end()
}
```
`spanContext` enables passing the current span as parent to child spans (eviction, sub-cache calls).

### `TrackTracer`
Class-bound; strong reference stored on cache instances:
```swift
public protocol TrackTracer: AnyObject {
    func startSpan(
        named name: String,
        childOf context: (any TrackSpanContext)?,
        attributes: TrackSpanAttributes
    ) -> any TrackSpan
}
```
When `context == nil`, the tracer creates a root span (correct for system-triggered evictions).

---

## Phase 2: Tracer Attachment

Each of the three cache classes gets a publicly settable `tracer` property, with no lock (set once at app startup, same as `countLimit`/`ageLimit`):

```swift
// MemoryCache.swift, DiskCache.swift
public var tracer: (any TrackTracer)? = nil
```

```swift
// Cache.swift — propagates automatically to sub-caches
public var tracer: (any TrackTracer)? {
    didSet {
        memoryCache.tracer = tracer
        diskCache.tracer = tracer
    }
}
```

Setting `cache.tracer = myTracer` is sufficient for three-level tracing (Cache → MemoryCache/DiskCache). Direct assignment to sub-cache tracers is also supported for per-layer override.

---

## Phase 3: Public API Changes

Add `context: (any TrackSpanContext)? = nil` as the last parameter (before `completion:` in async variants) to every public method. Default `nil` preserves full source compatibility — existing callsites compile unchanged.

Methods to update in **MemoryCache**:
- `set(object:forKey:cost:)` → add `context:`
- `set(object:forKey:cost:completion:)` → add `context:` before `completion:`
- `object(forKey:)` → add `context:`
- `object(forKey:completion:)` → add `context:`
- `removeObject(forKey:)` → add `context:`
- `removeObject(forKey:completion:)` → add `context:`
- `removeAllObjects()` → add `context:`
- `removeAllObjects(_:)` → add `context:`
- `trim(toCount/toCost/toAge:)` → add `context:` (all 6 variants)

Same set of changes for **DiskCache** and **Cache**.

**Subscripts** cannot accept extra parameters in Swift. They call the underlying sync methods which now default `context: nil`. Subscript users get no tracing — this is documented behavior.

---

## Phase 4: Span Lifecycle Patterns

### Private helper (add to each class)
```swift
private func _startSpan(named name: String, childOf context: (any TrackSpanContext)?,
                         operation: String, key: String? = nil, cost: UInt? = nil) -> (any TrackSpan)? {
    return tracer?.startSpan(
        named: name, childOf: context,
        attributes: TrackSpanAttributes(cacheName: self.name /* or hardcoded for MemoryCache */,
                                        operation: operation, key: key, cost: cost))
}
```

### Sync method pattern
```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0, context: (any TrackSpanContext)? = nil) {
    let span = _startSpan(named: "MemoryCache.set", childOf: context, operation: "set", key: key, cost: cost)
    _lock(); _unsafeSet(object: object, forKey: key, cost: cost, trimContext: span?.spanContext); _unlock()
    span?.setAttributes(TrackSpanAttributes(cacheName: ..., operation: "set", outcome: .success, cost: cost))
    span?.end()
}
```

### Async method pattern (span starts BEFORE dispatch, ends INSIDE closure)
```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         context: (any TrackSpanContext)? = nil, completion: MemoryCacheAsyncCompletion?) {
    let span = _startSpan(named: "MemoryCache.set", childOf: context, operation: "set", key: key, cost: cost)
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span?.setAttributes(TrackSpanAttributes(..., outcome: .failure)); span?.end()
            completion?(nil, key, object); return
        }
        // Call sync variant with nil context to prevent duplicate child span
        strongSelf.set(object: object, forKey: key, cost: cost)
        span?.setAttributes(TrackSpanAttributes(..., outcome: .success, cost: cost)); span?.end()
        completion?(strongSelf, key, object)
    }
}
```

### Get hit/miss
```swift
func object(forKey key: String, context: (any TrackSpanContext)? = nil) -> AnyObject? {
    let span = _startSpan(named: "MemoryCache.get", childOf: context, operation: "get", key: key)
    _lock(); let result = _unsafeObject(forKey: key); _unlock()
    span?.setAttributes(TrackSpanAttributes(..., outcome: result != nil ? .hit : .miss)); span?.end()
    return result
}
```

---

## Phase 5: Eviction Context Propagation

Eviction is synchronous in both caches — `_unsafeTrim` is called from within the locked section of `set`. No secondary queue hop; context is carried as a function parameter.

### MemoryCache

`_unsafeSet` gains a `trimContext` parameter:
```swift
func _unsafeSet(object: AnyObject, forKey key: String, cost: UInt = 0, trimContext: (any TrackSpanContext)? = nil) {
    _cache.set(object: MemoryCacheObject(key: key, value: object, cost: cost), forKey: key)
    if _cache.cost > _costLimit { _unsafeTrimSpanned(toCost: _costLimit, context: trimContext) }
    if _cache.count > _countLimit { _unsafeTrimSpanned(toCount: _countLimit, context: trimContext) }
}
```

New private wrappers create eviction child spans:
```swift
private func _unsafeTrimSpanned(toCost limit: UInt, context: (any TrackSpanContext)?) {
    let span = _startSpan(named: "MemoryCache.trim", childOf: context, operation: "trim")
    _unsafeTrim(toCost: limit)
    span?.setAttributes(TrackSpanAttributes(..., outcome: .evicted)); span?.end()
}
// same pattern for toCount
```

The public `set` sync method extracts `span?.spanContext` and passes it to `_unsafeSet`:
```swift
let span = _startSpan(...)
_lock(); _unsafeSet(object: object, forKey: key, cost: cost, trimContext: span?.spanContext); _unlock()
```

**Note:** `CacheGenerator.next()` calls `_unsafeSet` directly (Cache.swift:59). This call passes no `trimContext` — acceptable, as generator iteration does not originate from a traced caller request.

### DiskCache

Eviction is inline within `set`. After the archiving block:
```swift
let span = _startSpan(named: "DiskCache.set", childOf: context, ...)
// ... archiving logic ...
let trimContext = span?.spanContext
if _cache.cost > _costLimit { _unsafeTrimSpanned(toCost: _costLimit, context: trimContext) }
if _cache.count > _countLimit { _unsafeTrimSpanned(toCount: _countLimit, context: trimContext) }
_unlock()
span?.setAttributes(..., valueByteSize: fileSize, outcome: .success); span?.end()
```

### System-triggered eviction (memory warning / background)

`_didReceiveMemoryWarningNotification` and `_didEnterBackgroundNotification` call `removeAllObjects(nil)`. After the signature change, this maps to `removeAllObjects(_:)` with the `context` parameter defaulting to `nil`. This creates root-level spans — correct, as OS events have no caller context to inherit.

---

## Phase 6: Cache.swift — Composite Span Threading

`Cache` creates a top-level span and passes its `spanContext` down to both sub-caches:

```swift
func set(object: NSCoding, forKey key: String, context: (any TrackSpanContext)? = nil) {
    let span = _startSpan(named: "Cache.set", childOf: context, operation: "set", key: key)
    let childCtx = span?.spanContext
    memoryCache.set(object: object, forKey: key, context: childCtx)
    diskCache.set(object: object, forKey: key, context: childCtx)
    span?.setAttributes(TrackSpanAttributes(..., outcome: .success)); span?.end()
}
```

This produces the hierarchy: `Cache.set` → `MemoryCache.set` + `DiskCache.set` (with eviction as their children if triggered).

The `Cache.object(forKey:completion:)` async method has a complex nested callback structure (tries memory, then disk). The top-level `Cache.get` span must remain open until the final `completion` fires. Capture `span` in the outermost closure; when the disk-cache callback resolves, call `span?.end()` before dispatching `completion`. Pass `childCtx` to both the `memoryCache.object` and `diskCache.object` calls.

---

## Span Name Conventions

| Operation | Cache.swift | MemoryCache | DiskCache |
|---|---|---|---|
| set | `Cache.set` | `MemoryCache.set` | `DiskCache.set` |
| get | `Cache.get` | `MemoryCache.get` | `DiskCache.get` |
| remove | `Cache.remove` | `MemoryCache.remove` | `DiskCache.remove` |
| removeAll | `Cache.removeAll` | `MemoryCache.removeAll` | `DiskCache.removeAll` |
| trim | — | `MemoryCache.trim` | `DiskCache.trim` |

---

## Verification

### Mock implementation (test target only)
```swift
struct MockSpanContext: TrackSpanContext { let id = UUID() }
class MockSpan: TrackSpan {
    let name: String; var attributes: TrackSpanAttributes?; var ended = false
    let spanContext: any TrackSpanContext = MockSpanContext()
    init(name: String) { self.name = name }
    func setAttributes(_ a: TrackSpanAttributes) { attributes = a }
    func end() { ended = true }
}
class MockTracer: TrackTracer {
    var spans: [MockSpan] = []
    func startSpan(named name: String, childOf: (any TrackSpanContext)?, attributes: TrackSpanAttributes) -> any TrackSpan {
        let s = MockSpan(name: name); spans.append(s); return s
    }
}
```

### Test cases
1. **Backward compatibility**: call `cache.set(object:forKey:)` with no tracer set → object stored, zero spans, no crash.
2. **Opt-in activation**: set `cache.tracer = MockTracer()`, call sync set with non-nil context → 3 spans (Cache.set, MemoryCache.set, DiskCache.set), all `ended == true`.
3. **Span hierarchy**: `MemoryCache.set` span's parent context ID == `Cache.set` span's `spanContext` ID.
4. **Hit/miss**: `object(forKey:)` on existing key → outcome `.hit`; missing key → `.miss`.
5. **Eviction propagation**: set `MemoryCache.countLimit = 1`, insert 2 items → trim span exists with parent = set span's context.
6. **Async span lifetime**: in async variant, `span.ended == false` while dispatch is pending, `true` after completion fires.
7. **No context leak**: dispatch two concurrent `set` calls with distinct contexts → each span's parent context matches only its own originating context.
8. **DiskCache `valueByteSize`**: after `DiskCache.set`, span attribute `valueByteSize > 0`.
9. **Tracer propagation**: `cache.tracer = t` → `cache.memoryCache.tracer === t` and `cache.diskCache.tracer === t`; setting `nil` propagates `nil`.
10. **Subscript no-op**: `cache["k"] = obj` → no spans, object stored correctly.
