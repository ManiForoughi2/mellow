//! small JSON-like value type for decoded record fields.
//!
//! decoders return an ordered name -> [`Value`] map, keeps the crate dep-free
//! while serializing to canonical JSON. insertion order preserved so output stable

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    /// unsigned values that may exceed i64 (e.g. u64 detection masks)
    UInt(u64),
    Float(f64),
    Str(String),
    Array(Vec<Value>),
    Object(Map),
}

/// insertion-ordered string->value map
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Map {
    entries: Vec<(String, Value)>,
}

impl Map {
    pub fn new() -> Self {
        Map {
            entries: Vec::new(),
        }
    }

    /// insert or replace `key`, preserves position on replace
    pub fn insert(&mut self, key: impl Into<String>, value: Value) -> &mut Self {
        let key = key.into();
        if let Some(slot) = self.entries.iter_mut().find(|(k, _)| *k == key) {
            slot.1 = value;
        } else {
            self.entries.push((key, value));
        }
        self
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &Value)> {
        self.entries.iter().map(|(k, v)| (k, v))
    }
}

impl Value {
    pub fn obj(map: Map) -> Value {
        Value::Object(map)
    }

    /// compact canonical JSON (separators `,`/`:`), NaN/Inf floats serialize as
    /// `null`
    pub fn to_json(&self) -> String {
        let mut s = String::new();
        self.write_json(&mut s);
        s
    }

    fn write_json(&self, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Int(i) => {
                let _ = write!(out, "{i}");
            }
            Value::UInt(u) => {
                let _ = write!(out, "{u}");
            }
            Value::Float(f) => {
                if f.is_finite() {
                    let _ = write!(out, "{f}");
                } else {
                    out.push_str("null");
                }
            }
            Value::Str(s) => write_json_string(s, out),
            Value::Array(arr) => {
                out.push('[');
                for (i, v) in arr.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write_json(out);
                }
                out.push(']');
            }
            Value::Object(map) => {
                out.push('{');
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_json_string(k, out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
        }
    }
}

fn write_json_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// hex-encode a byte slice (lowercase, no separators)
pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// [`Value::Array`] of ints from a byte slice
pub fn u8_array(bytes: &[u8]) -> Value {
    Value::Array(bytes.iter().map(|&b| Value::Int(b as i64)).collect())
}

#[inline]
pub fn i8_of(b: u8) -> i64 {
    if b & 0x80 != 0 {
        b as i64 - 0x100
    } else {
        b as i64
    }
}

#[inline]
pub fn u16_le(b: &[u8], off: usize) -> i64 {
    (b[off] as i64) | ((b[off + 1] as i64) << 8)
}

#[inline]
pub fn i16_le(b: &[u8], off: usize) -> i64 {
    let v = (b[off] as i64) | ((b[off + 1] as i64) << 8);
    if v & 0x8000 != 0 {
        v - 0x10000
    } else {
        v
    }
}

#[inline]
pub fn u32_le(b: &[u8], off: usize) -> i64 {
    (b[off] as i64)
        | ((b[off + 1] as i64) << 8)
        | ((b[off + 2] as i64) << 16)
        | ((b[off + 3] as i64) << 24)
}

#[inline]
pub fn i32_le(b: &[u8], off: usize) -> i64 {
    let v = u32_le(b, off);
    if v & 0x8000_0000 != 0 {
        v - 0x1_0000_0000
    } else {
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_object_order_preserved() {
        let mut m = Map::new();
        m.insert("b", Value::Int(2));
        m.insert("a", Value::Int(1));
        assert_eq!(Value::obj(m).to_json(), r#"{"b":2,"a":1}"#);
    }

    #[test]
    fn le_helpers() {
        let b = [0x00, 0x80, 0xff, 0xff];
        assert_eq!(u16_le(&b, 0), 0x8000);
        assert_eq!(i16_le(&b, 0), -32768);
        assert_eq!(u32_le(&b, 0), 0xffff8000);
        assert_eq!(i8_of(0xff), -1);
    }
}
