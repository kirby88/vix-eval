# Fix Rust Compilation Error in network-proxy

## Context

The "Surprise" commit changed `normalize_host()` in `network-proxy/src/policy.rs` from returning `String` to returning `&str`. This is invalid because:
- The function internally calls `normalize_dns_host()` which returns an owned `String`
- You cannot return a `&str` reference to a locally-owned `String` — the `String` would be dropped at the end of the function scope, creating a dangling reference
- The `Host::parse()` caller stores the result in `Host(String)`, requiring an owned `String`
- `normalize_pattern()` also stores the result and needs an owned value

This causes 20+ cascading errors across `policy.rs`, `http_proxy.rs`, and `socks5.rs`.

## Fix

**Single change in `/workspace/codex-rs/network-proxy/src/policy.rs`, line 100:**

```rust
// Change from:
pub fn normalize_host(host: &str) -> &str {

// Change to:
pub fn normalize_host(host: &str) -> String {
```

The function body already returns `String` values from `normalize_dns_host()` on lines 105, 112, and 117 — the return type just needs to match.

## Verification

Run `cargo build --package codex-network-proxy` — should compile with no errors.
Run `cargo test --package codex-network-proxy` to verify all tests pass.
