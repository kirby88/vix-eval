Fix a bug in the serde_json crate (serde-rs/json, issue #979 https://github.com/serde-rs/json/issues/979).

## Bug Description

`EnumAccess::variant` silently accepts non-string JSON object member names, 
which violates the JSON spec. For example, the malformed JSON `{[true]: null}` 
is parsed without error when using a custom `Visitor` that calls 
`data.variant()` via `deserialize_enum`.

## Root Cause

In `src/de.rs`, the `EnumAccess` implementation's `variant` method deserializes 
the object key using a generic `seed.deserialize(&mut *self.de)` call. This 
allows the deserializer to accept any JSON value (arrays, numbers, booleans, 
etc.) as an object member name, instead of enforcing that it must be a JSON 
string.

The relevant line is approximately:
    let val = tri!(seed.deserialize(&mut *self.de));

## Required Fix

Enforce that the JSON object member key is a string before passing it to the 
seed deserializer. You should either:
  - Parse the key as a string first and return an error if it is not, OR
  - Use a wrapper deserializer that only accepts strings (similar to how the
    `MapKey` deserializer is implemented elsewhere in the file)

Do NOT accept non-string values as enum variant keys under any circumstance.

## Regression Test

Add a test (e.g. in `tests/regression/issue979.rs`) that verifies the 
following malformed JSON returns an error when deserialized via `deserialize_enum`:

    {[true]: null}

The reproducer from the issue demonstrates the bug:

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

## Files to Look At

- `src/de.rs` — specifically the `EnumAccess` impl (look for `impl EnumAccess` 
  or `visit_enum`, and the key-reading code in `variant()`)
- `tests/regression/` — add the new regression test here