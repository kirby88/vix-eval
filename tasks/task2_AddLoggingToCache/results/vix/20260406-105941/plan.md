## Implementation Plan: Distributed Tracing with Context Propagation

### Overview

The plan adds a pluggable tracing layer to the Track cache library. The design introduces a thin abstraction (`TraceBackend`) that the library calls into, a `TraceContext` value type that callers provide per-operation, and instrumentation at every public method on `Cache`, `MemoryCache`, and `DiskCache`. No third-party SDK is imported anywhere in the library.

---

### Architectural Decisions

**1. Value-typed TraceContext, not thread-local storage**

Thread-locals (or `TaskLocal` in Swift Concurrency) are tempting but dangerous here. The library uses `DispatchQueue`-based concurrency, not `async`/`await`, so `TaskLocal` does not propagate across `_queue.async { }` hops automatically. Thread-local storage would leak context between unrelated concurrent operations sharing the same thread. Instead, `TraceContext` is an explicit, opaque value type that callers pass to every public method. Inside async dispatch blocks, the context is captured in the closure's capture list. This is the only leak-free approach for `DispatchQueue`-based concurrency.

**2. Protocol-based backend (`TraceBackend`), not a concrete type**

The library defines the protocol. Consumers assign a conforming object to a global (or per-cache) registry. The library never imports any tracing SDK. A no-op default backend is provided so existing call sites need zero changes.

**3. New overloads, not signature replacement**

All existing public method signatures are preserved unchanged. New overloads add an optional `traceContext: TraceContext? = nil` parameter. This maintains full source compatibility — existing callers compile without modification. Callers that want tracing pass a context; callers that do not pass nothing.

**4. Span lifecycle scoped to each method body**

Each public method calls `backend.startSpan(...)`, executes its work, then calls `span.end(...)` with outcome and measured attributes. For async methods, the span is started before the `_queue.async` dispatch and ended inside the dispatch block after the work completes, so it correctly encompasses the actual I/O.

**5. Byte size measurement**

For `set` operations: `NSKeyedArchiver.archivedData(withRootObject:)` is used to measure the serialized byte count. For `object` (get) operations: the same is done on the returned object when non-nil. This is the same data path the disk cache already serialises.

---

### New File: `/workspace/Track/Tracing.swift`

This single file contains the entire tracing abstraction. It keeps all tracing-related declarations in one place, making it easy to review and to swap out.

**Contents:**

```
// 1. TraceContext — an opaque value type wrapping an Any? payload.
//    The library itself never inspects the payload. Conforming backends
//    use it to reconstruct their own span/context handles.

public struct TraceContext {
    public let storage: Any?
    public init(_ storage: Any?) { self.storage = storage }
}

// 2. SpanOutcome — an enum the library uses to record whether an
//    operation hit, missed, stored, removed, or failed.

public enum SpanOutcome: String {
    case hit, miss, set, removed, trimmed, error
}

// 3. TraceSpan — a protocol representing a live span. The backend
//    returns a conforming object from startSpan. The library calls
//    end(outcome:bytesIn:bytesOut:) when work completes.

public protocol TraceSpan: AnyObject {
    func end(outcome: SpanOutcome, bytesIn: Int?, bytesOut: Int?)
}

// 4. TraceBackend — the protocol implementors wire up. A no-op
//    default is provided.

public protocol TraceBackend: AnyObject {
    func startSpan(
        named operationName: String,
        cacheName: String,
        key: String?,
        parentContext: TraceContext?
    ) -> TraceSpan
}

// 5. NoOpTraceSpan / NoOpTraceBackend — zero-cost defaults.

final class NoOpTraceSpan: TraceSpan {
    func end(outcome: SpanOutcome, bytesIn: Int?, bytesOut: Int?) {}
}

public final class NoOpTraceBackend: TraceBackend {
    public static let shared = NoOpTraceBackend()
    public func startSpan(...) -> TraceSpan { return NoOpTraceSpan() }
}

// 6. TraceRegistry — a global registry with a single mutable backend.
//    Assigning a backend is the only global mutation the library performs.

public final class TraceRegistry {
    public static var backend: TraceBackend = NoOpTraceBackend.shared
}
```

---

### Helper: Byte Size Measurement

A private free function `_serializedByteCount(_ object: NSCoding) -> Int?` lives in `Tracing.swift`. It uses `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: false)` (available since iOS 11 / macOS 10.13) with a fallback to the deprecated `archivedData(withRootObject:)` for the iOS 8 deployment target declared in the podspec. The function returns `nil` on failure to avoid masking serialization errors.

---

### Modifications to `/workspace/Track/Cache.swift`

Every public method on `Cache` gains a new overload accepting `traceContext: TraceContext? = nil`. The original non-context signatures remain and delegate to the new overloads with `traceContext: nil`.

**Async set:**
```swift
func set(object: NSCoding, forKey key: String,
         traceContext: TraceContext? = nil,
         completion: CacheAsyncCompletion?) {
    let span = TraceRegistry.backend.startSpan(
        named: "cache.set", cacheName: name, key: key,
        parentContext: traceContext)
    let bytesIn = _serializedByteCount(object)
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.end(outcome: .error, bytesIn: bytesIn, bytesOut: nil)
            completion?(nil, key, object); return
        }
        strongSelf.set(object: object, forKey: key)
        span.end(outcome: .set, bytesIn: bytesIn, bytesOut: nil)
        completion?(strongSelf, key, object)
    }
}
```

The span is captured by the closure (value capture of the `TraceSpan` reference). Because `TraceSpan` is `AnyObject`, the closure holds a strong reference to the concrete span object returned by the backend. This correctly propagates the originating context across the dispatch hop.

