//! `oura_core` - pure-Rust dependency-free decoder for the Oura Ring 4 BLE wire
//! protocol (read-only, personal interop with a ring you own).
//!
//! owns the portable half: handshake proof, framing (outer frames + inner TLV),
//! per-record decoders, ring_time->UTC resolver, control-plane frame builders.
//! transport and persistence live in the host app; this crate is clock-, RNG-,
//! and I/O-free so output is identical on every platform
//!
//! ## Layout
//!
//! - [`aes`] - AES-128-ECB, only primitive the handshake needs
//! - [`crypto`] - handshake proof + `auth_key` extraction from `assa-store.realm`
//! - [`framing`] - outer-frame and inner-TLV parsers
//! - [`enums`] - canonical `API_*` / state / motion names
//! - [`decoders`] - per-type wire decoders + 0x61 debug-data sub-decoders
//! - [`sync_state`] - delta-resume cursor + ring_time->UTC anchor math
//! - [`commands`] - control-plane outer-frame builders
//! - [`value`] - JSON-like value/map type decoders emit
//!
//! ## Quick start
//!
//! ```
//! use oura_core::{framing, decoders};
//!
//! // A single notify-char value carrying one inner TLV record.
//! let value = [0x42u8, 0x0d, 0x01, 0x00, 0x00, 0x00, /* token */ 0x01,
//!              /* counter:3 */ 0x10, 0x20, 0x00, /* const */ 0,0,0,0,0];
//! for rec in framing::parse_inner_records(&value) {
//!     let data = decoders::decode(rec.type_byte, &rec.payload);
//!     let _ = oura_core::value::Value::Object(data).to_json();
//! }
//! ```

pub mod aes;
pub mod commands;
pub mod crypto;
pub mod decoders;
pub mod enums;
pub mod framing;
pub mod health;
pub mod metrics;
pub mod state;
pub mod sync_state;
pub mod value;

#[cfg(feature = "cabi")]
pub mod cabi;

use value::{Map, Value};

/// decoded inner record: framing header + decoded `data` map + canonical name
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedRecord {
    pub type_byte: u8,
    /// canonical name (`API_*` or `UNKNOWN_0xNN`)
    pub type_name: String,
    pub ring_time: u32,
    pub counter: u16,
    pub session: u16,
    pub data: Map,
    /// true if this tag should not advance the cursor / time anchor
    pub structurally_unknown: bool,
}

impl DecodedRecord {
    pub fn to_json(&self) -> String {
        let mut m = Map::new();
        m.insert("tag", Value::Str(format!("0x{:02x}", self.type_byte)));
        m.insert("type", Value::Str(self.type_name.clone()));
        m.insert("rt", Value::Int(self.ring_time as i64));
        m.insert("ctr", Value::Int(self.counter as i64));
        m.insert("sess", Value::Int(self.session as i64));
        m.insert("data", Value::Object(self.data.clone()));
        Value::Object(m).to_json()
    }
}

