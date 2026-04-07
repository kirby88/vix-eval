# Fix Rust Compilation Error in network-proxy

## Context

The most recent commit ("Surprise") changed the return type of `normalize_host()` in `codex-rs/network-proxy/src/policy.rs` from `String` to `&str`. This is invalid because the function body calls `normalize_dns_host()` which returns an owned `String` — you cannot return a `&str` reference to a temporary value. This causes 28+ compilation errors across the `codex-network-proxy` crate (and cascades into dependent crates).

## Fix

**File:** `codex-rs/network-proxy/src/policy.rs`, line 100

Change:
```rust
pub fn normalize_host(host: &str) -> &str {
```

Back to:
```rust
pub fn normalize_host(host: &str) -> String {
```

That's the entire fix — a one-character change on one line. All callers already expect `String`, and the function body already returns `String` through all paths (via `normalize_dns_host()`).

## Verification

Run `cargo check -p codex-network-proxy` — should pass with zero errors after the fix.
