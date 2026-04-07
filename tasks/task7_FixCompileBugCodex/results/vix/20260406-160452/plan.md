The fix has already been applied in the Execute phase. The current state of the workspace already has the correct fix in place.

**The compilation error has already been fixed.** Here is the plan summary for the record:

---

## Plan Summary

### Problem

The "Surprise" commit introduced a single incorrect change to `/workspace/codex-rs/network-proxy/src/policy.rs` at line 100:

The return type of `pub fn normalize_host` was changed from `-> String` to `-> &str`.

This is invalid for two reasons:

1. **Type mismatch in function body**: The function internally calls `normalize_dns_host()` which returns `String`. You cannot return a `String` value where the declared return type is `&str` without borrowing, and no local borrow is possible here since the `String` is created inside the function (it would be a dangling reference).

2. **Lifetime unsoundness at call sites**: Callers pass temporary `String` values, e.g. `normalize_host(&authority.host.to_string())`. Returning a `&str` that borrows from the input `&str` would mean the `&str` references data from a dropped temporary.

### Fix

Change line 100 of `/workspace/codex-rs/network-proxy/src/policy.rs` from:

```
pub fn normalize_host(host: &str) -> &str {
```

back to:

```
pub fn normalize_host(host: &str) -> String {
```

This is a one-line revert of the incorrect change. No other changes are needed — the function body and all callers are consistent with `-> String`.

### Verification

After the fix, `cargo check -p codex-network-proxy` completes with `Finished` and no errors. The only remaining build failure in the workspace is `codex-linux-sandbox`, which fails due to a missing system library (`libcap`) — this is an environment issue unrelated to Rust source code.

---

### Critical Files for Implementation

- `/workspace/codex-rs/network-proxy/src/policy.rs` - The only file that needs to change: revert return type of `normalize_host` from `&str` to `String` at line 100.