The file already has the correct signature: `pub fn normalize_host(host: &str) -> String {`. The compilation error has already been fixed in the Execute phase that ran before this planning phase.

To summarize what was done and what remains:

**Root Cause (already fixed)**

The most recent commit changed line 100 of `/workspace/codex-rs/network-proxy/src/policy.rs` from:

```rust
pub fn normalize_host(host: &str) -> String {
```

to:

```rust
pub fn normalize_host(host: &str) -> &str {
```

This introduced three cascading errors:

1. `normalize_dns_host` returns `String` (an owned heap allocation). `normalize_host` called it and tried to return a `&str` reference to the returned `String`. That `String` is a temporary that is dropped at the end of the call — the borrow checker correctly rejects returning a dangling reference to it.

2. `normalize_pattern` returns `String`. It assigns `let remainder = normalize_host(remainder);` and then on the `if prefix.is_empty()` branch returns `remainder` directly. With `normalize_host` returning `&str`, that branch would return a `&str` from a function declared to return `String` — a type mismatch.

3. `Host::parse` does `Ok(Self(normalized))` where `Self` wraps a `String`. With `normalize_host` returning `&str`, passing `normalized` to `Self(...)` would be a type mismatch since no `&str -> String` coercion is implicit in a tuple struct constructor.

**The fix** is a single-character-range change: restore the return type annotation from `&str` to `String`. The function body was already correct throughout — it always returned values from `normalize_dns_host`, which returns `String`. Only the declared return type was wrong.

The fix has already been applied. No further changes are needed.

### Critical Files for Implementation

- `/workspace/codex-rs/network-proxy/src/policy.rs` - The only file that needed to change; contains `normalize_host` whose return type was incorrectly set to `&str` instead of `String`