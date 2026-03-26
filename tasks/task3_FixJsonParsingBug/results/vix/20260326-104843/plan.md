I have everything I need. Here is the implementation plan.

---

## Implementation Plan

### Problem Statement

`VariantAccess::variant_seed` at `/workspace/src/de.rs:2055` passes the raw `&mut *self.de` to the seed deserializer when processing a JSON object enum key. The raw `Deserializer` accepts any JSON value (arrays, booleans, numbers, objects) as a key, violating the JSON specification that requires object member names to be strings. The malformed input `{[true]: null}` is silently accepted.

### Root Cause (Confirmed)

```rust
// /workspace/src/de.rs lines 2051-2058
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    let val = tri!(seed.deserialize(&mut *self.de));  // BUG: raw deserializer, no string enforcement
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

### Solution Design

The fix mirrors exactly how `MapAccess::next_key_seed` enforces string keys. That implementation (lines 1986-2025):

1. Peeks at the next non-whitespace byte before deserializing
2. Returns `ErrorCode::KeyMustBeAString` if the byte is not `b'"'`
3. Passes `MapKey { de: &mut *self.de }` (a wrapper deserializer that only understands strings and quoted-number keys) instead of the raw deserializer

The `MapKey` wrapper already exists and is perfectly suited for this purpose. It was designed exactly for this scenario -- deserializing an object key that must be a JSON string.

Context: When `VariantAccess::variant_seed` is called, the `{` has already been consumed by `deserialize_enum` (line 1883: `self.eat_char()`). So the deserializer position is immediately after `{`, and the next meaningful token should be the opening `"` of the key string.

### Step-by-Step Implementation

**Step 1: Fix `VariantAccess::variant_seed` in `/workspace/src/de.rs`**

Replace the buggy line 2055 with a string-enforcing pattern that:
- Calls `self.de.parse_whitespace()` to consume leading whitespace
- Checks the peeked byte is `b'"'`; if not, returns `ErrorCode::KeyMustBeAString`
- Handles EOF with `ErrorCode::EofWhileParsingObject`
- Passes `MapKey { de: &mut *self.de }` to the seed instead of `&mut *self.de`

The old code:
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

The new code:
```rust
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    match tri!(self.de.parse_whitespace()) {
        Some(b'"') => {}
        Some(_) => return Err(self.de.peek_error(ErrorCode::KeyMustBeAString)),
        None => return Err(self.de.peek_error(ErrorCode::EofWhileParsingObject)),
    }
    let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

Key decisions:
- `parse_whitespace()` is used (not `peek()`) because the key may follow whitespace after `{`
- The byte `b'"'` is only peeked, not consumed -- `MapKey::deserialize_any` does the `eat_char()` itself (line 2209)
- `ErrorCode::KeyMustBeAString` matches what `MapAccess` uses for the same condition (line 2005, 2012)
- `ErrorCode::EofWhileParsingObject` matches what `MapAccess` uses for EOF (line 2994)
- `MapKey` is in scope in the same impl block context -- it is a private struct defined later in the same file (line 2153), in the same module

**Step 2: Add regression test at `/workspace/tests/regression/issue979.rs`**

Create a new file following the pattern of other regression tests. The test uses the exact reproducer from the issue report:

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

The `automod::dir!("tests/regression")` call in `/workspace/tests/regression.rs` will automatically pick up any new `.rs` file placed in that directory -- no manual registration is needed.

### Verification of Correctness

- The `deserialize_enum` method (line 1880-1901) consumes `{` before calling `visitor.visit_enum(VariantAccess::new(self))`. The deserializer is positioned right after `{`.
- `parse_whitespace()` handles any whitespace between `{` and the key.
- When the input is `{[true]: null}`, after consuming `{`, the next non-whitespace byte is `[`. The new check sees `Some(b'[')`, which is not `b'"'`, and returns `ErrorCode::KeyMustBeAString`. The test assertion `result.is_err()` passes.
- When the input is `{"Variant": value}` (valid), the next byte is `"`, the check passes, and `MapKey` is used to parse the string key as before. Normal enum deserialization continues unaffected.
- `MapKey` correctly handles the numeric-key-in-quotes case (e.g., `{"42": value}`) for seeds that deserialize to integers, since `MapKey` has `deserialize_numeric_key!` impls for all number types.

### Potential Concerns

None significant. `MapKey` is a well-tested wrapper that already handles all the edge cases (string keys, numeric-string keys, bool-string keys). Reusing it is the minimal, correct, and consistent fix. The change is fully backward compatible for valid JSON inputs.

---

### Critical Files for Implementation

- `/workspace/src/de.rs` - Core logic to modify: the `VariantAccess::variant_seed` method (lines 2051-2058) is where the bug lives and must be fixed
- `/workspace/tests/regression/issue979.rs` - New file to create containing the regression test
- `/workspace/tests/regression/issue953.rs` - Pattern to follow for regression test file structure (simple `#[test]` function, no module wrapper)