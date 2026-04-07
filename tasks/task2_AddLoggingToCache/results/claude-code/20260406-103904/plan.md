# Plan: Distributed Tracing with Context Propagation for Track Cache

## Context
Track is a GCD-based Swift 5 iOS cache library (no async/await, no actors) with three public classes: `Cache` (composite coordinator), `MemoryCache`, and `DiskCache`. Each uses a concurrent `DispatchQueue` + binary `DispatchSemaphore` for thread safety. The goal is to add distributed tracing that: creates child spans per public method call, records cache name/key/outcome/byte size, propagates context through async eviction, uses a protocol-only backend (no SDK import), and never leaks context between concurrent GCD operations.

---

## New File: `Track/Tracing.swift`

Defines all protocols, the context carrier, no-op implementations, and shared constants.

```swift
// Opaque carrier — backend holds its SDK-specific span context here
public protocol TraceSpanContext: AnyObject {}

// One unit of work; thread safety is the backend's responsibility
public protocol TraceSpan: AnyObject {
    func setAttribute(_ key: String, stringValue value: String)
    func setAttribute(_ key: String, intValue value: Int)
    var context: TraceSpanContext { get }   // used to derive child spans
    func end()                              // must be called exactly once
}

// Swappable factory — library never imports any tracing SDK
public protocol TraceBackend: AnyObject {
    func startSpan(named name: String, parentContext: TraceSpanContext?) -> TraceSpan
}

// Passed per-call; captured by value (as a class ref) into GCD closure capture lists
public final class TraceContext {
    public let parentContext: TraceSpanContext?
    public let backend: TraceBackend
    public init(parentContext: TraceSpanContext? = nil, backend: TraceBackend) { ... }
    func startChildSpan(named name: String) -> TraceSpan {
        backend.startSpan(named: name, parentContext: parentContext)
    }
}

public enum TraceOutcome: String { case hit, miss, set, removed, evicted }

// No-op impls (zero cost when traceContext == nil due to guard short-circuit)
public final class NoOpTraceSpanContext: TraceSpanContext {}
public final class NoOpTraceSpan: TraceSpan { ... }
public final class NoOpTraceBackend: TraceBackend {
    public static let shared = NoOpTraceBackend()
    ...
}

// Internal attribute key constants
enum TraceAttributeKey {
    static let cacheName     = "cache.name"
    static let cacheType     = "cache.type"       // "memory" | "disk" | "composite"
    static let key           = "cache.key"
    static let outcome       = "cache.outcome"     // TraceOutcome.rawValue
    static let byteSize      = "cache.byte_size"   // Int (cost or file bytes)
    static let evictCount    = "cache.evict_count" // Int
    static let trimStrategy  = "cache.trim_strategy" // "count" | "cost" | "age"
}
```

---

## Span Naming Convention

| Class | Operation | Span name |
|---|---|---|
| MemoryCache | set / get / remove / removeAll / trim | `"memory_cache.set"` / `"memory_cache.get"` / … |
| MemoryCache | eviction triggered by set | `"memory_cache.evict"` |
| DiskCache | set / get / remove / removeAll / trim | `"disk_cache.set"` / `"disk_cache.get"` / … |
| DiskCache | eviction triggered by set | `"disk_cache.evict"` |
| Cache | set / get / remove / removeAll | `"cache.set"` / `"cache.get"` / … |

---

## Modified Files

### `Track/MemoryCache.swift`

**Pattern for every public sync method** — add `traceContext: TraceContext? = nil` as the last parameter (default nil preserves all existing call sites):

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         traceContext: TraceContext? = nil) {
    let span = traceContext?.startChildSpan(named: "memory_cache.set")
    span?.setAttribute(TraceAttributeKey.cacheName, stringValue: "MemoryCache")
    span?.setAttribute(TraceAttributeKey.cacheType, stringValue: "memory")
    span?.setAttribute(TraceAttributeKey.key, stringValue: key)
    span?.setAttribute(TraceAttributeKey.byteSize, intValue: Int(cost))
    _lock()
    _unsafeSet(object: object, forKey: key, cost: cost, traceContext: traceContext)
    _unlock()
    span?.setAttribute(TraceAttributeKey.outcome, stringValue: TraceOutcome.set.rawValue)
    span?.end()
}

