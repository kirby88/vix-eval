# Distributed Tracing for Track Cache Library

## Context

Track is a Swift 5 iOS two-tier LRU cache (MemoryCache + DiskCache). It has zero observability today. We need to add distributed tracing so callers can propagate their trace context into cache operations and see a span tree showing hit-tier, key, byte sizes, and outcome — without forcing a dependency on any specific tracing SDK.

The library is GCD-based (no Swift actors/async-await). Thread-local context propagation is unsafe with GCD thread pools (threads are reused), so **all context propagation is explicit parameter passing**.

---

## New File: `Track/Tracing.swift`

### Protocols (public)

```swift
// Reference type — safe to capture in GCD closures across hops
public protocol TraceContext: AnyObject {}

public protocol TraceSpan: AnyObject {
    func setAttribute(_ key: String, value: String)
    func setAttribute(_ key: String, value: Int)
    func setAttribute(_ key: String, value: UInt)
    func end()
}

public protocol TraceProvider: AnyObject {
    // Returns the new span AND the child context to propagate downstream.
    func startSpan(name: String, context: TraceContext?) -> (TraceSpan, TraceContext)
}
```

### Registry (public)

```swift
public final class TraceProviderRegistry {
    private static let _lock = NSLock()
    private static var _provider: TraceProvider?
    public static var shared: TraceProvider? {
        get { _lock.lock(); defer { _lock.unlock() }; return _provider }
        set { _lock.lock(); defer { _lock.unlock() }; _provider = newValue }
    }
}
```

### Internal helpers

```swift
// Noop types returned when no provider is registered
final class _NoopTraceContext: TraceContext {}
final class _NoopSpan: TraceSpan {
    func setAttribute(_ key: String, value: String) {}
    func setAttribute(_ key: String, value: Int) {}
    func setAttribute(_ key: String, value: UInt) {}
    func end() {}
}

// Called at top of every instrumented method
internal func _trackStartSpan(_ name: String, context: TraceContext?) -> (TraceSpan, TraceContext) {
    guard let provider = TraceProviderRegistry.shared else {
        return (_NoopSpan(), _NoopTraceContext())
    }
    return provider.startSpan(name: name, context: context)
}
```

---

## Attribute Schema

| Key | Type | Present on |
|---|---|---|
| `cache.name` | String | all spans |
| `cache.tier` | `"memory"` / `"disk"` / `"unified"` | all spans |
| `cache.operation` | `"set"` / `"get"` / `"remove"` / `"remove_all"` / `"trim_count"` / `"trim_cost"` / `"trim_age"` | all spans |
| `cache.key` | String | key-bearing operations |
| `cache.outcome` | `"stored"` / `"hit"` / `"miss"` / `"removed"` / `"cleared"` / `"trimmed"` / `"dropped"` | all spans |
| `cache.bytes` | UInt | set (cost/file size), get hits |
| `cache.hit_tier` | `"memory"` / `"disk"` / `"none"` | unified `get` spans only |

---

## Span Naming

| Layer | Span name |
|---|---|
| Cache (unified) | `track.set`, `track.get`, `track.remove`, `track.remove_all` |
| MemoryCache | `track.memory.set`, `track.memory.get`, `track.memory.remove`, `track.memory.remove_all`, `track.memory.trim` |
| DiskCache | `track.disk.set`, `track.disk.get`, `track.disk.remove`, `track.disk.remove_all`, `track.disk.trim` |

Async method spans wrap their sync method spans. The parent/child relationship shows queue-wait latency (parent duration − child duration).

---

## Changes to `Track/MemoryCache.swift`

Add `context: TraceContext? = nil` to **all** public sync and async methods. Existing callers compile unchanged (default nil).

### Signature additions (public extension)

```swift
// Async — add context parameter after key/cost, before completion
func set(object:forKey:cost:context:completion:)
func object(forKey:context:completion:)
func removeObject(forKey:context:completion:)
func removeAllObjects(_:context:)       // context after completion
func trim(toCount:context:completion:)
func trim(toCost:context:completion:)
func trim(toAge:context:completion:)

// Sync — add context parameter at end
func set(object:forKey:cost:context:)
func object(forKey:context:) -> AnyObject?
func removeObject(forKey:context:)
func removeAllObjects(context:)
func trim(toCount:context:)
func trim(toCost:context:)
func trim(toAge:context:)
```

### Sync method pattern (example: `set`)

