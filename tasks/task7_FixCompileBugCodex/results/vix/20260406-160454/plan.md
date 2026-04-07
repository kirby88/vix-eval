The problem is clear. Here is the implementation plan.

## Implementation Plan

### Fix the `normalize_host` return type in policy.rs

**File**: `/workspace/codex-rs/network-proxy/src/policy.rs`

**Change**: Revert the return type of `normalize_host` from `&str` back to `String`.

**Root Cause**:

The function signature currently reads:

```rust
pub fn normalize_host(host: &str) -> &str {
```

This is a lifetime error. Every code path in the function body calls `normalize_dns_host(...)`, which is defined as:

```rust
fn normalize_dns_host(host: &str) -> String {
    let host = host.to_ascii_lowercase();
    host.trim_end_matches('.').to_string()
}
```

`normalize_dns_host` always returns an owned `String`. The `normalize_host` function tries to return a `&str`, but that `&str` would be a reference into a locally-owned `String` that gets dropped at the end of `normalize_host`'s scope — which Rust's borrow checker correctly rejects as a dangling reference.

Additionally, the function has two code paths that create intermediate local bindings:
- `let host = host.split(':').next().unwrap_or_default();` — this `host` is a `&str` borrowed from the input, but it is passed into `normalize_dns_host` which produces a new `String`; that `String` cannot be returned as `&str`
- `normalize_dns_host(&host[1..end])` — same issue

Further downstream, `normalize_pattern` calls `normalize_host(remainder)` and assigns the result to `let remainder`, then either returns it directly as `String` or uses it in `format!("{prefix}{remainder}")`. With `&str` return, these would also fail to compile since `normalize_pattern` declares `-> String`.

And `Host::parse` does `Ok(Self(normalized))` where `Self` wraps a `String` — it needs an owned value.

**Exact change**: At the `normalize_host` function declaration, change only the return type token:

From:
```rust
pub fn normalize_host(host: &str) -> &str {
```

To:
```rust
pub fn normalize_host(host: &str) -> String {
```

No changes to the function body are needed. The body already calls `normalize_dns_host(...)` at every return site, and `normalize_dns_host` already returns `String`. The return expressions are already of type `String`; the only incorrect element is the declared return type on the signature.

No other files need modification. All callers (`http_proxy.rs`, `mitm.rs`, `socks5.rs`, `runtime.rs`) use the result in comparisons (`==`, `!=`) or string operations that work with `String` via `Deref<Target=str>`.

### Critical Files for Implementation

- `/workspace/codex-rs/network-proxy/src/policy.rs` - Contains the broken `normalize_host` function signature that must be fixed