# Fix: Rust Compilation Error in codex-linux-sandbox

## Context

The build fails because `build.rs` panics when `libcap` is not available via pkg-config. The panic happens on line 38-40 of `codex-rs/linux-sandbox/build.rs`. This is a hard failure that prevents the entire workspace from compiling.

The `vendored_bwrap.rs` already has a proper `#[cfg(not(vendored_bwrap_available))]` fallback implementation for when libcap/bubblewrap is unavailable, so there's no need to fail the build — the code handles this gracefully at the Rust level. The build script should emit a warning and continue rather than panic.

## Fix

**File:** `codex-rs/linux-sandbox/build.rs`, lines 38–40

Change:
```rust
if let Err(err) = try_build_vendored_bwrap() {
    panic!("failed to compile vendored bubblewrap for Linux target: {err}");
}
```

To:
```rust
if let Err(err) = try_build_vendored_bwrap() {
    println!("cargo:warning=failed to compile vendored bubblewrap for Linux target: {err}");
}
```

This allows the build to succeed without libcap. The `vendored_bwrap_available` cfg flag won't be set, so `vendored_bwrap.rs` will use its fallback `#[cfg(not(vendored_bwrap_available))]` impl which panics at runtime if the bwrap path is ever invoked.

## Verification

Run `cargo build` (or `cargo check`) in `/workspace/codex-rs` — the build should complete without errors.
