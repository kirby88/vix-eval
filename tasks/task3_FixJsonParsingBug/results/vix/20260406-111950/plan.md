## Implementation Plan

### Overview

The bug is in `/workspace/src/de.rs` in the `VariantAccess::variant_seed` implementation. The fix requires enforcing that enum variant keys in JSON objects must be strings, consistent with how `MapAccess::next_key_seed` already enforces this via the `MapKey` wrapper deserializer.

### Root Cause Analysis

In `deserialize_enum`, when the input starts with `{`, a `VariantAccess` is created. Its `variant_seed` method at line 2055 does:

```rust
let val = tri!(seed.deserialize(&mut *self.de));
```

This passes the raw deserializer to the seed, allowing the seed to deserialize any JSON value (arrays, numbers, booleans) as the key. The `MapKey` wrapper deserializer at line 2153 already exists to enforce string-only map keys — the same mechanism should be used here.

Similarly, `UnitVariantAccess::variant_seed` at line 2108 has the same issue:

```rust
let variant = tri!(seed.deserialize(&mut *self.de));
```

However, `UnitVariantAccess` is only constructed when the input starts with `"` (a quote character, line 1897), so by the time `variant_seed` is called the peek position is already at a string. Its `MapKey` wrapper's `deserialize_any` eats the opening quote and parses the string body — this is exactly the behavior needed. So `UnitVariantAccess` also benefits from the fix for consistency and correctness in case assumptions about construction ever change.

### Fix Strategy

Use the existing `MapKey` wrapper deserializer for both `VariantAccess` and `UnitVariantAccess` `variant_seed` implementations, exactly mirroring how `MapAccess::next_key_seed` does it at line 2021:

```rust
Ok(Some(tri!(seed.deserialize(MapKey { de: &mut *self.de }))))
```

#### Change 1: `VariantAccess::variant_seed` (line 2055)

Replace:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```
With:
```rust
let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
```

This causes `deserialize_any` on `MapKey` to be invoked, which calls `self.de.eat_char()` (consuming the `"`) then `self.de.read.parse_str(...)`, producing a `visit_str` or `visit_borrowed_str` call. If the next character is not `"`, the `MapKey` logic returns `KeyMustBeAString` error.

Wait — `MapKey::deserialize_any` unconditionally calls `self.de.eat_char()` assuming the current byte is a `"`. We need to verify what byte is at the current position when `variant_seed` is called for `VariantAccess`.

In `deserialize_enum`:
1. `parse_whitespace()` returns `Some(b'{')` — this is peeked, not consumed.
2. `self.eat_char()` consumes the `{`.
3. `visitor.visit_enum(VariantAccess::new(self))` is called.
4. Inside `visit_enum`, the visitor calls `data.variant()` which calls `variant_seed`.
5. At this point, the deserializer is positioned at the first byte of the key.

If the key starts with `"`, `MapKey::deserialize_any` will eat it and parse the string — correct.
If the key starts with `[` (as in `{[true]: null}`), `MapKey::deserialize_any` will eat the `[` then try to `parse_str` on what follows, which will error — this is the desired behavior.

But actually, looking more carefully at the `MapAccess` path: `has_next_key` explicitly peeks and returns `KeyMustBeAString` error before even getting to the `MapKey` deserializer if the key is not a `"`. For `VariantAccess`, there is no such pre-check. So using `MapKey` directly is safe: it will eat the first byte and then fail during string parsing if it's not a valid string.

Actually, `MapKey::deserialize_any` does `self.de.eat_char()` then `self.de.read.parse_str(...)`. If the current char is `[`, it eats `[` and then `parse_str` will fail because `[` is not a valid string start. This gives an error, which is the correct behavior.

#### Change 2: `UnitVariantAccess::variant_seed` (line 2108)

Replace:
```rust
let variant = tri!(seed.deserialize(&mut *self.de));
```
With:
```rust
let variant = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
```

`UnitVariantAccess` is only created when the outer deserializer sees `b'"'` (line 1897) — the quote is not consumed at that point. So `MapKey::deserialize_any` will eat the quote and parse the string correctly, exactly as before.

### Regression Test

Create `/workspace/tests/regression/issue979.rs` with a test that:
1. Defines a custom `Visitor` that calls `data.variant()` with `Vec<bool>` as the key type (so a non-string seed is used — specifically one that would accept arrays).
2. Deserializes `{[true]: null}` via `deserialize_enum`.
3. Asserts the result is an error.

The test follows the pattern from existing regression tests in `/workspace/tests/regression/`. The file `/workspace/tests/regression.rs` uses `automod::dir!("tests/regression")` so any `.rs` file placed there is automatically included — no manual `mod` declarations needed.

### Step-by-Step Implementation

1. Edit `/workspace/src/de.rs` line 2055:
   - Change `seed.deserialize(&mut *self.de)` to `seed.deserialize(MapKey { de: &mut *self.de })`

2. Edit `/workspace/src/de.rs` line 2108:
   - Change `seed.deserialize(&mut *self.de)` to `seed.deserialize(MapKey { de: &mut *self.de })`

3. Create `/workspace/tests/regression/issue979.rs` with the reproducer test from the bug report.

### Potential Concerns

- `MapKey` is a private struct defined later in the same file (line 2153), so it is in scope for both `VariantAccess` and `UnitVariantAccess` impls. No visibility changes needed.
- The `MapKey` struct has field `de: &'a mut Deserializer<R>`. The `variant_seed` method in `VariantAccess` has `self.de: &'a mut Deserializer<R>`, so `MapKey { de: &mut *self.de }` produces a `MapKey<'_, R>` that borrows `self.de` for the duration of the call — exactly the same pattern as line 2021.
- Existing tests that deserialize well-formed enums with string keys will continue to work because `MapKey::deserialize_any` correctly handles `"` prefixed strings.
- The fix makes `VariantAccess` consistent with `MapAccess` in key handling.

### Critical Files for Implementation

- `/workspace/src/de.rs` - Core logic to modify: the two `variant_seed` implementations in `VariantAccess` and `UnitVariantAccess`
- `/workspace/tests/regression/issue979.rs` - New file to create with the regression test
- `/workspace/tests/regression/issue953.rs` - Pattern to follow for regression test structure
- `/workspace/tests/regression.rs` - Confirms automod inclusion (no changes needed, but confirms new test file will be auto-included)