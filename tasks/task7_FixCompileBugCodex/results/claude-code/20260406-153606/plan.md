# Fix Rust Compilation Error in network-proxy

## Context

The most recent commit introduced a type mismatch in `codex-rs/network-proxy/src/policy.rs`. The function `normalize_host` was declared to return `&str` (a borrowed string slice), but its entire body calls `normalize_dns_host()` which returns `String` (an owned string). This mismatch cascades into 28 compilation errors across 4 files:

- **policy.rs** — root cause (9 errors)
- **http_proxy.rs** — callers expect `String`, get `&str` with temp-value borrow issues (10 errors)
- **socks5.rs** — same, plus `E0658: str_as_str` unstable feature triggered when calling `.as_str()` on `&str` (8 errors)
- **mitm.rs** — same caller issue (1 error)

## Fix

**Single change required:** `codex-rs/network-proxy/src/policy.rs` line 100

Change:
```rust
pub fn normalize_host(host: &str) -> &str {
```
To:
```rust
pub fn normalize_host(host: &str) -> String {
```

### Why this is the complete fix

The function body already returns `String` everywhere (all code paths call `normalize_dns_host()` which returns `String`). The wrong `&str` return type annotation is the only problem.

After the fix, all cascade effects resolve:
- `normalize_pattern` (line 139): `let remainder = normalize_host(remainder);` — `remainder` becomes `String`, which matches the `-> String` return type at line 141
- All callers (`http_proxy.rs`, `socks5.rs`, `mitm.rs`) bind `normalize_host(...)` to `let host = ...` (inferred type), so they get `String` cleanly
- `proxy_disabled_response` in `http_proxy.rs` expects `host: String` — now satisfied
- `.as_str()` on `String` (stable) replaces `.as_str()` on `&str` (unstable `str_as_str` feature) — fixes E0658

## Critical File

- `codex-rs/network-proxy/src/policy.rs` line 100 — **only file to edit**

## Verification

Run `cargo check -p network-proxy` (or `cargo build`) from the `codex-rs` directory to confirm zero errors.
