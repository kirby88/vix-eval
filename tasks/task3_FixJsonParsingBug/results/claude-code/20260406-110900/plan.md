# Fix: EnumAccess::variant silently accepts non-string JSON keys (issue #979)

## Context

`serde_json`'s `EnumAccess` impl for object-style enums (`{"VariantName": value}`) calls
`seed.deserialize(&mut *self.de)` to read the variant key. This passes the full deserializer to the
seed, so any JSON value — arrays, booleans, numbers, etc. — is silently accepted as the key name.
The JSON spec requires object member names to be strings, so `{[true]: null}` should be a parse
error.

The `MapKey` wrapper deserializer already enforces string-only keys for regular map deserialization;
the enum path simply needs to use the same mechanism.

## Files to Modify

- `src/de.rs` — fix `variant_seed` in the `EnumAccess` impl (~line 2051)
- `tests/regression/issue979.rs` — new regression test

## Fix: `src/de.rs`

**Location:** `impl<'de, 'a, R: Read<'de> + 'a> de::EnumAccess<'de> for VariantAccess<'a, R>`,
the `variant_seed` method at ~line 2051.

**Current code (line 2055):**
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```

**Replace with a peek + guard, then deserialize via `MapKey`:**
```rust
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    match tri!(self.de.parse_whitespace()) {
        Some(b'"') => {}
        Some(_) => return Err(self.de.peek_error(ErrorCode::KeyMustBeAString)),
        None => return Err(self.de.peek_error(ErrorCode::EofWhileParsingValue)),
    }
    let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

**Why `MapKey`:** `MapKey::deserialize_any` eats the leading `"` and then calls
`self.de.read.parse_str(...)`, returning a `visit_str` / `visit_borrowed_str`. This is exactly
the existing, tested string-parsing path used by `MapAccess::next_key_seed`.

The `parse_whitespace()` peek is necessary because the deserializer is positioned right after the
`{` has been consumed (done in `deserialize_enum` before calling `visitor.visit_enum`). We must
skip any whitespace before checking whether the key begins with `"`.

## New Test: `tests/regression/issue979.rs`

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
fn test_non_string_enum_key_rejected() {
    let mut de = serde_json::Deserializer::from_str("{[true]: null}");
    let result = de.deserialize_enum("name", &[], V);
    assert!(result.is_err(), "expected error for non-string object key in enum");
}
```

The test file is auto-discovered via `automod::dir!("tests/regression")` in `tests/regression.rs`,
so no other file needs to be modified.

## Verification

1. `cargo test` — all existing tests must pass.
2. The new `test_non_string_enum_key_rejected` test must pass (result is `Err`).
3. Confirm normal enum deserialization still works by running the full test suite
   (serde-derived enums, `#[serde(rename)]`, etc. are exercised in `tests/test.rs`).
