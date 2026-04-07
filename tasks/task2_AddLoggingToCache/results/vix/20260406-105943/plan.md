## Implementation Plan: Distributed Tracing with Context Propagation

### Overview

This is a Swift iOS caching library (Track) with four source files: `Cache.swift`, `MemoryCache.swift`, `DiskCache.swift`, and `LinkedList.swift`. The library uses `DispatchQueue` with semaphore locks, has no existing tracing, and targets iOS 8+ with Swift 3/5.

The key design challenges are:
1. No Swift concurrency (`async/await`) — only GCD (`DispatchQueue`)
2. GCD does not propagate context automatically across queue hops the way Swift actors do
3. The library must not import any specific tracing SDK
4. Trace context must not leak between concurrent operations sharing the same queue

---

### Architectural Decisions

#### 1. Swappable Backend via Protocol Abstraction

Define a `TraceBackend` protocol with a `Span` associated type replaced by an existential wrapper, in a new file `Tracing.swift`. The library ships a no-op default implementation so zero-configuration usage is unchanged.

```
public protocol TraceSpan {
    func setAttribute(key: String, value: String)
    func setAttribute(key: String, value: Int)
    func end()
}

public protocol TraceBackend {
    func startSpan(name: String, parentContext: TraceContext?) -> (span: TraceSpan, context: TraceContext)
}

public struct TraceContext {
    public let storage: AnyObject   // opaque carrier for SDK-specific state
    public init(storage: AnyObject) { self.storage = storage }
}
```

The `TraceContext` is an opaque value type wrapping an `AnyObject` carrier. This lets any SDK store whatever it needs (OpenTelemetry span context, Zipkin B3 headers, etc.) without the library knowing about it.

A `NoOpTraceBackend` and `NoOpSpan` are provided as defaults.

#### 2. Context Propagation Without Leaking Across GCD Hops

GCD's `DispatchQueue` does not carry task-local storage between `async` blocks the way Swift's structured concurrency does. The idiomatic solution without Swift concurrency is to **explicitly thread `TraceContext?` as a parameter** through every public method. This is the only approach that is:

- Leak-proof: each operation carries exactly the context it was given
- Non-invasive to unrelated concurrent operations sharing the same queue
- Backward-compatible: all parameters default to `nil`

This means every public `set`, `object`, `removeObject`, `removeAllObjects`, and `trim` method on `Cache`, `MemoryCache`, and `DiskCache` gains an optional `traceContext: TraceContext? = nil` parameter.

#### 3. Span Lifecycle and Attributes

Each public method:
1. Calls `traceBackend.startSpan(name: operationName, parentContext: traceContext)` to get `(span, childContext)`
2. Executes its operation
3. Records attributes: `cache.name`, `cache.key`, `outcome` (hit/miss/set/removed), `bytes` (size in bytes when available)
4. Calls `span.end()`

For async methods, the span wraps the entire async dispatch block (from queue entry to completion callback invocation).

#### 4. Eviction Propagation

When `_unsafeTrim(toCount:)`, `_unsafeTrim(toCost:)`, and `_unsafeTrim(toAge:)` are triggered as side effects of a `set` operation, the originating span's `childContext` is passed explicitly into the trim helpers so eviction spans appear as children of the write span.

The `_unsafeTrim` private methods gain an internal `traceContext: TraceContext?` parameter (not public API).

#### 5. Backend Registration

A global (module-level) `var traceBackend: TraceBackend` is placed in `Tracing.swift`, defaulting to `NoOpTraceBackend()`. Callers configure it once at app startup:

```swift
TrackCache.traceBackend = MyOpenTelemetryBackend()
```

This avoids passing the backend through every constructor while remaining fully swappable.

---

### New File

**`/workspace/Track/Tracing.swift`** — Contains:
- `TraceSpan` protocol
- `TraceBackend` protocol  
- `TraceContext` struct (opaque carrier)
- `NoOpSpan : TraceSpan`
- `NoOpTraceBackend : TraceBackend`
- `public var traceBackend: TraceBackend` module-level variable

---

### Changes to Existing Files

#### `/workspace/Track/Cache.swift`

1. Add `traceContext: TraceContext? = nil` to every public extension method signature (both sync and async variants of `set`, `object`, `removeObject`, `removeAllObjects`)
2. In each sync method body, call `traceBackend.startSpan`, pass `childContext` into `memoryCache` and `diskCache` calls, record attributes, call `span.end()`
3. In each async method body, capture `traceContext` in the closure, start span inside the async block, pass `childContext` forward
4. In `subscript` setter/getter, pass `nil` context (subscript cannot carry trace context without breaking the subscript signature; document this limitation)

#### `/workspace/Track/MemoryCache.swift`

