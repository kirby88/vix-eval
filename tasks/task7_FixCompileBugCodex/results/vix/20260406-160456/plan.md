Now I have a complete picture of the problem. Here is the plan.

---

## Problem Analysis

The compilation error is in `/workspace/codex-rs/network-proxy/src/policy.rs`. The most recent commit changed the return type of `normalize_host` from `-> String` to `-> &str`. This is incorrect because:

1. **`normalize_dns_host` returns `String`**, not `&str`. The body of `normalize_host` calls `normalize_dns_host(...)` and returns its result. You cannot return a reference to a locally-owned `String` — that would be a dangling reference, which Rust rightly rejects with a lifetime error.

2. **`Host::parse` uses the return value as `String`**: `Ok(Self(normalized))` — the `Host` struct wraps a `String`, so `normalized` must be a `String`.

3. **`normalize_pattern` uses the return value as `String`**: `let remainder = normalize_host(remainder);` — the result is used in `format!("{prefix}{remainder}")` or returned directly as a `String` from `normalize_pattern`.

---

## Fix Plan

The correct fix is to revert the signature of `normalize_host` back to `-> String`. This is the only change needed.

Specifically, change line 100 in `/workspace/codex-rs/network-proxy/src/policy.rs`:

```
pub fn normalize_host(host: &str) -> &str {
```

back to:

```
pub fn normalize_host(host: &str) -> String {
```

No other changes are needed. The function body already returns values from `normalize_dns_host`, which correctly returns `String`. All callers (`Host::parse`, `normalize_pattern`) already expect a `String`. The tests also remain valid since `String` and `&str` compare equal via `assert_eq!` due to `PartialEq` implementations.

---

### Critical Files for Implementation

- `/workspace/codex-rs/network-proxy/src/policy.rs` - The only file that needs to be changed: revert the return type of `normalize_host` from `&str` back to `String`