# Distributed Tracing for Track Cache Library

## Context

Track is a Swift 5 / iOS 8+ two-tier cache library (MemoryCache + DiskCache backed by an LRU linked list). It uses GCD (not async/await or actors): concurrent `DispatchQueue` + `DispatchSemaphore` for mutual exclusion. There is zero existing instrumentation.

The goal is to add distributed tracing that:
- Creates a child span per public method, parented to an optional caller-provided `TrackTraceContext`
- Records cache name, key, outcome, and byte sizes as span attributes
- Propagates the originating trace context into async eviction background work
- Uses a swappable tracer backend (protocol-only — no SDK dependency)
- Isolates contexts across concurrent GCD operations (closure-capture semantics, no thread-locals)

---

## Files to create / modify

| File | Action |
|---|---|
| `Track/Tracing.swift` | **Create** — all protocol + no-op types |
| `Track/Cache.swift` | **Modify** — add `tracer`, `context:` params, spans |
| `Track/MemoryCache.swift` | **Modify** — add `tracer`, `context:` params, spans, eviction propagation |
| `Track/DiskCache.swift` | **Modify** — add `tracer`, `context:` params, spans, eviction propagation |

---

## Step 1 — Create `Track/Tracing.swift`

### Protocols

```swift
/// Opaque carrier for an in-flight trace context (W3C traceparent, OTel, etc.)
public protocol TrackTraceContext: AnyObject {}

/// A single unit of work in a trace.
public protocol TrackSpan: AnyObject {
    /// Context that can be used as `parent` for child spans.
    var context: TrackTraceContext { get }
    func setAttribute(_ key: String, stringValue value: String)
    func setAttribute(_ key: String, intValue value: Int)
    func end()
}

/// Factory — the only integration point callers must implement.
public protocol TrackTracer: AnyObject {
    func startSpan(named name: String, parent: TrackTraceContext?) -> TrackSpan
}
```

### No-op defaults (so library works with zero configuration)

```swift
public final class TrackNoopTracer: TrackTracer {
    public static let shared = TrackNoopTracer()
    public func startSpan(named name: String, parent: TrackTraceContext?) -> TrackSpan {
        return TrackNoopSpan.shared
    }
}

public final class TrackNoopSpan: TrackSpan {
    public static let shared = TrackNoopSpan()
    private static let _ctx = _TrackNoopContext()
    public var context: TrackTraceContext { return TrackNoopSpan._ctx }
    public func setAttribute(_ key: String, stringValue value: String) {}
    public func setAttribute(_ key: String, intValue value: Int) {}
    public func end() {}
}

private final class _TrackNoopContext: TrackTraceContext {}
```

### Attribute key + outcome constants

```swift
public enum TrackSpanAttributes {
    public static let cacheName    = "track.cache.name"
    public static let cacheKey     = "track.cache.key"
    public static let outcome      = "track.cache.outcome"
    public static let layer        = "track.cache.layer"   // "memory" | "disk" | "unified"
    public static let bytesRead    = "track.cache.bytes_read"
    public static let bytesWritten = "track.cache.bytes_written"
}

public enum TrackSpanOutcome {
    public static let hit     = "hit"
    public static let miss    = "miss"
    public static let set     = "set"
    public static let removed = "removed"
    public static let trimmed = "trimmed"
}
```

---

## Step 2 — Modify `MemoryCache.swift`

### 2a. Add `tracer` property to `MemoryCache`

```swift
/// Inject a tracer to record spans for every public operation.
/// Defaults to the no-op tracer; replace before first use.
public var tracer: TrackTracer = TrackNoopTracer.shared
```

### 2b. Async public methods — add `context:` parameter, create span *inside* the async block