/// app-facing JSON array for every inner record in one notify-char value.
/// each element: framing fields + derived health metrics (from [`health`]) +
/// a `fields` label/value array for the debug inspector
pub fn app_records_json(value: &[u8]) -> String {
    let mut arr: Vec<Value> = Vec::new();
    for rec in framing::parse_inner_records(value) {
        let tag = rec.type_byte;
        let p = &rec.payload;
        let mut m = Map::new();
        m.insert("tag", Value::Int(tag as i64));
        m.insert("type", Value::Str(enums::canonical_type(tag)));
        m.insert("rt", Value::Int(rec.ring_time() as i64));
        m.insert(
            "structurally_unknown",
            Value::Bool(enums::is_structurally_unknown(tag)),
        );

        let mut fields: Vec<Value> = Vec::new();
        let field = |k: &str, v: String, fields: &mut Vec<Value>| {
            fields.push(Value::Array(vec![Value::Str(k.to_string()), Value::Str(v)]));
        };

        match tag {
            0x42 => {
                if p.len() == 9 {
                    let counter = (p[1] as i64) | ((p[2] as i64) << 8) | ((p[3] as i64) << 16);
                    let mut ts = Map::new();
                    ts.insert("ring_time", Value::Int(rec.ring_time() as i64));
                    ts.insert("ring_unix_approx_s", Value::Int(counter * 256));
                    ts.insert("token", Value::Int(p[0] as i64));
                    m.insert("time_sync", Value::Object(ts));
                    field("token", p[0].to_string(), &mut fields);
                    field("time_counter", counter.to_string(), &mut fields);
                    field("ring_unix_s", (counter * 256).to_string(), &mut fields);
                }
            }
            0x43 => {
                let text = ascii(p);
                m.insert("debug_text", Value::Str(text.clone()));
                field("text", text, &mut fields);
            }
            0x46 => {
                if let Some(t) = health::temp_primary_c(p) {
                    m.insert("temp_c", Value::Float(t));
                }
                if p.len() >= 4 && p.len() <= 14 && p.len() % 2 == 0 {
                    for (off, signed) in
                        [(0, false), (2, false), (4, true), (6, true), (8, true), (10, true), (12, true)]
                    {
                        if off + 2 <= p.len() {
                            let raw = if signed {
                                value::i16_le(p, off)
                            } else {
                                value::u16_le(p, off)
                            };
                            let v = raw as f64 / 100.0;
                            if (v - (-327.68)).abs() >= f64::EPSILON {
                                field(&format!("temp@{off}_c"), format!("{v:.2}"), &mut fields);
                            }
                        }
                    }
                }
            }
            0x45 | 0x53 => {
                if !p.is_empty() {
                    let st = p[0] as i64;
                    let name = enums::state_change(p[0])
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| format!("STATE_{st}"));
                    m.insert("state_name", Value::Str(name.clone()));
                    let text = ascii(&p[1..]);
                    field("state", st.to_string(), &mut fields);
                    field("state_name", name, &mut fields);
                    field("text", text, &mut fields);
                }
            }
            0x5d => {
                if let Some((hr, rmssd)) = health::hrv_current(p) {
                    m.insert("hrv_hr_bpm", Value::Int(hr));
                    m.insert("hrv_rmssd_ms", Value::Int(rmssd));
                }
                let mut i = 0;
                let mut idx = 0;
                while i + 1 < p.len() {
                    field(
                        &format!("win{idx}"),
                        format!("hr={} rmssd={}", p[i], p[i + 1]),
                        &mut fields,
                    );
                    i += 2;
                    idx += 1;
                }
            }
            0x60 => {
                let ibis = health::ibi60_intervals(p);
                if let Some(hr) = health::hr_from_ibis(&ibis) {
                    m.insert("instant_hr_bpm", Value::Float(hr));
                    field("hr_bpm", format!("{hr:.0}"), &mut fields);
                }
                if !ibis.is_empty() {
                    let joined = ibis
                        .iter()
                        .map(|v| v.to_string())
                        .collect::<Vec<_>>()
                        .join(",");
                    field("ibi_ms", joined, &mut fields);
                }
            }
            0x80 => {
                let ibis = health::green_ibi_filtered(p);
                if let Some(hr) = health::hr_from_ibis(&ibis) {
                    m.insert("instant_hr_bpm", Value::Float(hr));
                    field("hr_bpm", format!("{hr:.0}"), &mut fields);
                }
                let joined = ibis
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                field("filtered_ibi_ms", joined, &mut fields);
            }
            0x6f => {
                if let Some(avg) = health::spo2_average(p) {
                    m.insert("spo2_percent", Value::Int(avg));
                }
                let end = if p.len() > 1 && p[p.len() - 1] == 0xff {
                    p.len() - 1
                } else {
                    p.len()
                };
                if end > 1 {
                    let joined = p[1..end]
                        .iter()
                        .map(|v| v.to_string())
                        .collect::<Vec<_>>()
                        .join(",");
                    field("spo2_percent", joined, &mut fields);
                }
            }
            0x7e | 0x7f => {
                if p.len() == 14 {
                    m.insert("step_feature_bytes", value::u8_array(p));
                    let joined = p.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",");
                    field("u8", joined, &mut fields);
                }
            }
            0x76 => {
                if p.len() >= 8 {
                    let start = value::u32_le(p, 0);
                    let end = value::u32_le(p, 4);
                    // bedtime period from ring's own boundaries, app builds the
                    // sleep window from this not just HR coverage
                    m.insert("bedtime_start_rt", Value::Int(start));
                    m.insert("bedtime_end_rt", Value::Int(end));
                    field("start_rt", start.to_string(), &mut fields);
                    field("end_rt", end.to_string(), &mut fields);
                }
            }
            0x6a => {
                // SleepPeriodInfo: ring's per-period sleep readouts (stage tag,
                // respiratory rate, avg HR, motion count) surfaced for metrics
                let d = decoders::decode(0x6a, p);
                if let Some(value::Value::Float(b)) = d.get("breath") {
                    m.insert("respiratory_rate", Value::Float(*b));
                    field("breath", format!("{b:.1}"), &mut fields);
                }
                if let Some(value::Value::Float(hr)) = d.get("average_hr") {
                    m.insert("sleep_avg_hr", Value::Float(*hr));
                    field("avg_hr", format!("{hr:.0}"), &mut fields);
                }
                if let Some(value::Value::Int(st)) = d.get("sleep_state") {
                    // 0 = deep/SWS, 1 = light/REM-ish, 2 = wake (decoder [0..2])
                    m.insert("sleep_state", Value::Int(*st));
                    field("sleep_state", st.to_string(), &mut fields);
                }
                if let Some(value::Value::Int(mc)) = d.get("motion_count") {
                    m.insert("sleep_motion_count", Value::Int(*mc));
                    field("motion_count", mc.to_string(), &mut fields);
                }
            }
            0x6b => {
                if !p.is_empty() {
                    let name = enums::motion_state(p[0])
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| format!("MOTION_{}", p[0]));
                    field("motion_state", name, &mut fields);
                }
            }
            _ => {
                field("payload", value::hex(p), &mut fields);
            }
        }

        m.insert("fields", Value::Array(fields));
        arr.push(Value::Object(m));
    }
    Value::Array(arr).to_json()
}

