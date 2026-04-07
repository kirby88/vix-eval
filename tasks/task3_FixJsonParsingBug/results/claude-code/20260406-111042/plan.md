# Fix: EnumAccess::variant_seed silently accepts non-string object keys (issue #979)

## Context

`EnumAccess::variant_seed` in `src/de.rs` uses `seed.deserialize(&mut *self.de)` to read the
variant name from a JSON object key. This bypasses string enforcement and lets any JSON value
(arrays, numbers, booleans) appear as the key. The JSON spec requires object member names to
be strings.

The `MapKey` deserializer (same file) already solves the string-enforcement problem for map
keys — we just need to apply the same wrapper to enum variant keys.

## Fix (one-line change in `src/de.rs`)

**File:** `src/de.rs`, in `impl de::EnumAccess<'de> for VariantAccess<'a, R>` (~line 2047)

Change the `variant_seed` method from:
```rust
let val = tri!(seed.deserialize(&mut *self.de));
```
to:
```rust
let val = tri!(seed.deserialize(MapKey { de: &mut *self.de }));
```

`MapKey` is a private struct defined in the same file. Its `deserialize_any` calls
`parse_str()`, and the `forward_to_deserialize_any!` macro routes all non-numeric types
through it, so non-string values will produce an error.

## Regression Test

**New file:** `tests/regression/issue979.rs`

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

The test file must also be declared as a module. Check whether `tests/regression/` uses a
`mod.rs` or a top-level `tests/regression.rs` file to include submodules, then add
`mod issue979;` there.

## Verification

1. `cargo test` — all existing tests pass
2. `cargo test --test regression issue979` — new test passes (returns `Err`)
3. Optionally `cargo test --all-features` to cover the `arbitrary_precision` path
