# Fix Rust Compilation Error in network-proxy

## Context
The "Surprise" commit changed the return type of `normalize_host()` in `policy.rs` from `String` to `&str`. The function body still calls `normalize_dns_host()` which returns `String`, causing a cascade of 28 type mismatch errors across 4 files. The fix is a one-character change to restore the correct return type.

## Root Cause
**File:** `/workspace/codex-rs/network-proxy/src/policy.rs`, **line 100**

Changed from:
```rust
pub fn normalize_host(host: &str) -> String {
```
to:
```rust
pub fn normalize_host(host: &str) -> &str {
```

This is invalid because:
- The function body calls `normalize_dns_host()` (line 120) which returns `String`
- All call sites in `http_proxy.rs`, `socks5.rs`, and `mitm.rs` expect `String`

## Fix

**Single change in `/workspace/codex-rs/network-proxy/src/policy.rs` line 100:**

Change `-> &str` back to `-> String`.

No other files need to change — they were already correct before the "Surprise" commit.

## Verification

Run: `cd /workspace/codex-rs && cargo check`

Should produce zero errors related to `normalize_host`.
