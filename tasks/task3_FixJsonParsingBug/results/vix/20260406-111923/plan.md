## Implementation Plan

### Overview

The bug is in `VariantAccess::variant_seed` in `/workspace/src/de.rs`. When deserializing a JSON object as an enum (e.g., `{"VariantName": value}`), the key is read using `seed.deserialize(&mut *self.de)`, which delegates to the full generic deserializer. This allows non-string JSON values (arrays, booleans, numbers, etc.) as object keys, violating the JSON spec.

The fix is to wrap `&mut *self.de` with `MapKey { de: &mut *self.de }` instead — the same wrapper already used in `MapAccess::next_key_seed` on line 2021. `MapKey` enforces string-only deserialization via its `deserialize_any` implementation, which calls `self.de.eat_char()` and then `parse_str`, only succeeding for `"` characters.

### Analysis of Existing Pattern

The `MapKey` struct (defined at line 2153) already solves this exact problem for map keys. Its `deserialize_any` implementation:
1. Calls `self.de.eat_char()` (consuming the `"`)
2. Calls `self.de.read.parse_str(...)` to read a string
3. Any non-string JSON value at that position will fail because it does not start with `"`

In `MapAccess::next_key_seed` (line 2021), the fix is already present:
```
Ok(Some(tri!(seed.deserialize(MapKey { de: &mut *self.de }))))
```

In `VariantAccess::variant_seed` (line 2055), the raw deserializer is used:
```
let val = tri!(seed.deserialize(&mut *self.de));
```

This is the line that needs to change.

### Changes Required

**Change 1: `/workspace/src/de.rs`, line 2055**

Replace:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```

With:
```rust
let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
```

This is a one-line change. No new structs, no new error codes, no new logic. It reuses the existing `MapKey` wrapper that is already in scope in the same file.

Note: `UnitVariantAccess::variant_seed` (line 2108) also uses `seed.deserialize(&mut *self.de)`, but it is only reached when the top-level JSON value is a bare string (the `Some(b'"') => visitor.visit_enum(UnitVariantAccess::new(self))` branch in `deserialize_enum` at line 1897). A bare string is always a valid JSON string, so that path does not need fixing.

**Change 2: Create `/workspace/tests/regression/issue979.rs`**

Add a regression test file following the exact pattern shown in existing regression tests (e.g., `issue953.rs` which is a simple `#[test] fn test() { ... }` with no extra attributes). The test uses a custom `Visitor` that calls `data.variant()` with a `Vec<bool>` key type, which forces the deserializer to try to deserialize the key as a sequence. With the fix applied, the `MapKey` wrapper will reject `[true]` (which starts with `[`, not `"`) before even reaching that visitor logic.

The test file content:
```rust
use serde::de::{Deserializer, VariantAccess, Visitor};

struct V;

impl<'de> Visitor<'de> for V {
    type Value = (Vec<bool>, ());

    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "enum")
    }

    fn visit_enum<A>(self, data: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::EnumAccess<'de>,
    {
        let (key, variant_access) = data.variant()?;
        let value = variant_access.newtype_variant()?;
        Ok((key, value))
    }
}

#[test]
fn test() {
    let mut de = serde_json::Deserializer::from_str("{[true]: null}");
    let result = de.deserialize_enum("name", &[], V);
    assert!(result.is_err(), "expected error for non-string object key");
}
```

The test file is automatically picked up by `/workspace/tests/regression.rs` which uses `automod::dir!("tests/regression")` — no manual registration needed.

### Sequencing

1. Edit `src/de.rs` line 2055: change `seed.deserialize(&mut *self.de)` to `seed.deserialize(MapKey { de: &mut *self.de })`.
2. Create `tests/regression/issue979.rs` with the test above.
3. Run `cargo test` to verify the regression test passes and no existing tests break.

### Potential Challenges

- `MapKey`'s `deserialize_any` calls `self.de.eat_char()` unconditionally, assuming the next character is `"`. If the next character is not `"`, it will consume it anyway and then fail on `parse_str`. This means the error message for `{[true]: null}` will reference a position inside the `[` rather than at its start. This is acceptable and consistent with how map key errors are reported.
- No existing tests should break: the only behavior change is rejecting previously-accepted malformed input. All valid JSON enum representations (`{"Variant": value}`) use string keys and will continue to work identically.

### Critical Files for Implementation

- `/workspace/src/de.rs` - Core logic to modify: change `seed.deserialize(&mut *self.de)` to `seed.deserialize(MapKey { de: &mut *self.de })` in `VariantAccess::variant_seed`
- `/workspace/tests/regression/issue979.rs` - New file to create: regression test verifying `{[true]: null}` returns an error
- `/workspace/tests/regression.rs` - Pattern to follow: shows how regression tests are auto-discovered via `automod::dir!`
- `/workspace/tests/regression/issue953.rs` - Pattern to follow: minimal regression test structure