func object(forKey key: String, traceContext: TraceContext? = nil) -> AnyObject? {
    let span = traceContext?.startChildSpan(named: "memory_cache.get")
    // ... set name/type/key attributes ...
    _lock()
    let obj = _cache.object(forKey: key); obj?.time = CACurrentMediaTime()
    _unlock()
    span?.setAttribute(TraceAttributeKey.outcome,
                       stringValue: (obj != nil ? TraceOutcome.hit : .miss).rawValue)
    if let cost = obj?.cost { span?.setAttribute(TraceAttributeKey.byteSize, intValue: Int(cost)) }
    span?.end()
    return obj?.value
}
// removeObject, removeAllObjects, trim(toCount/toCost/toAge) — same pattern
```

**Pattern for every public async method** — capture context explicitly in the closure:

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         completion: MemoryCacheAsyncCompletion?,
         traceContext: TraceContext? = nil) {
    _queue.async { [weak self, traceContext] in   // explicit capture — no queue leakage
        guard let strongSelf = self else { completion?(nil, key, object); return }
        strongSelf.set(object: object, forKey: key, cost: cost, traceContext: traceContext)
        completion?(strongSelf, key, object)
    }
}
// All other async variants follow the identical wrapper pattern
```

**Propagate context through eviction chain:**

```swift
// _unsafeSet — add traceContext parameter (default nil preserves CacheGenerator call site)
fileprivate func _unsafeSet(object: AnyObject, forKey key: String, cost: UInt = 0,
                            traceContext: TraceContext? = nil) {
    _cache.set(...)
    if _cache.cost > _costLimit { _unsafeTrim(toCost: _costLimit, traceContext: traceContext) }
    if _cache.count > _countLimit { _unsafeTrim(toCount: _countLimit, traceContext: traceContext) }
}

fileprivate func _unsafeTrim(toCount countLimit: UInt, traceContext: TraceContext? = nil) {
    let span = traceContext?.startChildSpan(named: "memory_cache.evict")
    span?.setAttribute(TraceAttributeKey.trimStrategy, stringValue: "count")
    let before = _cache.count
    // ... existing eviction loop unchanged ...
    span?.setAttribute(TraceAttributeKey.evictCount, intValue: Int(before) - Int(_cache.count))
    span?.end()
}
// _unsafeTrim(toCost:) and _unsafeTrim(toAge:) — same pattern with trimStrategy "cost"/"age"
```

Notification-triggered eviction (`_didReceiveMemoryWarningNotification` → `removeAllObjects(nil)`) compiles unchanged; `nil` satisfies the completion parameter and `traceContext` defaults to nil — no trace context available, correct behaviour.

---

### `Track/DiskCache.swift`

Same public API changes as MemoryCache. Key structural difference: DiskCache has no `_unsafeSet` — the sync `set()` holds the lock and calls `_unsafeTrim` inline:

```swift
func set(object: NSCoding, forKey key: String, traceContext: TraceContext? = nil) {
    let span = traceContext?.startChildSpan(named: "disk_cache.set")
    span?.setAttribute(TraceAttributeKey.cacheName, stringValue: name)
    span?.setAttribute(TraceAttributeKey.cacheType, stringValue: "disk")
    span?.setAttribute(TraceAttributeKey.key, stringValue: key)
    var recordedSize: UInt = 0
    _lock()
    if NSKeyedArchiver.archiveRootObject(object, toFile: filePath) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
            recordedSize = (attrs[.size] as? UInt) ?? 0
            _cache.set(object: DiskCacheObject(key: key, cost: recordedSize, ...), forKey: key)
        } catch {}
    }
    if _cache.cost > _costLimit { _unsafeTrim(toCost: _costLimit, traceContext: traceContext) }
    if _cache.count > _countLimit { _unsafeTrim(toCount: _countLimit, traceContext: traceContext) }
    _unlock()
    span?.setAttribute(TraceAttributeKey.byteSize, intValue: Int(recordedSize))
    span?.setAttribute(TraceAttributeKey.outcome, stringValue: TraceOutcome.set.rawValue)
    span?.end()
}
```

`_unsafeTrim` variants in DiskCache receive `traceContext` and emit `"disk_cache.evict"` spans with `evictCount` and `trimStrategy` attributes — identical pattern to MemoryCache.

---

### `Track/Cache.swift`

The coordinator creates a parent span and derives a child `TraceContext` so sub-cache spans nest correctly:

