# Fix: EnumAccess::variant_seed silently accepts non-string JSON keys (issue #979)

## Context

`serde_json`'s `EnumAccess` implementation allows any JSON value (arrays, booleans, numbers) as an object member key when deserializing enums. This violates the JSON spec (keys must be strings). For example, `{[true]: null}` parses without error via `deserialize_enum`.

**Root cause:** `VariantAccess::variant_seed` in `src/de.rs` (line 2055) calls `seed.deserialize(&mut *self.de)` — passing the raw deserializer. This lets the seed consume any JSON token as the key, not just strings.

By contrast, `MapAccess::next_key_seed` (lines 2000–2021) first checks for `b'"'`, returns `ErrorCode::KeyMustBeAString` if not found, then wraps the deserializer in `MapKey { ... }` which enforces string-only semantics.

## Fix

### 1. `src/de.rs` — `VariantAccess::variant_seed` (line 2055)

Replace:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```

With a peek-then-wrap pattern identical to what `MapAccess` uses:
```rust
let val = match tri!(self.de.parse_whitespace()) {
    Some(b'"') => tri!(seed.deserialize(MapKey { de: &mut *self.de })),
    Some(_) => return Err(self.de.peek_error(ErrorCode::KeyMustBeAString)),
    None => return Err(self.de.peek_error(ErrorCode::EofWhileParsingObject)),
};
```

This reuses the existing `MapKey` struct (defined at line 2153) and `ErrorCode::KeyMustBeAString` — no new types or error codes needed.

### 2. `tests/regression/issue979.rs` — New regression test

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

The test file is auto-included via `automod::dir!("tests/regression")` in `tests/regression.rs`.

## Critical files

- `src/de.rs:2051-2058` — `VariantAccess::variant_seed` (the fix)
- `src/de.rs:2153` — `MapKey` struct (reused, no changes needed)
- `src/de.rs:2000-2021` — `MapAccess::next_key_seed` (pattern reference)
- `tests/regression/issue979.rs` — new test file to create

## Verification

```
cargo test
cargo test --test regression
```

The new test should fail before the fix and pass after it.
