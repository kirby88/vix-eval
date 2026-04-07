## Implementation Plan: Distributed Tracing with Context Propagation

### Overview

The library is a Swift iOS cache composed of three layers:
- `Cache` — top-level coordinator (`/workspace/Track/Cache.swift`)
- `MemoryCache` — LRU in-memory cache (`/workspace/Track/MemoryCache.swift`)
- `DiskCache` — LRU disk-backed cache (`/workspace/Track/DiskCache.swift`)
- `LinkedList.swift` — internal data structure, not modified

The design must satisfy these constraints:
1. No hard dependency on any specific tracing SDK
2. Every public method creates a child span if a trace context is provided
3. Spans record: cache name, key, outcome, byte sizes
4. Async eviction propagates the originating trace context
5. No trace context leakage across concurrent operations

---

### Architectural Decisions

**Swappable backend via protocol + optional injection**

The library defines a `TraceBackend` protocol that the caller implements and registers. The library holds a weak or optional reference to the backend. If no backend is registered, all tracing calls are no-ops. This avoids any import of OpenTelemetry, os.signpost, or any other framework.

**Explicit context threading, not ambient/thread-local**

Swift's `DispatchQueue` does not provide safe ambient context propagation — context stored in thread-local or queue-specific storage can bleed across `async` blocks on a shared concurrent queue. The only safe approach is explicit context passing: every public method that accepts async completion gains an optional `TraceContext` parameter. For backward compatibility, these parameters are optional and default to `nil`, so existing call sites are unchanged.

**Span ownership model**

The caller creates a root span and passes its context. The library creates a child span, records attributes, and ends it. The library never holds onto or stores trace contexts beyond the scope of a single operation.

**Eviction context capture**

When trim/eviction happens synchronously inside a `set` (within the lock), the trace context for the originating `set` is available on the stack and can be passed into the internal trim helpers. When trim is called explicitly (async or sync), the caller-provided context travels with it.

---

### New File: `/workspace/Track/Tracing.swift`

This is the only new file. It defines:

```swift
// 1. TraceContext: an opaque value type the library passes around
public struct TraceContext {
    public let spanContext: AnyObject  // opaque, backend-owned
    public init(spanContext: AnyObject) { ... }
}

// 2. SpanAttributes: what the library records on every span
public struct SpanAttributes {
    public var cacheName: String?
    public var key: String?
    public var outcome: String?      // "hit", "miss", "set", "removed", "evicted", "noop"
    public var bytesRead: UInt?
    public var bytesWritten: UInt?
}

// 3. TraceBackend protocol: implemented by the app, not the library
public protocol TraceBackend: AnyObject {
    // Called by the library to start a child span. Returns an opaque handle.
    func startSpan(named operationName: String,
                   childOf context: TraceContext?,
                   attributes: SpanAttributes) -> TraceContext?
    // Called when the operation finishes.
    func endSpan(_ context: TraceContext, attributes: SpanAttributes)
}

// 4. TraceBackendRegistry: a library-global weak holder
public final class TraceBackendRegistry {
    public static let shared = TraceBackendRegistry()
    public weak var backend: (AnyObject & TraceBackend)?
    // ... thread-safe set/get via a lock
}
```

Why a registry rather than injected per-cache? The library has `shareInstance` singletons and the `Cache` init does not accept a backend parameter; a global registry is consistent with the library's existing design and does not require changing any constructor signatures.

---

### Changes to `/workspace/Track/Cache.swift`

**Sync public methods** — add optional `traceContext: TraceContext? = nil` to every public method signature in the `public extension Cache` block:

- `set(object:forKey:traceContext:)` — starts a child span, calls through, ends span with `outcome: "set"` and `bytesWritten`
- `object(forKey:traceContext:)` — starts span, calls through, ends with `outcome: "hit"` or `"miss"`, and `bytesRead`
- `removeObject(forKey:traceContext:)` — starts span, calls through, ends with `outcome: "removed"`
- `removeAllObjects(traceContext:)` — starts span, calls through, ends with `outcome: "removed"`
- `subscript` — calls the traced `set`/`object` overloads with `nil` context (subscript cannot gain parameters; this is the correct behavior)

**Async public methods** — add optional `traceContext: TraceContext? = nil`:

- `set(object:forKey:traceContext:completion:)` — captures `traceContext` at call site, then inside the `_queue.async` block starts a child span using the **captured** context (not any ambient context). The closure captures the context value, not a reference, ensuring isolation.
- `object(forKey:traceContext:completion:)` — same pattern; the nested async callbacks to memory/disk also receive the same captured span context so the full read path is one logical span with sub-spans per layer
- `removeObject(forKey:traceContext:completion:)` — same
- `removeAllObjects(_:traceContext:)` — same

**Important isolation note for the async `object` method**: This method dispatches into `memoryCache.object(forKey:completion:)` and `diskCache.object(forKey:completion:)` with nested callbacks. The trace context must be a value captured at the top of the `_queue.async` block, not stored anywhere mutable, to avoid cross-operation leakage. Each async `object` invocation captures its own `TraceContext` value independently.

---

### Changes to `/workspace/Track/MemoryCache.swift`

