# Fix: EnumAccess::variant_seed must reject non-string JSON keys (issue #979)

## Context

`EnumAccess::variant_seed` in `src/de.rs` calls `seed.deserialize(&mut *self.de)` directly, which allows the underlying deserializer to accept any JSON value as an object member name (arrays, booleans, numbers, etc.). This violates the JSON spec and the contract that map keys must be strings.

The existing `MapAccess::next_key_seed` already handles this correctly: it peeks for `b'"'` and returns `ErrorCode::KeyMustBeAString` if it's missing, then deserializes via the `MapKey` wrapper which enforces string-only parsing. `EnumAccess::variant_seed` needs the same treatment.

**Note:** `MapKey` has a contract comment: "Only deserialize from this after peeking a `"` byte! Otherwise it may deserialize invalid JSON successfully." So we must peek first.

## Files to modify

- `src/de.rs` — fix `variant_seed` in the `EnumAccess` impl for `VariantAccess`
- `tests/regression/issue979.rs` — new regression test (auto-discovered by `automod::dir!` in `tests/regression.rs`)

## Implementation

### 1. `src/de.rs` — `variant_seed` (line 2051–2058)

**Current code:**
```rust
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    let val = tri!(seed.deserialize(&mut *self.de));
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

**Fixed code:**
```rust
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    if tri!(self.de.peek()) != Some(b'"') {
        return Err(self.de.peek_error(ErrorCode::KeyMustBeAString));
    }
    let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

This mirrors exactly the pattern used by `MapAccess::next_key_seed` at lines 2000–2021.

### 2. `tests/regression/issue979.rs` — new file

```rust
use serde::de::{Deserializer, VariantAccess, Visitor};
use std::fmt;

struct V;

impl<'de> Visitor<'de> for V {
    type Value = (Vec<bool>, ());

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
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
fn test_non_string_enum_key_rejected() {
    let mut de = serde_json::Deserializer::from_str("{[true]: null}");
    let result = de.deserialize_enum("name", &[], V);
    assert!(result.is_err(), "expected error for non-string object key");
}
```

No changes needed to `tests/regression.rs` — it uses `automod::dir!("tests/regression")` to auto-discover all files.

## Verification

```sh
cargo test --test regression issue979
cargo test --test regression   # ensure no regressions
cargo test                     # full test suite
```
