# Fix: Enforce string-only keys in EnumAccess::variant_seed

## Context

`VariantAccess::variant_seed` in `src/de.rs` calls `seed.deserialize(&mut *self.de)` directly on the full deserializer, which can accept any JSON value (arrays, booleans, numbers, etc.) as an object member key. This violates the JSON spec and serde's contract that enum variant names must be strings. Issue #979 demonstrates `{[true]: null}` parsing without error.

## Fix: `src/de.rs` — `VariantAccess::variant_seed` (lines 2051–2058)

Add a whitespace-skipping peek **before** delegating to the seed, rejecting non-`"` bytes with the existing `KeyMustBeAString` error code.

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
    let val = tri!(seed.deserialize(&mut *self.de));
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

`parse_whitespace()` skips whitespace then **peeks** (does not consume) the next byte, so the `"` remains in the stream for `seed.deserialize` to consume normally.

**Pattern precedent:** identical guard style is used in `MapAccess::next_key_seed` (~line 2005) and `ignore_value` (~line 1202).

## New test: `tests/regression/issue979.rs`

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

## Verification

- Run `cargo test` — existing tests should pass, new regression test should pass.
- Specifically `cargo test --test regression` to target the new test file.