Same pattern as `Cache`. Every method in `public extension MemoryCache` gains `traceContext: TraceContext? = nil`.

**Key attribute: bytesRead/bytesWritten**

`MemoryCache` stores `MemoryCacheObject` which has a `cost: UInt` field. Use `cost` as `bytesWritten` on set and `bytesRead` on get (when found).

**Outcome values**:
- `set` → `"set"`
- `object` found → `"hit"`, not found → `"miss"`
- `removeObject` → `"removed"`
- `removeAllObjects` → `"removed"`
- trim operations → `"evicted"` with count or cost as attribute

**Eviction context propagation**:
`_unsafeSet` currently calls `_unsafeTrim(toCost:)` and `_unsafeTrim(toCount:)` synchronously when limits are exceeded. These private helpers will gain an internal `traceContext` parameter (not public-facing). The `set` method passes its span context into `_unsafeSet`, which passes it into `_unsafeTrim`. Trim creates its own child span (`"MemoryCache.trim"`) under the originating set's context.

For async trim (the `trim(toCount:completion:)` family): the outer `_queue.async` block captures the caller-provided `traceContext` value. Inside, `trim(toCount:)` is called synchronously, which also receives the context. This is correct because the async dispatch captures the value before the closure executes.

---

### Changes to `/workspace/Track/DiskCache.swift`

Same pattern. Every method in `public extension DiskCache` gains `traceContext: TraceContext? = nil`.

**Key attribute: bytesRead/bytesWritten**

`DiskCacheObject` has `cost: UInt` (the `totalFileAllocatedSizeKey` value in bytes). Use this as `bytesWritten` on set and `bytesRead` on get (when found).

**Eviction context propagation**:
`set(object:forKey:)` calls `_unsafeTrim(toCost:)` and `_unsafeTrim(toCount:)` inside the lock. These helpers gain an internal `traceContext` parameter. The trim span is created as a child of the `set` span context — the same principle as `MemoryCache`.

The `DiskCache` init kicks off an async load: `_queue.async { _=self._createCacheDir(); _=self._loadFilesInfo(); self._unlock() }`. This is infrastructure initialization, not a user-triggered operation, so no trace context is applicable there. No change needed.

---

### Internal helper signature pattern

Private trim helpers across both cache classes are updated to accept context internally. The signature change is internal only (not `public`), preserving the public API surface except for the optional `traceContext` additions. Example:

```swift
// Before
fileprivate func _unsafeTrim(toCount countLimit: UInt)

// After
fileprivate func _unsafeTrim(toCount countLimit: UInt, traceContext: TraceContext? = nil)
```

Default `nil` means existing internal call sites that do not pass context continue to compile without change, and only call sites that have context need updating.

---

### Span naming convention

All span names follow `"TypeName.methodName"` to avoid collisions if multiple backends aggregate spans:

- `"Cache.set"`, `"Cache.object"`, `"Cache.removeObject"`, `"Cache.removeAllObjects"`
- `"MemoryCache.set"`, `"MemoryCache.object"`, etc.
- `"DiskCache.set"`, `"DiskCache.object"`, etc.
- `"MemoryCache.trim"`, `"DiskCache.trim"` for eviction spans

---

### Context isolation guarantee

The library exclusively uses value capture in `async` closures. No `TraceContext` is stored as a property of any cache class. Each `async` dispatch captures its own copy of `TraceContext?` from the call-site stack frame. Since `TraceContext` is a struct (value type), copying it into a closure creates an independent copy. This satisfies the requirement that concurrent operations on the same cache instance never share or leak trace state.

---

### Backward compatibility

All new `traceContext` parameters use `= nil` defaults. Every existing call site — in `Demo/`, or consumer code — compiles without changes. The `subscript` operator cannot accept a context parameter but calls the traced methods with `nil`, which is correct.

---

### Sequencing

1. Create `/workspace/Track/Tracing.swift` with `TraceContext`, `SpanAttributes`, `TraceBackend` protocol, and `TraceBackendRegistry`.
2. Modify `/workspace/Track/MemoryCache.swift`: add `traceContext` to all public methods, internal trim helpers, and `_unsafeSet`.
3. Modify `/workspace/Track/DiskCache.swift`: add `traceContext` to all public methods and internal trim helpers.
4. Modify `/workspace/Track/Cache.swift`: add `traceContext` to all public methods; thread context through the nested async `object` callback chain.

Steps 2 and 3 can be done in parallel. Step 4 depends on step 1 (for the types) but not on steps 2/3 (the internal calls just pass context through).

---

### Critical Files for Implementation

- `/workspace/Track/Cache.swift` — Core coordinator; all public async and sync methods need tracing; the nested async object lookup requires careful context threading
- `/workspace/Track/MemoryCache.swift` — Primary in-memory cache; all public methods + private eviction helpers need context propagation
- `/workspace/Track/DiskCache.swift` — Disk-backed cache; same treatment as MemoryCache plus byte-size extraction from file attributes
- `/workspace/Track/Tracing.swift` — New file; defines all tracing abstractions (TraceContext, SpanAttributes, TraceBackend, TraceBackendRegistry) on which the other three files depend