```swift
// Private helper
private func _childContext(from traceContext: TraceContext?, parentSpan: TraceSpan) -> TraceContext? {
    guard let ctx = traceContext else { return nil }
    return TraceContext(parentContext: parentSpan.context, backend: ctx.backend)
}

func set(object: NSCoding, forKey key: String, traceContext: TraceContext? = nil) {
    let span = traceContext?.startChildSpan(named: "cache.set")
    span?.setAttribute(TraceAttributeKey.cacheName, stringValue: name)
    span?.setAttribute(TraceAttributeKey.cacheType, stringValue: "composite")
    span?.setAttribute(TraceAttributeKey.key, stringValue: key)
    let childCtx = span.flatMap { _childContext(from: traceContext, parentSpan: $0) }
    memoryCache.set(object: object, forKey: key, traceContext: childCtx)
    diskCache.set(object: object, forKey: key, traceContext: childCtx)
    span?.setAttribute(TraceAttributeKey.outcome, stringValue: TraceOutcome.set.rawValue)
    span?.end()
}

func object(forKey key: String, traceContext: TraceContext? = nil) -> AnyObject? {
    let span = traceContext?.startChildSpan(named: "cache.get")
    // ... set attributes ...
    let childCtx = span.flatMap { _childContext(from: traceContext, parentSpan: $0) }
    var result: AnyObject? = nil
    if let obj = memoryCache.object(forKey: key, traceContext: childCtx) {
        result = obj
    } else if let obj = diskCache.object(forKey: key, traceContext: childCtx) {
        memoryCache.set(object: obj, forKey: key, traceContext: childCtx) // promote with trace
        result = obj
    }
    span?.setAttribute(TraceAttributeKey.outcome,
                       stringValue: (result != nil ? TraceOutcome.hit : .miss).rawValue)
    span?.end()
    return result
}
// removeObject, removeAllObjects — same parent-span + childCtx pattern
```

**Async methods** capture `traceContext` in `[weak self, traceContext]` and delegate to the sync version (which handles span creation):

```swift
func set(object: NSCoding, forKey key: String,
         completion: CacheAsyncCompletion?,
         traceContext: TraceContext? = nil) {
    _queue.async { [weak self, traceContext] in
        guard let strongSelf = self else { completion?(nil, key, object); return }
        strongSelf.set(object: object, forKey: key, traceContext: traceContext)
        completion?(strongSelf, key, object)
    }
}
```

The async `object(forKey:completion:)` is refactored to call the sync `object(forKey:traceContext:)` inside the already-dispatched block (same off-caller-thread guarantee, simpler context propagation, removes the original three-level nested closure):

```swift
func object(forKey key: String,
            completion: CacheAsyncCompletion?,
            traceContext: TraceContext? = nil) {
    _queue.async { [weak self, traceContext] in
        guard let strongSelf = self else { return }
        let result = strongSelf.object(forKey: key, traceContext: traceContext)
        DispatchQueue.main.async { completion?(strongSelf, key, result) }
    }
}
```

---

## GCD Context Safety Rationale

`_queue` is a **concurrent** queue — `DispatchQueue.getSpecific` would return the same value to all concurrent blocks, causing context leakage. Explicit closure capture (`[weak self, traceContext]`) is the only correct approach: each enqueued closure captures its own `traceContext` reference at enqueue time, independent of all other in-flight operations.

`TraceContext` is immutable after creation (all `let` properties), so capturing the reference across threads requires no synchronisation on Track's side.

---

## Backward Compatibility

All existing call sites compile unchanged:
- `traceContext:` defaults to `nil` on every method → no spans created → identical behaviour
- `removeAllObjects(nil)` (notification path): `nil` satisfies the completion param; `traceContext` defaults to `nil`
- `_unsafeSet(object:forKey:)` in `CacheGenerator.next()`: `traceContext` defaults to `nil`
- `_unsafeTrim(toCost:)` in property setters: `traceContext` defaults to `nil`
- Subscripts: unchanged (Swift subscripts cannot carry extra parameters); documented as untraced

---

## Files to Create / Modify

| File | Action |
|---|---|
| `Track/Tracing.swift` | **Create** — all protocols, TraceContext, NoOp impls, TraceOutcome, TraceAttributeKey |
| `Track/MemoryCache.swift` | **Modify** — 14 public methods + `_unsafeSet` + 3 `_unsafeTrim` variants |
| `Track/DiskCache.swift` | **Modify** — 14 public methods + 3 `_unsafeTrim` variants + inline eviction in `set()` |
| `Track/Cache.swift` | **Modify** — 8 public methods + `_childContext` helper + async `object` refactor |
| `Track/LinkedList.swift` | No changes |

---

## Verification

1. **Regression**: All existing call sites compile and tests pass with `traceContext` omitted.
2. **No-op path**: With `traceContext = nil`, zero allocations related to tracing (span guard short-circuits immediately).
3. **Span tree**: With a recording backend, `Cache.set` produces spans: `cache.set` → `memory_cache.set`, `cache.set` → `disk_cache.set`.
4. **Eviction propagation**: Setting countLimit = 1 and inserting two items produces `memory_cache.evict` as a child of `memory_cache.set` with correct `evict_count` attribute.
5. **Concurrent isolation**: 100 concurrent async operations each with distinct TraceContexts produce spans where every span's `parentContext` matches its originating context (no cross-contamination).
6. **Notification path**: `UIApplication.didReceiveMemoryWarningNotification` triggers `removeAllObjects` with no span created.