**Async object (get):**
Start span before dispatch, end inside with `.hit`/`.miss` outcome and `bytesOut` from the returned object's serialized size.

**Sync set/get/remove:**
The span wraps the synchronous call entirely within the same stack frame. Start before the call, end after.

**Subscript:**
The subscript getter and setter call through to `object(forKey:)` and `set(object:forKey:)` respectively. These already go through the instrumented methods, so the subscript itself does not need a separate span — it would double-count. The subscript is left as-is.

---

### Modifications to `/workspace/Track/MemoryCache.swift`

Same pattern as `Cache`. Every `public` method in the `public extension MemoryCache` block gains an overload with `traceContext: TraceContext? = nil`.

Key difference: `MemoryCache` does not have a `name` property. The `cacheName` attribute passed to `startSpan` will be a constant string `"MemoryCache"`. If a user creates `Cache` and then uses `memoryCache` directly, they can pass the cache name themselves via the context-bearing overloads.

The trim operations (`trim(toCount:)`, `trim(toCost:)`, `trim(toAge:)`) are also public and must be instrumented. The outcome for trim completions will be `.trimmed`.

**Async eviction context propagation:**

The `_didReceiveMemoryWarningNotification` and `_didEnterBackgroundNotification` handlers call `removeAllObjects(nil)`. These are system-triggered and have no caller trace context, so they correctly produce no span (they call the non-context overload).

The critical eviction case is the inline trim triggered at the end of `set` (the calls to `_unsafeTrim` after `_cache.cost > _costLimit`). This eviction is synchronous and happens within the same `set` span, so it is already covered — no separate span is needed for synchronous trim-during-set.

---

### Modifications to `/workspace/Track/DiskCache.swift`

Same pattern. Every `public` method in `public extension DiskCache` gains an overload with `traceContext: TraceContext? = nil`.

The disk cache `set(object:forKey:)` sync method already computes `fileSize` via `URLResourceKey.totalFileAllocatedSizeKey`. This value is available after the write succeeds; pass it as `bytesIn` to `span.end`.

The disk cache `object(forKey:)` sync method reads via `_unsafeObject(forKey:key)`. After the read, the returned object's serialized size is measured via `_serializedByteCount` for `bytesOut`.

**Background init unlock concern:** The `DiskCache.init` does `_queue.async { _=self._createCacheDir(); _=self._loadFilesInfo(); self._unlock() }`. This is infrastructure initialization, not a public operation, and is correctly left un-instrumented.

---

### Context Propagation Across Actor Hops — Detailed Design

The word "actor" here refers to the `DispatchQueue` hops, not Swift actors. The invariant to maintain:

> A `TraceContext` passed by caller A must not appear inside work dispatched by an unrelated concurrent caller B.

This is guaranteed by the overload design:
- Each call to a public method captures its own `span` (returned by `startSpan`) in its own closure.
- The `TraceContext` is a value type (`struct`) — it is copied into the closure's capture list, not shared via a reference.
- No global mutable `currentContext` exists anywhere in the library.

Because there is no implicit context propagation mechanism (no thread-local, no `TaskLocal`), context isolation is structural: each closure owns exactly the `TraceContext` it was given, and nothing else can see it.

---

### Sequence of Implementation

1. **Create `/workspace/Track/Tracing.swift`** — defines `TraceContext`, `SpanOutcome`, `TraceSpan`, `TraceBackend`, `NoOpTraceBackend`, `TraceRegistry`, and `_serializedByteCount`.

2. **Modify `/workspace/Track/MemoryCache.swift`** — add `traceContext` overloads to every public method. The original non-context methods become one-line delegates to the new overloads.

3. **Modify `/workspace/Track/DiskCache.swift`** — same treatment. Use the already-computed `fileSize` in the sync `set` for `bytesIn`.

4. **Modify `/workspace/Track/Cache.swift`** — add `traceContext` overloads to every public method. The `Cache` layer starts its own span and passes `traceContext` down to `memoryCache` and `diskCache` calls so child operations also produce child spans.

   Note: when `Cache.set` calls `memoryCache.set` and `diskCache.set`, it should pass the same `traceContext` so those calls appear as children of the Cache span. The `startSpan` method signature accepts a `parentContext: TraceContext?` — this is the mechanism. The backend is responsible for interpreting the context as a parent.

5. **Update `/workspace/Track.podspec`** (if needed) — no new dependencies are added, so the podspec needs no changes.

---

### What is NOT Instrumented

- `makeIterator()` / `CacheGenerator.next()` — iteration is a sequence of reads; instrumenting every `next()` call would produce enormous span noise. Iteration is left un-instrumented.
- `LRU`, `LinkedList` internals — private, not public API.
- `_unsafeTrim`, `_unsafeSet`, `_unsafeObject` — private helpers always called within an already-instrumented public method.
- `MemoryCache.shareInstance` / `DiskCache.shareInstance` — property access, not operations.

---

### Critical Files for Implementation

- `/workspace/Track/Tracing.swift` - New file: defines the entire tracing abstraction (TraceContext, TraceSpan, TraceBackend, NoOpTraceBackend, TraceRegistry, byte-size helper)
- `/workspace/Track/Cache.swift` - Top-level Cache public methods to instrument; also where context is threaded from Cache down into MemoryCache and DiskCache
- `/workspace/Track/MemoryCache.swift` - All public MemoryCache methods to instrument with traceContext overloads
- `/workspace/Track/DiskCache.swift` - All public DiskCache methods to instrument; the fileSize variable in sync set is the primary bytesIn source