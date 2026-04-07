## Implementation Plan

### Overview

The bug is in `VariantAccess::variant_seed` in `/workspace/src/de.rs`. The method calls `seed.deserialize(&mut *self.de)` directly, which allows the underlying deserializer to accept any JSON value as the object key — including arrays, booleans, numbers, etc. The fix is to route through the existing `MapKey` wrapper deserializer, which already enforces that the key must be a JSON string (via `deserialize_any` which calls `parse_str`), instead of the raw deserializer.

### Root Cause Detail

At line 2055 in `/workspace/src/de.rs`:

```rust
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    let val = tri!(seed.deserialize(&mut *self.de));  // BUG: accepts any JSON value as key
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

The `MapKey` struct defined at line 2153 already handles this correctly: its `deserialize_any` implementation calls `self.de.read.parse_str(...)`, which returns an error if the next byte is not `"`. By contrast, `&mut *self.de` dispatches to `Deserializer::deserialize_any`, which peeks at the next byte and calls `visit_seq` for `[`, `visit_bool` for `t`/`f`, etc.

### Fix Strategy

Replace `seed.deserialize(&mut *self.de)` with `seed.deserialize(MapKey { de: &mut *self.de })` in `VariantAccess::variant_seed`.

This is exactly analogous to how `MapAccess::next_key_seed` works at line 2021:
```rust
Ok(Some(tri!(seed.deserialize(MapKey { de: &mut *self.de }))))
```

The `MapKey` deserializer's `deserialize_any` calls `self.de.eat_char()` (consuming the opening `"`) then `self.de.read.parse_str(...)`, returning an error if the current byte is not a string. All other `deserialize_*` methods on `MapKey` either delegate to numeric key parsing (which also enforces quoted numeric format) or forward to the underlying deserializer for things like `deserialize_enum` on the key itself.

This one-line change is the minimal, correct fix: it reuses the already-proven `MapKey` abstraction with no new logic.

### Regression Test Plan

Create `/workspace/tests/regression/issue979.rs` following the exact pattern of existing regression tests like `/workspace/tests/regression/issue953.rs`. The test file will:

1. Import `serde::de::{Deserializer, VariantAccess, Visitor}` (not `serde_json::*` — the visitor must manually drive `deserialize_enum` to expose the bug path).
2. Define a `struct V` implementing `Visitor<'de>` with `Value = (Vec<bool>, ())`.
3. Implement `visit_enum` to call `data.variant()` (which internally calls `variant_seed`) and then `variant_access.newtype_variant()`.
4. Define a `#[test]` function that constructs a `serde_json::Deserializer::from_str("{[true]: null}")`, calls `deserialize_enum("name", &[], V)`, and asserts the result is `Err`.

The file `/workspace/tests/regression.rs` uses `automod::dir!("tests/regression")` which auto-includes all `.rs` files in the directory, so no manual `mod` declaration is needed — just adding the file is sufficient.

### Step-by-Step Implementation

**Step 1:** Edit `/workspace/src/de.rs` at line 2055.

Change:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```
To:
```rust
let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
```

No other changes are needed in `src/de.rs`. `MapKey` is already defined in the same file and is in scope.

**Step 2:** Create `/workspace/tests/regression/issue979.rs` with the following content (based on the exact reproducer from the issue):

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
fn test_issue979_non_string_enum_key_rejected() {
    let mut de = serde_json::Deserializer::from_str("{[true]: null}");
    let result = de.deserialize_enum("name", &[], V);
    assert!(result.is_err(), "expected error for non-string object key");
}
```

### Verification

After the two changes, run `cargo test` to confirm:
- The new regression test passes (i.e., the malformed JSON is rejected with an error).
- All existing tests continue to pass (the `MapKey` path for enum keys handles the same cases that the raw deserializer handled for well-formed string keys, since `MapKey::deserialize_any` correctly parses string keys).

### Critical Files for Implementation

- `/workspace/src/de.rs` - Core logic to modify: change `seed.deserialize(&mut *self.de)` to `seed.deserialize(MapKey { de: &mut *self.de })` in `VariantAccess::variant_seed` at line 2055
- `/workspace/tests/regression/issue979.rs` - New file to create: regression test verifying malformed JSON `{[true]: null}` is rejected
- `/workspace/tests/regression/issue953.rs` - Pattern to follow: existing regression test showing the minimal file structure expected