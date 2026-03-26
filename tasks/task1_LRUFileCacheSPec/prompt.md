# LRU File Cache — Swift Spec

## Requirements

- Disk-backed LRU cache for iOS
- Support multiple independent named caches (e.g. images, videos), each with their own configuration
- Fast start: cache must be usable immediately after init with no blocking I/O on the hot path
- LRU order is determined by last-accessed date
- Eviction runs asynchronously and must not block reads or writes
- Eviction moves files to the system `tmp/` directory rather than deleting them; file name collisions in `tmp/` must be handled
- All insertions use atomic writes
- The index (LRU metadata) is persisted to disk and survives process restarts

## Configuration (per cache)

- Name (used as the on-disk namespace)
- Max entry count
- Max total byte size
- Eviction debounce interval
- iOS data protection class

## API

| Method | Description |
|---|---|
| `add(key, data)` | Insert a new entry; replace if key already exists |
| `update(key, data)` | Alias for `add`; signals update intent to the caller |
| `modify(key, data)` | Replace payload for an existing key; error if key is absent |
| `get(key)` | Return payload and bump last-accessed date; return nil if absent |
| `promote(key)` | Update last-accessed date without reading the payload; error if key is absent |

## Constraints

- `modify` must fail explicitly if the key does not exist; `add` and `update` must not
- `get` and `promote` both count as an access and must update LRU order
- Index persistence triggered by `get`/`promote` should be debounced to avoid write amplification
- Index persistence triggered by mutations (`add`, `modify`, eviction) must be immediate
- A cache directory deleted externally must be recreated on next write
- A corrupted index on init must degrade gracefully to an empty cache, not a crash
- A file present in the index but missing on disk at `get` time must return nil and self-heal the index
