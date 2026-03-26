# Plan: Distributed Tracing with Context Propagation

## Context

The Track library has no observability. Callers integrating it into traced applications (e.g. with OpenTelemetry or Datadog) cannot correlate cache operations with the rest of their trace tree. This plan adds opt-in, SDK-agnostic distributed tracing to every public method on `Cache`, `MemoryCache`, and `DiskCache`. When no context is provided all tracing code is bypassed at essentially zero cost.

---

## New File: `Track/Tracing.swift`

Everything tracing-related lives here. No other SDK imports. No hard dependencies.

### Protocols and types

```swift
// Opaque carrier — class so closure capture is a reference copy, not value copy
public protocol TraceContext: AnyObject {}

public enum CacheLayer: String { case memory, disk, unified }
public enum CacheOperation: String { case get = "cache.get", set = "cache.set",
    remove = "cache.remove", removeAll = "cache.removeAll", trim = "cache.trim" }
public enum CacheOutcome: String { case hit, miss, set, removed, evicted, notFound }
public enum TrimDimension { case count(UInt), cost(UInt), age(TimeInterval) }

public struct CacheSpanAttributes {
    public let cacheName: String
    public let layer: CacheLayer
    public let operation: CacheOperation
    public let key: String?          // nil for removeAll / trim
    public let outcome: CacheOutcome
    public let byteSize: UInt?       // nil when unknown/not applicable
    public let trimDimension: TrimDimension?
}
```

```swift
public protocol TraceBackend: AnyObject {
    // Called before the operation. Return nil to suppress this span entirely.
    func startSpan(named: String, parent: TraceContext,
                   attributes: CacheSpanAttributes) -> TraceContext?
    // Called after the operation completes (outside any lock).
    func endSpan(_ span: TraceContext, finalAttributes: CacheSpanAttributes,
                 error: Error?)
}
```

```swift
// Zero-overhead default — methods are empty; Swift optimizer eliminates calls
public final class NoOpTraceBackend: TraceBackend {
    public static let shared = NoOpTraceBackend()
    public func startSpan(named: String, parent: TraceContext,
                          attributes: CacheSpanAttributes) -> TraceContext? { nil }
    public func endSpan(_ span: TraceContext, finalAttributes: CacheSpanAttributes,
                        error: Error?) {}
}
```

```swift
// Library-level singleton config point. Set once at app startup.
public struct TraceConfiguration {
    private static var _backend: TraceBackend = NoOpTraceBackend.shared
    private static let _lock = DispatchSemaphore(value: 1)

    public static func configure(backend: TraceBackend) {
        _lock.wait(); _backend = backend; _lock.signal()
    }
    internal static var backend: TraceBackend {
        _lock.wait(); let b = _backend; _lock.signal(); return b
    }
}
```

### Internal span helper (`@inline(__always)`)

```swift
// Fast path: if context == nil, calls body(nil) with zero overhead.
// Otherwise: startSpan → body(childSpan) → endSpan.
// body returns (result, outcome, finalBytes).
@inline(__always)
internal func _withSpan<T>(
    named: String, operation: CacheOperation,
    key: String?, cacheName: String, layer: CacheLayer,
    byteSize: UInt? = nil, trimDimension: TrimDimension? = nil,
    context: TraceContext?,
    body: (_ childSpan: TraceContext?) throws -> (result: T, outcome: CacheOutcome, finalBytes: UInt?)
) rethrows -> T
```

---

## Modified: `Track/MemoryCache.swift`

### 1. Add `name` property and update `init`

`MemoryCache` has no `name`. Add:
```swift
public let name: String
public init(name: String = "shared") { self.name = name; /* existing observers */ }
```
`shareInstance` calls `MemoryCache()` → becomes `MemoryCache(name: "shared")`. Source-compatible.

### 2. Add `systemEventContext` property

```swift
// Set this to a long-lived root span to trace system-triggered evictions.
public var systemEventContext: TraceContext? = nil
```

Notification handlers pass it:
```swift
@objc fileprivate func _didReceiveMemoryWarningNotification() {
    if autoRemoveAllObjectWhenMemoryWarning {
        removeAllObjects(nil, traceContext: systemEventContext)
    }
}
```

### 3. Add `traceContext` to every public method

All public methods get `traceContext: TraceContext? = nil` as a trailing defaulted parameter. Source-compatible — existing callers compile unchanged.

### 4. Sync methods — `_withSpan` wrapper

Pattern (shown for `set`):
```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         traceContext: TraceContext? = nil) {
    _withSpan(named: "MemoryCache.set", operation: .set, key: key,
              cacheName: name, layer: .memory, byteSize: cost, context: traceContext) { _ in
        _lock()
        _unsafeSet(object: object, forKey: key, cost: cost)
        _unlock()
        return ((), .set, cost)
    }
}
```

For `object(forKey:)`: outcome is `.hit`/`.miss`; `finalBytes` is the object's `cost` from the LRU if found.
For `removeObject(forKey:)`: outcome is `.removed` if key existed (check return of `_cache.removeObject`), else `.notFound`.
For `trim(to...)`: outcome is `.evicted`; include `trimDimension`.

