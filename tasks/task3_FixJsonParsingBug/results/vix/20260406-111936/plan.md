## Implementation Plan

### Overview

The bug is in `VariantAccess::variant_seed` in `/workspace/src/de.rs`. When deserializing an enum from a JSON object (the `{...}` form), the key is deserialized using the raw deserializer via `seed.deserialize(&mut *self.de)`. This allows any JSON value — including arrays like `[true]` — as the key, instead of enforcing that it must be a JSON string.

The fix mirrors the existing `MapKey` wrapper pattern: introduce a new `EnumKey` wrapper struct that enforces the key must be a JSON string (returning an error otherwise), then use it in both `EnumAccess` implementations.

---

### Root Cause Analysis

In `deserialize_enum`, when the input starts with `{`, a `VariantAccess` is created and `visitor.visit_enum(VariantAccess::new(self))` is called. Inside `VariantAccess::variant_seed`:

```rust
fn variant_seed<V>(self, seed: V) -> Result<(V::Value, Self)>
where
    V: de::DeserializeSeed<'de>,
{
    let val = tri!(seed.deserialize(&mut *self.de));  // BUG: accepts any JSON value
    tri!(self.de.parse_object_colon());
    Ok((val, self))
}
```

The `seed.deserialize(&mut *self.de)` call passes the full deserializer, so the seed's `deserialize_any` (or whichever method it calls) can request any JSON type. The `Deserializer`'s `deserialize_any` will happily parse arrays, booleans, numbers, etc. as the object key.

The existing fix for map keys (`MapKey`) works by wrapping the deserializer such that `deserialize_any` unconditionally reads a JSON string (calling `eat_char()` to consume the `"` and then `parse_str`), and forwarding other methods appropriately. Any non-string encountered at the key position causes an error.

---

### Solution Design

Introduce a new zero-cost wrapper `EnumKey<'a, R>` (analogous to `MapKey<'a, R>`) that:

1. In `deserialize_any`: peeks at the current byte, and if it is not `"`, returns `Err` with `ErrorCode::KeyMustBeAString`. If it is `"`, consumes it and parses the string, forwarding to the visitor.
2. Delegates all other `de::Deserializer` methods via `forward_to_deserialize_any!` so that any type the seed requests (e.g. `deserialize_str`, `deserialize_identifier`, `deserialize_string`) goes through the string-enforcing path.

Then, in `VariantAccess::variant_seed`, change:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```
to:
```rust
let val = tri!(seed.deserialize(EnumKey { de: &mut *self.de }));
```

This ensures that no matter what the seed's deserializer calls, only a JSON string key is accepted.

Note: `UnitVariantAccess::variant_seed` is reached only when the input starts with `"` (a bare string, not an object), so it already enforces a string by virtue of how `deserialize_enum` routes to it (only when `peek == b'"'`). However, for correctness and symmetry, the same `EnumKey` wrapper (or a simpler explicit peek-check) should be applied there too. Since `UnitVariantAccess` is only ever constructed after `deserialize_enum` peeks `b'"'`, the current code is actually safe there — but applying `EnumKey` adds defense in depth and consistency.

---

### Step-by-Step Implementation

**Step 1: Add `EnumKey` struct and its `de::Deserializer` impl in `/workspace/src/de.rs`**

Place this immediately after or near the `MapKey` struct definition (around line 2153), since `EnumKey` is conceptually analogous.

The struct:
```rust
struct EnumKey<'a, R: 'a> {
    de: &'a mut Deserializer<R>,
}
```

The `de::Deserializer` impl:
```rust
impl<'de, 'a, R> de::Deserializer<'de> for EnumKey<'a, R>
where
    R: Read<'de>,
{
    type Error = Error;

    #[inline]
    fn deserialize_any<V>(self, visitor: V) -> Result<V::Value>
    where
        V: de::Visitor<'de>,
    {
        match tri!(self.de.peek()) {
            Some(b'"') => {
                self.de.eat_char();
                self.de.scratch.clear();
                match tri!(self.de.read.parse_str(&mut self.de.scratch)) {
                    Reference::Borrowed(s) => visitor.visit_borrowed_str(s),
                    Reference::Copied(s) => visitor.visit_str(s),
                }
            }
            Some(_) => Err(self.de.peek_error(ErrorCode::KeyMustBeAString)),
            None => Err(self.de.peek_error(ErrorCode::EofWhileParsingValue)),
        }
    }

    forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64
        char str string bytes byte_buf option unit unit_struct newtype_struct
        seq tuple tuple_struct map struct enum identifier ignored_any
    }
}
```

The `forward_to_deserialize_any!` macro forwards all other `deserialize_*` calls to `deserialize_any`, which enforces the string constraint uniformly.

**Step 2: Modify `VariantAccess::variant_seed` in `/workspace/src/de.rs`**

Change the call at line 2055 from:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```
to:
```rust
let val = tri!(seed.deserialize(EnumKey { de: &mut *self.de }));
```

This is the critical fix. `UnitVariantAccess::variant_seed` can remain unchanged since the routing in `deserialize_enum` guarantees `b'"'` is the next byte when `UnitVariantAccess` is used.

**Step 3: Add regression test in `/workspace/tests/regression/issue979.rs`**

Create the file (picked up automatically by `automod::dir!` from `tests/regression.rs`):

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

The test module is automatically included because `tests/regression.rs` uses `automod::dir!("tests/regression")`.

---

### Design Decisions and Trade-offs

**Why `EnumKey` instead of a simple peek check in `variant_seed`?**

A simple peek check would look like:
```rust
match tri!(self.de.peek()) {
    Some(b'"') => {}
    Some(_) => return Err(self.de.peek_error(ErrorCode::KeyMustBeAString)),
    None => return Err(self.de.peek_error(ErrorCode::EofWhileParsingValue)),
}
let val = tri!(seed.deserialize(&mut *self.de));
```

This would work for the specific reported bug case (`[true]`), but it is fragile: after the peek, `seed.deserialize(&mut *self.de)` still uses the full deserializer, and `deserialize_any` on the full deserializer would consume the `"` and parse the string correctly. However, a malicious or unusual seed could call `deserialize_seq` or `deserialize_bool` and still misparse things if the input happened to be something other than an array that starts with `"`. The `EnumKey` wrapper approach is more robust because it makes the string constraint hold regardless of what method the seed chooses to call.

**Why `KeyMustBeAString` error code?**

This is the existing error code used in `has_next_key` (for map key validation) and `MapKey` (for non-numeric keys). It produces the message `"key must be a string"`, which is semantically correct for this scenario. No new error code is needed.

**Why `forward_to_deserialize_any!` for all types?**

The `EnumKey` wrapper is intentionally restrictive: only JSON strings are valid enum variant names. Unlike `MapKey`, which supports numeric keys wrapped in quotes (for `#[serde(rename)]` patterns with numeric map keys), enum variant names in Rust are always identifiers (strings). So it's correct to unconditionally reject non-strings for all deserialize methods by forwarding everything to `deserialize_any`.

---

### Critical Files for Implementation

- `/workspace/src/de.rs` - Core logic: add `EnumKey` struct + impl, fix `VariantAccess::variant_seed` to use it
- `/workspace/tests/regression/issue979.rs` - New regression test file to create
- `/workspace/tests/regression/issue953.rs` - Pattern to follow for regression test structure