Pattern (avoids double-spanning when async delegates to internal sync path):

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         context: TrackTraceContext? = nil,
         completion: MemoryCacheAsyncCompletion?) {
    _queue.async { [weak self, context] in
        guard let strongSelf = self else { completion?(nil, key, object); return }
        let span = strongSelf.tracer.startSpan(named: "track.memory_cache.set", parent: context)
        span.setAttribute(TrackSpanAttributes.cacheName, stringValue: "memory")
        span.setAttribute(TrackSpanAttributes.cacheKey, stringValue: key)
        span.setAttribute(TrackSpanAttributes.layer, stringValue: "memory")
        strongSelf._lock()
        strongSelf._unsafeSet(object: object, forKey: key, cost: cost,
                              evictionContext: span.context)
        strongSelf._unlock()
        span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.set)
        span.setAttribute(TrackSpanAttributes.bytesWritten, intValue: Int(cost))
        span.end()
        completion?(strongSelf, key, object)
    }
}
```

Same pattern for `object(forKey:context:completion:)` (records `hit`/`miss` + `bytesRead` from `MemoryCacheObject.cost`), `removeObject`, `removeAllObjects`, and all `trim(to*)` variants.

### 2c. Sync public methods — same span creation at call time

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         context: TrackTraceContext? = nil) {
    let span = tracer.startSpan(named: "track.memory_cache.set", parent: context)
    span.setAttribute(TrackSpanAttributes.cacheName, stringValue: "memory")
    span.setAttribute(TrackSpanAttributes.cacheKey, stringValue: key)
    span.setAttribute(TrackSpanAttributes.layer, stringValue: "memory")
    _lock()
    _unsafeSet(object: object, forKey: key, cost: cost, evictionContext: span.context)
    _unlock()
    span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.set)
    span.setAttribute(TrackSpanAttributes.bytesWritten, intValue: Int(cost))
    span.end()
}
```

### 2d. Propagate eviction context — update `_unsafeSet` and `_unsafeTrim`

`_unsafeSet` signature: add `evictionContext: TrackTraceContext? = nil`

Inside `_unsafeSet`, after mutation, before calling `_unsafeTrim`:

```swift
if _cache.cost > _costLimit {
    _unsafeTrim(toCost: _costLimit, evictionContext: evictionContext)
}
if _cache.count > _countLimit {
    _unsafeTrim(toCount: _countLimit, evictionContext: evictionContext)
}
```

`_unsafeTrim(toCount:evictionContext:)` — create a child span:

```swift
fileprivate func _unsafeTrim(toCount countLimit: UInt,
                             evictionContext: TrackTraceContext? = nil) {
    guard _cache.count > countLimit else { return }
    let span = tracer.startSpan(named: "track.memory_cache.evict", parent: evictionContext)
    span.setAttribute(TrackSpanAttributes.layer, stringValue: "memory")
    span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.trimmed)
    // ... existing LRU eviction loop ...
    span.end()
}
```

Same for `_unsafeTrim(toCost:evictionContext:)` and `_unsafeTrim(toAge:evictionContext:)`.

### 2e. Notification-triggered evictions

`_didReceiveMemoryWarningNotification` and `_didEnterBackgroundNotification` call `removeAllObjects(nil)`.
Since these are system events with no caller context, the resulting span will have no parent (root span). No change needed beyond the existing `removeAllObjects` already creating its own span when `context: nil`.

---

## Step 3 — Modify `DiskCache.swift`

Same structure as MemoryCache. Key differences:

- Layer attribute: `"disk"`
- Span names: `"track.disk_cache.set"`, `"track.disk_cache.get"`, etc.
- `bytesWritten`: read from `fileSize` (already computed in sync `set` as `DiskCacheObject.cost`)
- `bytesRead`: read from `_cache.object(forKey: key)?.cost` inside the sync `object(forKey:)` path

### 3a. Add `tracer` property to `DiskCache`

```swift
public var tracer: TrackTracer = TrackNoopTracer.shared
```

### 3b. Async methods — same span-inside-block pattern

The async `set` creates a span inside the block, then calls the **private** `_unsafeDiskSet(...)` directly (not the public sync `set`) to avoid double-spanning. The private helper contains the existing write + eviction logic and accepts `evictionContext`.

Actually, to minimise diff, it's cleaner to refactor the sync `set` body into an internal `_unsafeDiskSet(object:forKey:evictionContext:)` that both sync and async paths call after acquiring the lock.

### 3c. Propagate eviction context into `_unsafeTrim`

Same approach as MemoryCache: add `evictionContext: TrackTraceContext? = nil` parameter to `_unsafeTrim(toCount:)`, `_unsafeTrim(toCost:)`, `_unsafeTrim(toAge:)`. Create child eviction spans inside each.

In sync `set`, the sequence becomes:

```swift
func set(object: NSCoding, forKey key: String, context: TrackTraceContext? = nil) {
    let span = tracer.startSpan(named: "track.disk_cache.set", parent: context)
    // ... set attributes ...
    guard let fileURL = _generateFileURL(key, path: cacheURL) else { span.end(); return }
    _lock()
    var fileSize: UInt = 0
    if NSKeyedArchiver.archiveRootObject(object, toFile: fileURL.path) {
        // ... existing date + size logic ...
        fileSize = /* computed from file attributes */
        _cache.set(object: DiskCacheObject(key: key, cost: fileSize, date: date), forKey: key)
    }
    if _cache.cost > _costLimit { _unsafeTrim(toCost: _costLimit, evictionContext: span.context) }
    if _cache.count > _countLimit { _unsafeTrim(toCount: _countLimit, evictionContext: span.context) }
    _unlock()
    span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.set)
    span.setAttribute(TrackSpanAttributes.bytesWritten, intValue: Int(fileSize))
    span.end()
}
```

---

## Step 4 — Modify `Cache.swift`

### 4a. Add `tracer` property + propagate to sub-caches

```swift
public var tracer: TrackTracer = TrackNoopTracer.shared {
    didSet {
        memoryCache.tracer = tracer
        diskCache.tracer = tracer
    }
}
```

Setting `Cache.tracer` propagates to both sub-caches automatically.

### 4b. Add `context:` to all public methods

The `Cache` layer spans use layer `"unified"` and span names like `"track.cache.set"`. Span context is passed as parent to sub-cache calls.

Example sync `set`:

```swift
func set(object: NSCoding, forKey key: String, context: TrackTraceContext? = nil) {
    let span = tracer.startSpan(named: "track.cache.set", parent: context)
    span.setAttribute(TrackSpanAttributes.cacheName, stringValue: name)
    span.setAttribute(TrackSpanAttributes.cacheKey, stringValue: key)
    span.setAttribute(TrackSpanAttributes.layer, stringValue: "unified")
    memoryCache.set(object: object, forKey: key, context: span.context)
    diskCache.set(object: object, forKey: key, context: span.context)
    span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.set)
    span.end()
}
```

Example sync `object(forKey:)`:

```swift
func object(forKey key: String, context: TrackTraceContext? = nil) -> AnyObject? {
    let span = tracer.startSpan(named: "track.cache.get", parent: context)
    span.setAttribute(TrackSpanAttributes.cacheName, stringValue: name)
    span.setAttribute(TrackSpanAttributes.cacheKey, stringValue: key)
    span.setAttribute(TrackSpanAttributes.layer, stringValue: "unified")
    if let object = memoryCache.object(forKey: key, context: span.context) {
        span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.hit)
        span.end()
        return object
    }
    if let object = diskCache.object(forKey: key, context: span.context) {
        memoryCache.set(object: object, forKey: key, context: span.context)
        span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.hit)
        span.end()
        return object
    }
    span.setAttribute(TrackSpanAttributes.outcome, stringValue: TrackSpanOutcome.miss)
    span.end()
    return nil
}
```

Async methods: span created *inside* the `_queue.async` block with captured `context`.

### 4c. Subscripts

Subscripts do not accept a `context:` parameter (Swift limitation). They delegate to `object(forKey:)` / `set(object:forKey:)` with `context: nil`, creating root spans. Document this limitation.

---

## Context isolation guarantee

Since every async operation captures `context` as a local closure variable at dispatch time (not in any shared mutable property), concurrent operations on different GCD tasks cannot see each other's contexts. No thread-local storage is used. Spans are stack-local variables; they cannot leak across concurrent closures.

---

## Backward compatibility

All new `context:` parameters have a default value of `nil`, so all existing call sites continue to compile and run unchanged. When `context` is nil, a root span is created (or the noop tracer emits nothing).

---

## Verification

1. **No SDK dependency**: confirm `Track.podspec` lists no new pod dependencies after the change.
2. **Compile check**: `xcodebuild build -project Framework/Track.xcodeproj -scheme Track` (or swift build if Package.swift exists).
3. **Manual integration test**: inject a test `TrackTracer` that records span names and attributes into an array; call `Cache.set/object/remove` and assert:
   - Span names include `"track.cache.set"`, `"track.memory_cache.set"`, `"track.disk_cache.set"`
   - Attribute `"track.cache.key"` matches the key used
   - `"track.cache.outcome"` is `"hit"` for a second read of the same key
   - `"track.cache.bytes_written"` > 0 for disk cache after a write
4. **Eviction test**: configure a `DiskCache` with `costLimit = 1`, write two objects, assert an eviction span is emitted as a child of the write span (parent context matches).
5. **Isolation test**: dispatch 100 concurrent async reads/writes each with distinct trace contexts; assert no span's recorded key attribute belongs to a different concurrent operation's key.
