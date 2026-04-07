# Fix Rust Compilation Error in codex-network-proxy

## Context

The function `normalize_host` in `network-proxy/src/policy.rs` had its return type changed from `String` to `&str` (line 100). However, its implementation calls `normalize_dns_host()` which returns an owned `String`, making it impossible to return a borrowed `&str` — the temporary would be dropped immediately. This single change cascades into 28 compilation errors across 4 files.

## Root Cause

`policy.rs:100` — signature changed to `pub fn normalize_host(host: &str) -> &str` but the body returns `normalize_dns_host(...)` which returns `String`. Every call site that expected `String` now breaks.

## Fix

Change the return type of `normalize_host` back to `String` (one-line change in `policy.rs`).

**File:** `codex-rs/network-proxy/src/policy.rs`, line 100

Change:
```rust
pub fn normalize_host(host: &str) -> &str {
```
To:
```rust
pub fn normalize_host(host: &str) -> String {
```

This resolves all 28 downstream errors:
- `E0308` mismatched types in `http_proxy.rs`, `mitm.rs`, `socks5.rs`, `policy.rs` — callers expect `String`
- `E0658` unstable `str::as_str()` calls — those become stable `String::as_str()` once `host` is `String` again
- `E0716` temporary dropped while borrowed in `http_proxy.rs:339` — borrow of temporary `String` no longer needed
- `E0308` in `policy.rs:141` (`normalize_pattern` returns `String` but `normalize_host` was returning `&str`)

## Verification

```
cd /workspace/codex-rs && cargo check -p codex-network-proxy
```
Should produce zero errors.
