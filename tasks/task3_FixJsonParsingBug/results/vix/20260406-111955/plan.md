## Implementation Plan

### Overview

The fix has two parts:
1. Modify `VariantAccess::variant_seed` in `/workspace/src/de.rs` to enforce that the enum key is a JSON string.
2. Add a regression test in `/workspace/tests/regression/issue979.rs`.

---

### Part 1: Fix in `src/de.rs`

**Location:** `impl<'de, 'a, R: Read<'de> + 'a> de::EnumAccess<'de> for VariantAccess<'a, R>`, lines 2047-2059.

**Current buggy code:**
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

The problem is `seed.deserialize(&mut *self.de)` uses the full general-purpose deserializer, which accepts any JSON value as the key.

**Approach: peek-and-reject before delegating**

The simplest and most minimal fix is to peek at the next byte before calling `seed.deserialize`. If it is not `b'"'`, return `ErrorCode::KeyMustBeAString` immediately. This mirrors the exact same check already done in the `MapAccess::next_key_seed` implementation at lines ~2002-2005:

```rust
if peek == b'"' {
    Ok(true)
} else {
    Err(map.de.peek_error(ErrorCode::KeyMustBeAString))
}
```

The `variant_seed` method has access to `self.de` (a `&mut Deserializer<R>`), so it can call `self.de.parse_whitespace()` and then check the resulting byte. If it is `b'"'`, proceed with `seed.deserialize(&mut *self.de)` as before (which, given `b'"'` is next, will correctly parse a string). If not, return `Err(self.de.peek_error(ErrorCode::KeyMustBeAString))`.

**Updated code:**
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

Key design notes:
- `parse_whitespace()` advances past whitespace and returns the next peeked byte without consuming it (it uses `peek()` internally), so the `b'"'` quote character will still be present for `seed.deserialize` to consume. No double-consumption issue.
- `ErrorCode::KeyMustBeAString` and `ErrorCode::EofWhileParsingValue` already exist in the error module — no new error codes needed.
- This is strictly additive validation — no behavior change for valid JSON.
- `UnitVariantAccess::variant_seed` is unaffected because `UnitVariantAccess` is only created when the deserializer has already peeked `b'"'` (line 1897: `Some(b'"') => visitor.visit_enum(UnitVariantAccess::new(self))`), so that path is already string-gated.

---

### Part 2: Regression test in `tests/regression/issue979.rs`

The test module system uses `automod::dir!("tests/regression")` in `/workspace/tests/regression.rs`, so any `.rs` file placed in `tests/regression/` is automatically included — no manual `mod` declaration needed.

**New file:** `/workspace/tests/regression/issue979.rs`

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

This directly reproduces the original issue. No features, no extra dependencies.

---

### Critical Files for Implementation

- `/workspace/src/de.rs` - Core logic: modify `VariantAccess::variant_seed` to peek-and-reject non-string keys
- `/workspace/tests/regression/issue979.rs` - New file: regression test for the bug
- `/workspace/tests/regression.rs` - Pattern reference: confirms `automod::dir!` auto-includes new test files (no edit needed)