Span wraps the full method including semaphore wait. Span starts before `_lock()`, ends after `_unlock()`.

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0, context: TraceContext? = nil) {
    let (span, _) = _trackStartSpan("track.memory.set", context: context)
    span.setAttribute("cache.tier", value: "memory")
    span.setAttribute("cache.name", value: "MemoryCache")
    span.setAttribute("cache.operation", value: "set")
    span.setAttribute("cache.key", value: key)
    span.setAttribute("cache.bytes", value: cost)
    _lock()
    _unsafeSet(object: object, forKey: key, cost: cost)
    _unlock()
    span.setAttribute("cache.outcome", value: "stored")
    span.end()
}
```

### Async method pattern — delegates to sync with child context

Async span is the parent; it dispatches to queue and calls the sync version with `childContext`, which creates the child span. This gives the queue-wait/execution split in traces.

```swift
func set(object: AnyObject, forKey key: String, cost: UInt = 0,
         context: TraceContext? = nil,
         completion: MemoryCacheAsyncCompletion?) {
    let (span, childContext) = _trackStartSpan("track.memory.set", context: context)
    span.setAttribute("cache.tier", value: "memory")
    span.setAttribute("cache.name", value: "MemoryCache")
    span.setAttribute("cache.operation", value: "set")
    span.setAttribute("cache.key", value: key)
    span.setAttribute("cache.bytes", value: cost)
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute("cache.outcome", value: "dropped")
            span.end()
            completion?(nil, key, object)
            return
        }
        strongSelf.set(object: object, forKey: key, cost: cost, context: childContext)
        span.setAttribute("cache.outcome", value: "stored")
        span.end()
        completion?(strongSelf, key, object)
    }
}
```

### Trim async — context propagation into background

```swift
func trim(toCount countLimit: UInt, context: TraceContext? = nil,
          completion: MemoryCacheAsyncCompletion?) {
    let (span, childContext) = _trackStartSpan("track.memory.trim", context: context)
    span.setAttribute("cache.tier", value: "memory")
    span.setAttribute("cache.name", value: "MemoryCache")
    span.setAttribute("cache.operation", value: "trim_count")
    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute("cache.outcome", value: "dropped")
            span.end()
            completion?(nil, nil, nil)
            return
        }
        strongSelf.trim(toCount: countLimit, context: childContext)
        span.setAttribute("cache.outcome", value: "trimmed")
        span.end()
        completion?(strongSelf, nil, nil)
    }
}
// trim(toCost:) and trim(toAge:) identical structure, cache.operation = "trim_cost" / "trim_age"
```

### Notification-triggered eviction

`_didReceiveMemoryWarningNotification` and `_didEnterBackgroundNotification` call `removeAllObjects(nil)`. After signature change this becomes `removeAllObjects(nil, context: nil)` — still compiles, produces noop spans when no provider is set.

---

## Changes to `Track/DiskCache.swift`

Same pattern as MemoryCache. `cache.name = self.name`, `cache.tier = "disk"`.

### Byte size access in `set`

`DiskCacheObject` is `private` to the file so `cost` (file size in bytes) is accessible within `DiskCache`'s method bodies. Capture after the archival:

```swift
func set(object: NSCoding, forKey key: String, context: TraceContext? = nil) {
    guard let fileURL = _generateFileURL(key, path: cacheURL) else { return }
    let filePath = fileURL.path
    let (span, _) = _trackStartSpan("track.disk.set", context: context)
    // set tier/name/operation/key attributes
    _lock()
    var storedBytes: UInt = 0
    if NSKeyedArchiver.archiveRootObject(object, toFile: filePath) {
        do {
            // ... existing date/attributes code ...
            storedBytes = fileSize   // already computed, capture it
            _cache.set(object: DiskCacheObject(key: key, cost: fileSize, date: date), forKey: key)
        } catch {}
    }
    // existing trim checks
    _unlock()
    span.setAttribute("cache.bytes", value: storedBytes)
    span.setAttribute("cache.outcome", value: "stored")
    span.end()
}
```

### Byte size access in `object(forKey:)`

Read cost from LRU metadata inside the lock (before calling `_unsafeObject`):

```swift
func object(forKey key: String, context: TraceContext? = nil) -> AnyObject? {
    let (span, _) = _trackStartSpan("track.disk.get", context: context)
    // set tier/name/operation/key attributes
    _lock()
    let cachedBytes: UInt = _cache.object(forKey: key)?.cost ?? 0
    let object = _unsafeObject(forKey: key)
    _unlock()
    span.setAttribute("cache.outcome", value: object != nil ? "hit" : "miss")
    if object != nil { span.setAttribute("cache.bytes", value: cachedBytes) }
    span.end()
    return object
}
```

---

## Changes to `Track/Cache.swift`

Add `context: TraceContext? = nil` to all public methods. The unified layer creates a parent span and passes `childContext` to both tier methods.

### Sync `object(forKey:)` — passes child context to both tiers

```swift
func object(forKey key: String, context: TraceContext? = nil) -> AnyObject? {
    let (span, childContext) = _trackStartSpan("track.get", context: context)
    span.setAttribute("cache.name", value: self.name)
    span.setAttribute("cache.operation", value: "get")
    span.setAttribute("cache.key", value: key)
    if let object = memoryCache.object(forKey: key, context: childContext) {
        span.setAttribute("cache.hit_tier", value: "memory")
        span.setAttribute("cache.outcome", value: "hit")
        span.end()
        return object
    }
    if let object = diskCache.object(forKey: key, context: childContext) {
        memoryCache.set(object: object, forKey: key)  // re-promotion: no context (internal side-effect)
        span.setAttribute("cache.hit_tier", value: "disk")
        span.setAttribute("cache.outcome", value: "hit")
        span.end()
        return object
    }
    span.setAttribute("cache.hit_tier", value: "none")
    span.setAttribute("cache.outcome", value: "miss")
    span.end()
    return nil
}
```

### Async `object(forKey:)` — the most complex case

Span S1 must outlive two possible completion paths. `childContext` C1 is passed to both memcache and disk calls (disk gets C1, not S2's context — making S2 and S3 siblings under S1).

```swift
func object(forKey key: String, context: TraceContext? = nil, completion: CacheAsyncCompletion?) {
    // S1 starts before any dispatch. Both `span` and `childContext` captured by reference.
    let (span, childContext) = _trackStartSpan("track.get", context: context)
    span.setAttribute("cache.name", value: self.name)
    span.setAttribute("cache.operation", value: "get")
    span.setAttribute("cache.key", value: key)

    _queue.async { [weak self] in
        guard let strongSelf = self else {
            span.setAttribute("cache.outcome", value: "dropped"); span.end(); return
        }

        // Pass C1 to memcache — memcache creates S2 (child of S1) internally
        strongSelf.memoryCache.object(forKey: key, context: childContext) { [weak self] (_, memKey, memObject) in
            guard let strongSelf = self else {
                span.setAttribute("cache.outcome", value: "dropped"); span.end(); return
            }

            if memObject != nil {
                // BRANCH A: memory hit — S2 already ended inside memcache
                span.setAttribute("cache.hit_tier", value: "memory")
                span.setAttribute("cache.outcome", value: "hit")
                span.end()  // S1 ends here
                strongSelf._queue.async { [weak self] in completion?(self, memKey, memObject) }
            } else {
                // BRANCH B: miss — pass C1 to disk (NOT S2's context, which has ended)
                // S3 becomes sibling of S2, both children of S1
                strongSelf.diskCache.object(forKey: key, context: childContext) { [weak self] (diskCache, diskKey, diskObject) in
                    guard let strongSelf = self else {
                        span.setAttribute("cache.outcome", value: "dropped"); span.end(); return
                    }
                    if let dk = diskKey, let dc = diskCache {
                        strongSelf.memoryCache.set(object: dc, forKey: dk, completion: nil)  // re-promotion, no context
                    }
                    span.setAttribute("cache.hit_tier", value: diskObject != nil ? "disk" : "none")
                    span.setAttribute("cache.outcome", value: diskObject != nil ? "hit" : "miss")
                    span.end()  // S1 ends here
                    strongSelf._queue.async { [weak self] in completion?(self, diskKey, diskObject) }
                }
            }
        }
    }
}
```

**Correctness invariant:** `span.end()` is called in exactly one branch in every guard/completion path. No code path exits without ending S1.

### Other async methods in Cache

Follow the simple pattern: start span, dispatch, call tier sync methods with `childContext`, end span, call completion.

---

## Context Leak Prevention

- No thread-local storage or `DispatchQueue.setSpecific` used anywhere
- Context is always passed as an explicit `context:` parameter
- Two concurrent operations on the same queue each hold their own captured `context` reference — complete isolation
- `nil` context → noop spans when provider is set, or real unparented root spans if provider attaches a root automatically

---

## Files to Create/Modify

| File | Change |
|---|---|
| `Track/Tracing.swift` | **Create** — protocols, registry, noops, helper |
| `Track/MemoryCache.swift` | Modify — add context to all 14 public methods |
| `Track/DiskCache.swift` | Modify — add context to all 14 public methods + capture bytes |
| `Track/Cache.swift` | Modify — add context to all 8 public methods + propagate child context |

`Track.podspec` does not need changes (`s.source_files = 'Track/*.{swift}'` already covers the new file).

---

## Implementation Order

1. `Track/Tracing.swift` — no dependencies
2. `Track/MemoryCache.swift` — depends on Tracing.swift
3. `Track/DiskCache.swift` — depends on Tracing.swift
4. `Track/Cache.swift` — depends on updated MemoryCache + DiskCache signatures

---

## Verification

- **Compile check:** `xcodebuild -project Framework/Track.xcodeproj -scheme Track build` (or Swift Package if added)
- **Manual trace walk:** Set a test `TraceProvider` that records all `startSpan` calls and `setAttribute` calls. Call `cache.set(object:forKey:context:)` with a root context and assert the span tree: `track.set` → `track.memory.set` + `track.disk.set`
- **Async object test:** Call `cache.object(forKey:context:completion:)` on a key present only in disk. Assert spans: `track.get` → `track.memory.get` (miss) + `track.disk.get` (hit). Assert `cache.hit_tier = "disk"` on the top span.
- **Leak test:** Issue two concurrent async gets with different contexts. Verify each completion's recorded context (via test provider) matches only the originating context — no cross-contamination.
- **No provider test:** Call all public methods with no `TraceProviderRegistry.shared` set. No crash, no observable side effects.
- **Backward compat test:** Confirm all existing call sites in `Demo/` compile without modification (all new parameters default to `nil`).