### 5. Async methods — capture-then-pass pattern

The context is captured into a `let` before entering `_queue.async`. This is the **only** safe pattern — it ensures each concurrent closure has its own independent copy of the context reference with no shared mutable state.

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         completion: MemoryCacheAsyncCompletion?,
         traceContext: TraceContext? = nil) {
    let capturedContext = traceContext        // local let, unique per call
    _queue.async { [weak self] in
        guard let strongSelf = self else { completion?(nil, key, object); return }
        strongSelf.set(object: object, forKey: key, cost: cost, traceContext: capturedContext)
        completion?(strongSelf, key, object)
    }
}
```

This applies to all async methods including trim variants.

### 6. `_unsafeSet` — add `spanContext` parameter with default nil

```swift
func _unsafeSet(object: AnyObject, forKey key: String,
                cost: UInt = 0, spanContext: TraceContext? = nil)
```

The `spanContext` is forwarded to inline eviction helpers so auto-eviction triggered by a `set` is attributed to that set's span context. The existing call from `CacheGenerator` passes no context (nil default, no change needed).

Inline eviction spans are emitted **after** `_unlock()` to avoid calling backend methods while holding the lock. Capture before/after count to detect eviction, then emit a sub-span outside the lock.

---

## Modified: `Track/DiskCache.swift`

### 1. Add `traceContext` to every public method

Same pattern as MemoryCache.

### 2. Sync `set(object:forKey:)` — wrap and emit eviction sub-span

The inline eviction (lines 379–384 in current code) happens inside `_lock()/_unlock()`. Capture the `_cache.count` and `_cache.cost` before and after eviction. After `_unlock()`, if eviction occurred, emit a sub-span using the `traceContext`. The byte size attribute on the `set` span uses the `fileSize` computed during archiving.

### 3. `_unsafeTrim` — scope note

These are `private` on a `private extension DiskCache`, so they're file-private. No callers outside the file. Add `spanContext: TraceContext? = nil` to each; emit a sub-span around the file deletion loop. Called after the outer `_lock()/_unlock()` from the sync trim wrappers.

Wait — `_unsafeTrim` is called from *inside* `_lock()`. So it can't emit spans (would risk backend re-entrancy into the lock). Instead:

**Revised approach for `DiskCache` trim:** The public `trim(toCount:traceContext:)` (sync) calls `_lock()`, then `_unsafeTrim(...)`, then `_unlock()`. The span wraps the whole `_lock/unlock` sequence from the public method. Outcome is `.evicted`. The byte count removed can be captured by making `_unsafeTrim` return the bytes removed.

### 4. Async trim — capture-then-pass

```swift
func trim(toCount countLimit: UInt, completion: DiskCacheAsyncCompletion?,
          traceContext: TraceContext? = nil) {
    let capturedContext = traceContext
    _queue.async { [weak self] in
        guard let strongSelf = self else { completion?(nil, nil, nil); return }
        strongSelf.trim(toCount: countLimit, traceContext: capturedContext)
        completion?(strongSelf, nil, nil)
    }
}
```

---

## Modified: `Track/Cache.swift`

### 1. Add `traceContext` to every public method

Same defaulted-nil pattern.

### 2. Sync methods — `_withSpan` at facade level, pass span as sub-context

```swift
func set(object: NSCoding, forKey key: String, traceContext: TraceContext? = nil) {
    _withSpan(named: "Cache.set", operation: .set, key: key,
              cacheName: name, layer: .unified, context: traceContext) { childSpan in
        memoryCache.set(object: object, forKey: key, traceContext: childSpan)
        diskCache.set(object: object, forKey: key, traceContext: childSpan)
        return ((), .set, nil)
    }
}
```

For `object(forKey:)` sync: check memory first; if miss, check disk and promote. Child spans from both lookups nest under the `Cache.get` span.

### 3. Async `object(forKey:completion:traceContext:)` — nested async re-wire

This is the most complex change. The trace tree for a disk-hit should be:
```
Cache.get [unified, outcome=hit]
  MemoryCache.get [memory, outcome=miss]
  DiskCache.get   [disk,   outcome=hit]
  MemoryCache.set [memory, outcome=set]  ← promotion