fn ascii(b: &[u8]) -> String {
    b.iter()
        .map(|&c| if c < 0x80 { c as char } else { '\u{FFFD}' })
        .collect()
}

/// parse and decode every inner record in one notify-char value.
/// transport calls this once [`framing::looks_like_outer_frame`] says the value
/// is an inner-record stream not outer frames
pub fn decode_inner_records(value: &[u8]) -> Vec<DecodedRecord> {
    framing::parse_inner_records(value)
        .into_iter()
        .map(|rec| {
            let data = decoders::decode(rec.type_byte, &rec.payload);
            DecodedRecord {
                type_name: enums::canonical_type(rec.type_byte),
                structurally_unknown: enums::is_structurally_unknown(rec.type_byte),
                ring_time: rec.ring_time(),
                type_byte: rec.type_byte,
                counter: rec.counter,
                session: rec.session,
                data,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn end_to_end_time_sync() {
        // type=0x42 len=13: ctr+sess (4) + 9-byte TimeSyncInd payload
        let value = [
            0x42, 0x0d, 0x01, 0x00, 0x00, 0x00, // ctr=1 sess=0
            0x05, // token
            0x10, 0x20, 0x00, // counter LE
            0, 0, 0, 0, 0, // const
        ];
        let recs = decode_inner_records(&value);
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].type_name, "API_TIME_SYNC_IND");
        assert_eq!(recs[0].ring_time, 1);
        assert_eq!(
            recs[0].data.get("time_counter"),
            Some(&Value::Int(0x002010))
        );
    }
}
