The problem is clear. Here is the plan.

## Plan

### Problem

In `/workspace/codex-rs/network-proxy/src/policy.rs`, the function `normalize_host` at line 100 has its return type declared as `&str`:

```
pub fn normalize_host(host:&str)->&str{
```

However, the function body exclusively calls `normalize_dns_host(...)`, which returns `String` — an owned heap allocation. Rust will not coerce an owned `String` into a borrowed `&str` reference with a lifetime tied to the input, because the `String` is a local temporary that would be dropped at the end of the function call. This causes a lifetime/type mismatch compilation error.

There are three call sites that are also affected by this wrong return type:

1. **`Host::parse` (around line 21)**: calls `normalize_host(input)` and passes the result directly to `Self(normalized)`, which requires a `String` (since `Host` wraps `String`).
2. **`normalize_pattern` (around line 139)**: assigns `normalize_host(remainder)` to `remainder` and then either returns it as-is (requiring `String` since the function returns `String`) or uses it in `format!("{prefix}{remainder}")` (which works with either, but the direct return path requires `String`).

### Fix

The correct return type for `normalize_host` is `String`. The function body is already correct — it always returns owned `String` values from `normalize_dns_host`. The only error is the declared return type on line 100.

**Single change required:**

In `/workspace/codex-rs/network-proxy/src/policy.rs`, line 100, change the return type of `normalize_host` from `&str` to `String`:

- Before: `pub fn normalize_host(host: &str) -> &str {`
- After:  `pub fn normalize_host(host: &str) -> String {`

No other changes are needed. The function body, all callers, and all test assertions are already consistent with a `String` return type.

### Critical Files for Implementation

- `/workspace/codex-rs/network-proxy/src/policy.rs` - Contains the `normalize_host` function with the incorrect return type on line 100 that must be changed from `&str` to `String`