1. Add `traceContext: TraceContext? = nil` to all public sync and async methods
2. In `set(object:forKey:cost:)` sync — start span, record `cache.name` (use class name), `key`, `cost` bytes, outcome = "set", pass `traceContext` into `_unsafeSet`
3. In `object(forKey:)` sync — start span, record hit/miss outcome, byte size from `MemoryCacheObject.cost`
4. In `removeObject(forKey:)` sync — start span, record key and outcome = "removed"
5. In `removeAllObjects()` sync — start span, record outcome = "removeAll"
6. In `trim(toCount:)`, `trim(toCost:)`, `trim(toAge:)` sync — start span, record limit and outcome
7. Propagate `traceContext` into `_unsafeTrim` variants (add internal parameter)
8. Async wrappers: capture `traceContext` before dispatching, pass it through

#### `/workspace/Track/DiskCache.swift`

Same treatment as `MemoryCache`:
1. Add `traceContext: TraceContext? = nil` to all public methods
2. In `set` sync — start span, record key, file size (already computed as `fileSize`), outcome = "set", pass context into trim side-effects
3. In `object` sync — start span, record key, file size from `DiskCacheObject.cost`, hit/miss outcome
4. In `removeObject`, `removeAllObjects` — span with outcome
5. In `trim` variants — span with limit attribute
6. In `_unsafeTrim` variants — add `traceContext: TraceContext?` parameter for eviction child spans
7. Async wrappers: capture context before dispatch

---

### Detailed Implementation Steps (Sequenced)

**Step 1 — Create `/workspace/Track/Tracing.swift`**

Define the full tracing abstraction:
- `TraceContext` struct with `AnyObject` storage
- `TraceSpan` protocol with `setAttribute` overloads and `end()`
- `TraceBackend` protocol with `startSpan(name:parentContext:) -> (TraceSpan, TraceContext)`
- `NoOpSpan` (empty implementations)
- `NoOpTraceBackend` (returns `NoOpSpan` and a dummy context)
- `public var traceBackend: TraceBackend = NoOpTraceBackend()`

**Step 2 — Modify `/workspace/Track/MemoryCache.swift`**

- Update all public method signatures to add `traceContext: TraceContext? = nil`
- Add span start/end to each sync method
- Update `_unsafeSet` and `_unsafeTrim` signatures to accept `traceContext: TraceContext?`
- Update async methods to capture and forward context
- Attribute constants: use string literals matching OpenTelemetry semantic conventions where applicable (`"cache.name"`, `"cache.key"`, `"cache.outcome"`, `"cache.bytes"`)

**Step 3 — Modify `/workspace/Track/DiskCache.swift`**

Same pattern as Step 2. The `set` method already computes `fileSize` — pass this directly to `span.setAttribute("cache.bytes", value: Int(fileSize))`.

**Step 4 — Modify `/workspace/Track/Cache.swift`**

- Add `traceContext: TraceContext? = nil` to public methods
- Propagate `childContext` from the outer Cache span into `memoryCache.*` and `diskCache.*` calls, so the memory and disk operations appear as children of the Cache operation
- This creates a proper two-level span tree: `Cache.set -> MemoryCache.set` and `Cache.set -> DiskCache.set`

**Step 5 — Verify Subscript Limitation is Documented**

The subscript `set`/`get` on `Cache`, `MemoryCache`, and `DiskCache` cannot accept a `traceContext` parameter by Swift language rules. Add a comment stating subscript operations are not traced; callers should use the explicit `set`/`object` methods for traced operations.

---

### Context Propagation Correctness Across Concurrent Operations

Because `TraceContext` is a value type (struct), each dispatched closure captures its own independent copy. Two concurrent `object(forKey:)` calls on the same cache with different parent contexts will each carry their own `TraceContext` copy into the queue block — there is no shared mutable state to leak between them. The semaphore lock only protects the LRU data structure, not the trace context.

For async eviction triggered by `set`: the `set` method starts a span, gets `childContext`, then calls the sync `set` internally (which eventually calls `_unsafeSet` then `_unsafeTrim`). By passing `childContext` explicitly into `_unsafeTrim`, the eviction span is a child of the write span. This correctly represents "this eviction happened because of this write" in the trace tree.

---

### What is NOT Changed

- `LinkedList.swift` — pure data structure, no cache semantics, no tracing needed
- `CacheGenerator` / `MemoryCacheGenerator` / `DiskCacheGenerator` — iteration is not a cache operation; adding tracing here would produce noisy, meaningless spans
- Constructor methods — no span needed for initialization
- `NotificationCenter` memory-warning handlers — these call `removeAllObjects(nil)` which will pass `nil` context, producing no span (since `NoOpTraceBackend` short-circuits)

---

### Critical Files for Implementation

- `/workspace/Track/Tracing.swift` - New file: defines TraceSpan, TraceBackend, TraceContext, NoOpBackend, and the module-level backend variable
- `/workspace/Track/MemoryCache.swift` - Core logic to modify: all public methods get traceContext parameter, span lifecycle, attribute recording, eviction propagation
- `/workspace/Track/DiskCache.swift` - Core logic to modify: same as MemoryCache, plus file-size byte attributes already computed in set
- `/workspace/Track/Cache.swift` - Facade layer: propagates childContext from Cache-level spans down into MemoryCache and DiskCache calls to build proper span trees