```

Implementation outline:
```swift
func object(forKey key: String, completion: CacheAsyncCompletion?,
            traceContext: TraceContext? = nil) {
    let capturedContext = traceContext
    _queue.async { [weak self] in
        guard let strongSelf = self else { return }

        // Start Cache.get span inside async block for accurate timing
        let backend = TraceConfiguration.backend
        let topSpan: TraceContext? = capturedContext.flatMap {
            backend.startSpan(named: "Cache.get", parent: $0,
                              attributes: /* .get, .unified, key */)
        }
        let subContext: TraceContext? = topSpan ?? capturedContext

        strongSelf.memoryCache.object(forKey: key, completion: { [weak strongSelf] (_, memKey, memObject) in
            guard let s = strongSelf else { return }
            if let memObject = memObject {
                // End Cache.get span with .hit
                topSpan.map { backend.endSpan($0, finalAttributes: /* .hit */, error: nil) }
                s._queue.async { [weak s] in completion?(s, memKey, memObject) }
            } else {
                s.diskCache.object(forKey: key, completion: { [weak s] (_, diskKey, diskObject) in
                    guard let s = s else { return }
                    if let dk = diskKey, let dobj = diskObject as? AnyObject {
                        // Promotion: MemoryCache.set is child of Cache.get
                        s.memoryCache.set(object: dobj, forKey: dk, completion: nil,
                                          traceContext: subContext)
                    }
                    let outcome: CacheOutcome = diskObject != nil ? .hit : .miss
                    topSpan.map { backend.endSpan($0, finalAttributes: /* outcome */, error: nil) }
                    s._queue.async { [weak s] in completion?(s, diskKey, diskObject) }
                }, traceContext: subContext)   // DiskCache.get is child of Cache.get
            }
        }, traceContext: subContext)           // MemoryCache.get is child of Cache.get
    }
}
```

### 4. Subscript — not traced

Subscripts cannot have extra parameters in Swift. Document this; callers needing tracing should use `object(forKey:traceContext:)` / `set(object:forKey:traceContext:)`.

---

## Context Leakage Prevention

**Rule:** Trace context travels *only* as captured `let` constants in closures and as explicit function parameters. It is **never** stored in mutable shared state (no DispatchQueue-specific data, no thread-local, no property on the cache object).

Each `_queue.async` invocation creates a new closure with its own captured `let capturedContext`. Two concurrent calls never share context storage.

---

## File Creation Order

1. `Track/Tracing.swift` — new file, no dependencies
2. `Track/MemoryCache.swift` — add `name`, `systemEventContext`, span wiring
3. `Track/DiskCache.swift` — span wiring, `_unsafeTrim` return values
4. `Track/Cache.swift` — facade span wiring, nested async object rewrite

---

## Critical Files

| File | Change |
|------|--------|
| `Track/Tracing.swift` | **New.** All protocols, types, `NoOpTraceBackend`, `TraceConfiguration`, `_withSpan` |
| `Track/MemoryCache.swift` | Add `name`, `systemEventContext`; add `traceContext:` to 14 public methods; wire `_unsafeSet` |
| `Track/DiskCache.swift` | Add `traceContext:` to 14 public methods; `_unsafeTrim` return bytes removed; wire inline eviction |
| `Track/Cache.swift` | Add `traceContext:` to 8 public methods; rewrite nested async `object(forKey:)` |

---

## Verification

### Test double

Create `RecordingTraceBackend` (test target only):
- Implements `TraceBackend`
- Stores `[(name: String, startAttrs: CacheSpanAttributes, endAttrs: CacheSpanAttributes?, error: Error?)]`
- Each `startSpan` returns a `RecordingContext` that has a unique ID and records its parent

### Test cases

1. **Zero-tracing fast path:** Call any public method without `traceContext`. Assert `RecordingTraceBackend.spans.isEmpty`.
2. **`startSpan` returning nil suppresses `endSpan`:** Backend returns nil from `startSpan`. Assert `endSpan` is never called.
3. **Memory hit:** `memoryCache.set(...)` then `memoryCache.object(forKey:traceContext:)`. Assert one `.set/.set` span and one `.get/.hit` span, both children of the provided root context.
4. **Memory miss:** `memoryCache.object(forKey:traceContext:)` for absent key. Assert one `.get/.miss` span.
5. **Disk hit + promotion via `Cache`:** Set via `diskCache.set` directly, call `cache.object(forKey:traceContext:)`. Assert 4 spans: `Cache.get`, `MemoryCache.get`(miss), `DiskCache.get`(hit), `MemoryCache.set`(set). Assert parent–child nesting via `RecordingContext.parentId`.
6. **Explicit async trim:** `memoryCache.trim(toCount:completion:traceContext:)`. Assert one `.trim/.evicted` span with correct `trimDimension`.
7. **Auto-eviction inline:** Set `countLimit = 2`, insert 3 items with a root context. Assert a `MemoryCache.autoEvict` sub-span is emitted as a child of the third `set` span.
8. **Concurrency — no leakage:** Dispatch 100 concurrent `cache.object(forKey:...)` calls, each with a distinct `RecordingContext` carrying a unique ID. After all complete, assert every recorded span references the correct parent ID and no cross-contamination occurred.
9. **System event context:** Set `memoryCache.systemEventContext = rootCtx`, post `didReceiveMemoryWarningNotification`, assert a `removeAll` span with `rootCtx` as parent.
10. **No-op backend baseline:** With `NoOpTraceBackend`, run 100,000 iterations of `memoryCache.object(forKey:)` with a non-nil context. Use `XCTestCase.measure` and assert performance within 5% of baseline (no context passed).
