# Fix: EnumAccess::variant silently accepts non-string JSON keys (issue #979)

## Context

`EnumAccess::variant_seed()` in `src/de.rs` uses `seed.deserialize(&mut *self.de)` to
read the object key. This passes the raw deserializer, which accepts any JSON value
(arrays, booleans, numbers, etc.) as the key. JSON only allows strings as object member
names, so non-string keys should be rejected with an error.

The `MapKey` wrapper deserializer already exists in the same file and enforces string-
only keys. The fix is to route `variant_seed()` through `MapKey` instead of the raw
deserializer.

## Files to Modify

- `src/de.rs` — fix `variant_seed()` in the `EnumAccess` impl
- `tests/regression/issue979.rs` — new regression test (must also be registered in `tests/regression.rs` or equivalent)

## Implementation Plan

### 1. Fix `variant_seed()` in `src/de.rs`

**Location:** ~line 2055, inside `impl<'de, 'a, R: Read<'de> + 'a> de::EnumAccess<'de> for VariantAccess<'a, R>`

Change:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```
To:
```rust
let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
```

This reuses the existing `MapKey` struct (defined at ~line 2153) which enforces that the
JSON value being deserialized is a quoted string. Non-string values (arrays, booleans,
numbers, null) will produce a type error.

### 2. Add regression test `tests/regression/issue979.rs`

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

### 3. Register the test file

Check how existing regression tests are wired up (e.g., via `tests/regression.rs` or
`mod` declarations). Add `mod issue979;` in the appropriate place so the test is
discovered by `cargo test`.

## Verification

```
cargo test --test regression issue979
```

Should show the new test passing. Also run the full test suite to confirm no regressions:

```
cargo test
```
