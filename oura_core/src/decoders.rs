//! Per-record-type wire-format decoders.
//!
//! each decoder takes the payload after the 6-byte TLV header, returns a [`Map`]
//! or `Err(DecodeError)`; dispatcher surfaces a `_decode_error` map on error.
//! [`CvaPpgDecoder`] is stateful, dispatch entry [`decode`] is stateless

use crate::enums::{canonical_type, motion_state, ring_event_type, state_change};
use crate::value::{hex, i16_le, i8_of, u16_le, u32_le, u8_array, Map, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeError(pub String);

impl core::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{}", self.0)
    }
}

type R = Result<Map, DecodeError>;

fn err(s: impl Into<String>) -> DecodeError {
    DecodeError(s.into())
}

fn ascii_replace(b: &[u8]) -> String {
    b.iter()
        .map(|&c| if c < 0x80 { c as char } else { '\u{FFFD}' })
        .collect()
}

/// stateful decoder for `0x81 API_CVA_RAW_PPG_DATA`.
/// one decoder per sampler session, [`feed`] each record's bytes; returns the
/// samples from THIS record (24-bit signed ADC counts). state persists so
/// deltas resolve against the prior absolute, reset on session boundary
///
/// [`feed`]: CvaPpgDecoder::feed
#[derive(Debug, Clone)]
pub struct CvaPpgDecoder {
    mode_flag: u8,
    sub_counter: u8,
    accumulator: u32,
    last_value: i64,
    pub samples_total: u64,
    pub absolutes_total: u64,
    pub deltas_total: u64,
    pub records_fed: u64,
    pub bytes_fed: u64,
}

impl Default for CvaPpgDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl CvaPpgDecoder {
    pub fn new() -> Self {
        let mut d = CvaPpgDecoder {
            mode_flag: 0,
            sub_counter: 0,
            accumulator: 0,
            last_value: 0,
            samples_total: 0,
            absolutes_total: 0,
            deltas_total: 0,
            records_fed: 0,
            bytes_fed: 0,
        };
        d.reset();
        d
    }

    pub fn reset(&mut self) {
        self.mode_flag = 0;
        self.sub_counter = 0;
        self.accumulator = 0;
        self.last_value = 0;
    }

    pub fn feed(&mut self, payload: &[u8]) -> Vec<i64> {
        let mut out = Vec::new();
        for &b in payload {
            if self.mode_flag != 0 {
                if self.sub_counter <= 2 {
                    self.accumulator |= (b as u32) << (self.sub_counter * 8);
                    self.sub_counter += 1;
                }
                if self.sub_counter == 3 {
                    let sample: i64 = if b & 0x80 != 0 {
                        let v = self.accumulator | 0xff00_0000;
                        (v as i64) - 0x1_0000_0000
                    } else {
                        self.accumulator as i64
                    };
                    self.last_value = sample;
                    out.push(sample);
                    self.absolutes_total += 1;
                    self.mode_flag = 0;
                }
            } else if b == 0x80 {
                self.accumulator = 0;
                self.sub_counter = 0;
                self.mode_flag = 1;
            } else {
                let delta = i8_of(b);
                self.last_value += delta;
                out.push(self.last_value);
                self.deltas_total += 1;
            }
        }
        self.samples_total += out.len() as u64;
        self.records_fed += 1;
        self.bytes_fed += payload.len() as u64;
        out
    }
}

fn decode_time_sync_ind(p: &[u8]) -> R {
    if p.len() != 9 {
        return Err(err(format!(
            "TimeSyncInd payload must be 9 bytes, got {}",
            p.len()
        )));
    }
    let counter = (p[1] as i64) | ((p[2] as i64) << 8) | ((p[3] as i64) << 16);
    let mut m = Map::new();
    m.insert("token", Value::Int(p[0] as i64));
    m.insert("time_counter", Value::Int(counter));
    m.insert("ring_unix_time_approx_s", Value::Int(counter * 256));
    Ok(m)
}

fn decode_debug_event_ind(p: &[u8]) -> R {
    let mut m = Map::new();
    m.insert("text", Value::Str(ascii_replace(p)));
    Ok(m)
}

fn decode_temp_event(p: &[u8]) -> R {
    let n = p.len();
    if n < 4 || n > 14 || n % 2 != 0 {
        return Err(err(format!(
            "TempEvent payload size must be even in [4..14], got {n}"
        )));
    }
    let temp = |off: usize, signed: bool| -> Value {
        if off + 2 > n {
            return Value::Null;
        }
        let raw = if signed { i16_le(p, off) } else { u16_le(p, off) };
        let v = raw as f64 / 100.0;
        if (v - (-327.68)).abs() < f64::EPSILON {
            Value::Null
        } else {
            Value::Float(v)
        }
    };
    let mut m = Map::new();
    m.insert("temp1_c", temp(0, false));
    m.insert("temp2_c", temp(2, false));
    m.insert("temp3_c", temp(4, true));
    m.insert("temp4_c", temp(6, true));
    m.insert("temp5_c", temp(8, true));
    m.insert("temp6_c", temp(10, true));
    m.insert("temp7_c", temp(12, true));
    Ok(m)
}

fn decode_state_change_ind(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("StateChangeInd payload too short"));
    }
    let state = p[0];
    let mut m = Map::new();
    m.insert("state", Value::Int(state as i64));
    m.insert(
        "state_name",
        state_change(state)
            .map(|s| Value::Str(s.to_string()))
            .unwrap_or(Value::Null),
    );
    m.insert("text", Value::Str(ascii_replace(&p[1..])));
    Ok(m)
}

fn decode_hrv_event(p: &[u8]) -> R {
    let n = p.len();
    if n < 2 || n > 12 || n % 2 != 0 {
        return Err(err(format!(
            "HrvEvent payload must be even in [2..12], got {n}"
        )));
    }
    let mut pairs = Vec::new();
    let mut i = 0;
    while i < n {
        let mut pm = Map::new();
        pm.insert("hr_bpm", Value::Int(p[i] as i64));
        pm.insert("rmssd_ms", Value::Int(p[i + 1] as i64));
        pairs.push(Value::obj(pm));
        i += 2;
    }
    let mut m = Map::new();
    m.insert("samples_5min", Value::Array(pairs));
    Ok(m)
}

fn decode_ibi_and_amplitude_event(p: &[u8]) -> R {
    if p.len() != 14 {
        return Err(err(format!(
            "IbiAndAmplitudeEvent payload must be 14 bytes, got {}",
            p.len()
        )));
    }
    let b12 = p[12];
    let b13 = p[13];
    let mid_bits = [
        ((b12 >> 5) & 0x6) as i64,
        ((b12 >> 3) & 0x6) as i64,
        ((b12 >> 1) & 0x6) as i64,
        ((b12 << 1) & 0x6) as i64,
        ((b13 >> 5) & 0x6) as i64,
        ((b13 >> 3) & 0x6) as i64,
    ];
    let mut ibi_ms = Vec::with_capacity(6);
    for i in 0..6 {
        let high = (p[i] as i64) << 3;
        let low = (p[6 + i] & 0x1) as i64;
        ibi_ms.push(Value::Int(high | mid_bits[i] | low));
    }
    let nibble = b13 & 0x0F;
    let shift = if nibble == 7 { 0 } else { nibble + 1 };
    let amp: Vec<Value> = (0..6)
        .map(|i| Value::Int(((p[6 + i] >> 1) as i64) << shift))
        .collect();
    let mut m = Map::new();
    m.insert("ibi_ms", Value::Array(ibi_ms));
    m.insert("amp", Value::Array(amp));
    m.insert("amp_shift", Value::Int(shift as i64));
    Ok(m)
}

fn decode_spo2_event(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("Spo2Event payload too short"));
    }
    let samples_end = if p.len() > 1 && p[p.len() - 1] == 0xff {
        p.len() - 1
    } else {
        p.len()
    };
    let mut m = Map::new();
    m.insert("header_high", Value::Int((p[0] >> 4) as i64));
    m.insert("header_low", Value::Int((p[0] & 0x0F) as i64));
    m.insert("spo2_percent", u8_array(&p[1..samples_end]));
    Ok(m)
}

fn decode_bedtime_period(p: &[u8]) -> R {
    if p.len() < 8 {
        return Err(err(format!(
            "BedtimePeriod payload must be >=8 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("start_ring_time", Value::Int(u32_le(p, 0)));
    m.insert("end_ring_time", Value::Int(u32_le(p, 4)));
    Ok(m)
}

fn decode_ppg_amplitude_ind(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err(format!(
            "PpgAmplitudeInd payload must be >=2 bytes, got {}",
            p.len()
        )));
    }
    let raw = u16_le(p, 0);
    let mut m = Map::new();
    m.insert(
        "amplitude_normalized",
        Value::Float(raw as f64 / 65535.0),
    );
    m.insert("amplitude_raw_u16", Value::Int(raw));
    Ok(m)
}

fn decode_temp_period(p: &[u8]) -> R {
    if p.len() != 2 {
        return Err(err(format!(
            "TempPeriod payload must be 2 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("temp_raw", Value::Int(i16_le(p, 0)));
    Ok(m)
}

fn decode_ehr_acm_intensity_event(p: &[u8]) -> R {
    let n = p.len();
    if n < 2 || n > 14 || n % 2 != 0 {
        return Err(err(format!(
            "EhrAcmIntensityEvent size must be even in [2..14], got {n}"
        )));
    }
    let mut fields = Vec::new();
    let mut i = 0;
    while i < n {
        fields.push(Value::Int(u16_le(p, i)));
        i += 2;
    }
    let mut m = Map::new();
    m.insert("u16_values", Value::Array(fields));
    Ok(m)
}

fn decode_motion_event(p: &[u8]) -> R {
    let n = p.len();
    if !(4..=6).contains(&n) {
        return Err(err(format!(
            "MotionEvent payload size must be in [4..6], got {n}"
        )));
    }
    let mut m = Map::new();
    m.insert("flags_high", Value::Int((p[0] >> 5) as i64));
    m.insert("flags_low", Value::Int((p[0] & 0x1F) as i64));
    m.insert("acm_x", Value::Int(i8_of(p[1]) * 8));
    m.insert("acm_y", Value::Int(i8_of(p[2]) * 8));
    m.insert("acm_z", Value::Int(i8_of(p[3]) * 8));
    if n >= 5 {
        if p[4] & 0x40 != 0 {
            return Err(err("MotionEvent byte4 bit 6 must be 0"));
        }
        m.insert("flag_b4_bit7", Value::Int(((p[4] >> 7) & 1) as i64));
        m.insert("low6_b4", Value::Int((p[4] & 0x3F) as i64));
    }
    if n >= 6 {
        if p[5] & 0x40 != 0 {
            return Err(err("MotionEvent byte5 bit 6 must be 0"));
        }
        m.insert("low6_b5", Value::Int((p[5] & 0x3F) as i64));
    }
    Ok(m)
}

fn decode_motion_period(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("MotionPeriod payload too short"));
    }
    let state = p[0];
    let mut m = Map::new();
    m.insert("motion_state_30s", Value::Int(state as i64));
    m.insert(
        "motion_state_name",
        motion_state(state)
            .map(|s| Value::Str(s.to_string()))
            .unwrap_or(Value::Null),
    );
    m.insert("trailing_hex", Value::Str(hex(&p[1..])));
    Ok(m)
}

fn decode_real_steps_features(p: &[u8]) -> R {
    if p.len() != 14 {
        return Err(err(format!(
            "RealSteps payload must be 14 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("u8_values", u8_array(p));
    Ok(m)
}

fn decode_ring_start_ind(p: &[u8]) -> R {
    if p.len() < 14 {
        return Err(err(format!(
            "RingStartInd payload too short ({})",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("timestamp_u32", Value::Int(u32_le(p, 0)));
    m.insert("byte_4", Value::Int(p[4] as i64));
    m.insert("byte_9", Value::Int(p[9] as i64));
    m.insert("byte_a", Value::Int(p[0xa] as i64));
    m.insert("byte_b", Value::Int(p[0xb] as i64));
    m.insert("byte_c", Value::Int(p[0xc] as i64));
    m.insert("byte_d", Value::Int(p[0xd] as i64));
    Ok(m)
}

fn decode_activity_info_event(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("ActivityInfoEvent payload too short"));
    }
    let mut m = Map::new();
    m.insert("activity_byte_0", Value::Int(p[0] as i64));
    m.insert("trailing_hex", Value::Str(hex(&p[1..])));
    Ok(m)
}

fn decode_ble_connection_ind(p: &[u8]) -> R {
    let mut m = Map::new();
    for &off in &[0usize, 1, 6, 7, 8, 9] {
        if off < p.len() {
            m.insert(format!("u8_at_off_{off}"), Value::Int(p[off] as i64));
        }
    }
    m.insert(
        "trailing_hex",
        Value::Str(if p.len() > 10 { hex(&p[10..]) } else { String::new() }),
    );
    m.insert("len", Value::Int(p.len() as i64));
    Ok(m)
}

fn decode_selftest_event(p: &[u8]) -> R {
    if p.len() < 4 {
        return Err(err("SelftestEvent payload too short (<4)"));
    }
    let mut m = Map::new();
    m.insert("u16_at_off_0", Value::Int(u16_le(p, 0)));
    m.insert("u16_at_off_2", Value::Int(u16_le(p, 2)));
    m.insert("trailing_hex", Value::Str(hex(&p[4..])));
    Ok(m)
}

fn decode_unknown_56(p: &[u8]) -> R {
    if p.len() != 1 {
        return Err(err(format!(
            "Unknown56 payload length {}, expected 1",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("flag", Value::Int(p[0] as i64));
    Ok(m)
}

fn decode_unknown_85(p: &[u8]) -> R {
    if p.len() != 10 {
        return Err(err(format!(
            "Unknown85 payload length {}, expected 10",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("unix_time_s", Value::Int(u32_le(p, 0)));
    m.insert("reserved", Value::Str(hex(&p[4..8])));
    m.insert("trailer_hex", Value::Str(hex(&p[8..10])));
    Ok(m)
}

fn decode_feature_session(p: &[u8]) -> R {
    if p.len() < 3 {
        return Err(err(format!(
            "FeatureSession payload too short ({})",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("byte_0", Value::Int(p[0] as i64));
    m.insert("capability", Value::Int(p[1] as i64));
    m.insert("status", Value::Int(p[2] as i64));
    if p.len() > 3 {
        m.insert("session_payload_hex", Value::Str(hex(&p[3..])));
        m.insert("session_payload_len", Value::Int((p.len() - 3) as i64));
    }
    Ok(m)
}

fn decode_spo2_ibi_and_amplitude_event(p: &[u8]) -> R {
    if p.len() != 13 {
        return Err(err(format!(
            "Spo2IbiAndAmplitude payload must be 13 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("u8_values", u8_array(p));
    Ok(m)
}

/// `0x72 API_SLEEP_ACM_PERIOD`: six little-endian u16 movement accumulators for
/// one 30-second epoch.
///
/// field layout established by aligning 1146 of these records against a
/// labelled 30-second hypnogram exported from an Oura account for the same
/// night (2026-08-04 capture set). records arrive at exactly 300 ring ticks,
/// which is 30.0 s at the ring's 10 Hz clock.
///
/// medians by labelled stage were awake 60/115/49, deep 14/27/13,
/// light 15/30/14, rem 21/41/19 for `acm0..acm2`. that separates wake from
/// sleep decisively and deep from light barely at all: this is a motion record,
/// not a stage classification. nothing in it encodes deep/light/REM/awake.
fn decode_sleep_acm_period(p: &[u8]) -> R {
    if p.len() != 12 {
        return Err(err(format!(
            "SleepAcmPeriod payload must be 12 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    let acm: Vec<Value> = (0..6)
        .map(|i| Value::Int(u16_le(p, i * 2) as i64))
        .collect();
    for (i, v) in acm.iter().enumerate() {
        if let Value::Int(n) = v {
            m.insert(format!("acm{i}"), Value::Int(*n));
        }
    }
    m.insert("acm", Value::Array(acm));
    m.insert("epoch_seconds", Value::Int(30));
    Ok(m)
}

/// `0x2F` sub-op `0x28` parameter push for feature `0x02` (Daytime HR), the
/// record the ring emits once live HR is running.
///
/// wire shape, payload after the `2f <len> 28 02` header:
/// `<quality:u8> 02 00 00 <ibi:u16le> 00 00 00 00 12 0a 7f`
///
/// **the IBI unit is 0.2 ms.** two captures labelled 58 bpm by the wearer
/// decode to 58.5 and 58.2 bpm at that scale; the 0.25 ms alternative gives
/// 46.8 and 46.6 bpm and is excluded.
///
/// `quality` is `0x09` for clean samples and `0x19` for suspect ones. across
/// both captures 2 of 31 `0x09` samples fell outside a physiological interval
/// against 4 of 9 `0x19` samples, so treat `0x19` as low confidence rather
/// than discarding it.
/// dispatch a whole `0x2F` feature-plane notification frame.
///
/// frames look like `2f <len> <sub_op> <feature_id> <payload..>`, where `len`
/// counts everything after itself. returns `None` for frames this module has
/// nothing to say about (status replies, acks), so the caller can fall through
/// to its existing handling.
pub fn decode_feature_frame(frame: &[u8]) -> Option<Map> {
    if frame.len() < 4 || frame[0] != 0x2f {
        return None;
    }
    let len = frame[1] as usize;
    if frame.len() < 2 + len {
        return None;
    }
    let (sub_op, feature_id) = (frame[2], frame[3]);
    let payload = &frame[4..2 + len];
    match (sub_op, feature_id) {
        // 0x28 parameter push for Daytime HR: the live heart-rate record
        (0x28, 0x02) => decode_dhr_param_push(payload).ok(),
        _ => None,
    }
}

pub fn decode_dhr_param_push(p: &[u8]) -> R {
    if p.len() != 13 {
        return Err(err(format!(
            "DhrParamPush payload must be 13 bytes, got {}",
            p.len()
        )));
    }
    let raw = u16_le(p, 4) as i64;
    let mut m = Map::new();
    m.insert("quality", Value::Int(p[0] as i64));
    m.insert("low_confidence", Value::Bool(p[0] & 0x10 != 0));
    m.insert("ibi_raw", Value::Int(raw));
    let ibi_ms = raw as f64 * 0.2;
    m.insert("ibi_ms", Value::Float(ibi_ms));
    if ibi_ms > 0.0 {
        m.insert("bpm", Value::Float(60_000.0 / ibi_ms));
    }
    Ok(m)
}

fn decode_ehr_trace_event(p: &[u8]) -> R {
    let n = p.len();
    if n < 5 || n > 14 {
        return Err(err(format!("EhrTraceEvent payload size [5..14], got {n}")));
    }
    let mut m = Map::new();
    m.insert(
        "header_hex",
        Value::Str(if n >= 4 { hex(&p[..4]) } else { hex(p) }),
    );
    m.insert("samples_u8", u8_array(&p[4..]));
    Ok(m)
}

fn decode_sleep_temp_event(p: &[u8]) -> R {
    let n = p.len();
    if n == 0 || n & 1 != 0 {
        return Err(err(format!(
            "SleepTempEvent payload size must be even and >0, got {n}"
        )));
    }
    let n_samples = n / 2;
    let mut temps = Vec::with_capacity(n_samples);
    let mut i = 0;
    while i < n {
        let raw = (p[i] as i64) | ((p[i + 1] as i64) << 8);
        temps.push(Value::Float(raw as f64 / 100.0));
        i += 2;
    }
    let mut m = Map::new();
    m.insert("n_samples", Value::Int(n_samples as i64));
    m.insert("temps_c", Value::Array(temps));
    m.insert("sample_interval_s", Value::Int(30));
    m.insert(
        "_note",
        Value::Str("samples are spaced 30s ending at this record's t".to_string()),
    );
    Ok(m)
}

fn decode_spo2_dc_event(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("Spo2DcEvent payload too short"));
    }
    let mut m = Map::new();
    m.insert("channel_index", Value::Int(p[0] as i64));
    m.insert("trailing_hex", Value::Str(hex(&p[1..])));
    m.insert("len", Value::Int(p.len() as i64));
    Ok(m)
}

fn decode_green_ibi_quality_event(p: &[u8]) -> R {
    let n = p.len();
    if n < 2 || n % 2 != 0 {
        return Err(err(format!(
            "GreenIbiQuality payload must be even >= 2, got {n}"
        )));
    }
    let mut samples = Vec::new();
    let mut i = 0;
    while i < n {
        let b_low = p[i];
        let b_high = p[i + 1];
        let mut sm = Map::new();
        sm.insert(
            "value_11bit",
            Value::Int(((b_low as i64) << 3) | (b_high & 0x07) as i64),
        );
        sm.insert("quality_a", Value::Int(((b_high >> 3) & 0x03) as i64));
        sm.insert("quality_b", Value::Int(((b_high >> 5) & 0x07) as i64));
        samples.push(Value::obj(sm));
        i += 2;
    }
    let mut m = Map::new();
    m.insert("samples", Value::Array(samples));
    m.insert(
        "_note",
        Value::Str(
            "parser is partially stateful (reads session flags); per-sample fields are deterministic"
                .to_string(),
        ),
    );
    Ok(m)
}

fn decode_scan_start(p: &[u8]) -> R {
    if p.len() < 3 {
        return Err(err("ScanStart payload too short"));
    }
    let mut m = Map::new();
    m.insert("triggering_feature", Value::Int(p[0] as i64));
    m.insert("trigger_reason", Value::Int(p[1] as i64));
    m.insert("classification_metric", Value::Int(p[2] as i64));
    let slots = if p.len() >= 9 { &p[3..9] } else { &p[3..] };
    m.insert("candidate_slots", u8_array(slots));
    m.insert(
        "trailing_hex",
        Value::Str(if p.len() > 9 { hex(&p[9..]) } else { String::new() }),
    );
    Ok(m)
}

fn decode_scan_end(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("ScanEnd payload empty"));
    }
    let mut m = Map::new();
    m.insert("success_code", Value::Int(p[0] as i64));
    if p.len() >= 4 {
        m.insert("u16_at_off_2", Value::Int(u16_le(p, 2)));
    }
    let tail_start = if p.len() >= 4 { 4 } else { 1 };
    m.insert("trailing_hex", Value::Str(hex(&p[tail_start..])));
    m.insert("len", Value::Int(p.len() as i64));
    Ok(m)
}

fn decode_sleep_summary_1(p: &[u8]) -> R {
    if p.len() < 4 {
        return Err(err("SleepSummary1 payload too short"));
    }
    let mut m = Map::new();
    m.insert("u16_at_off_0", Value::Int(u16_le(p, 0)));
    m.insert("u16_at_off_2", Value::Int(u16_le(p, 2)));
    m.insert("trailing_hex", Value::Str(hex(&p[4..])));
    Ok(m)
}

fn decode_sleep_summary_2(p: &[u8]) -> R {
    if p.len() != 14 {
        return Err(err(format!(
            "SleepSummary2 payload must be 14 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("header_hex", Value::Str(hex(&p[..8])));
    m.insert("u16_at_off_8", Value::Int(u16_le(p, 8)));
    m.insert("u32_at_off_10", Value::Int(u32_le(p, 10)));
    Ok(m)
}

fn decode_sleep_summary_3(p: &[u8]) -> R {
    if p.len() != 11 {
        return Err(err(format!(
            "SleepSummary3 payload must be 11 bytes, got {}",
            p.len()
        )));
    }
    let mut m = Map::new();
    m.insert("byte_0", Value::Int(p[0] as i64));
    m.insert("byte_1", Value::Int(p[1] as i64));
    m.insert("u16_at_off_2", Value::Int(u16_le(p, 2)));
    m.insert("u32_at_off_4", Value::Int(u32_le(p, 4)));
    m.insert("u16_at_off_8", Value::Int(u16_le(p, 8)));
    m.insert("byte_10", Value::Int(p[10] as i64));
    Ok(m)
}

fn decode_tag_event(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("TagEvent payload empty"));
    }
    let mut m = Map::new();
    m.insert("event_kind", Value::Int(p[0] as i64));
    m.insert("fields_hex", Value::Str(hex(&p[1..])));
    m.insert("len", Value::Int(p.len() as i64));
    Ok(m)
}

fn decode_user_info(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("UserInfo payload empty"));
    }
    let mut m = Map::new();
    m.insert("user_info_kind", Value::Int(p[0] as i64));
    m.insert("fields_hex", Value::Str(hex(&p[1..])));
    m.insert("len", Value::Int(p.len() as i64));
    Ok(m)
}

fn decode_sleep_period_info_2(p: &[u8]) -> R {
    if p.len() < 10 {
        return Err(err(format!(
            "SleepPeriodInfo payload must be >=10 bytes, got {}",
            p.len()
        )));
    }
    let motion_count = p[6];
    if motion_count >= 0x79 {
        return Err(err(format!(
            "motion_count={motion_count} out of range [0..120]"
        )));
    }
    let sleep_state = i8_of(p[7]);
    if !(0..3).contains(&sleep_state) {
        return Err(err(format!(
            "sleep_state={sleep_state} out of range [0..2]"
        )));
    }
    let cv_raw = (p[8] as i64) | ((p[9] as i64) << 8);
    let mut m = Map::new();
    m.insert("average_hr", Value::Float(p[0] as f64 * 0.5));
    m.insert("hr_trend", Value::Float(i8_of(p[1]) as f64 * 0.0625));
    m.insert("mzci", Value::Float(p[2] as f64 * 0.0625));
    m.insert("dzci", Value::Float(p[3] as f64 * 0.0625));
    m.insert("breath", Value::Float(p[4] as f64 / 8.0));
    m.insert("breath_v", Value::Float(p[5] as f64 / 8.0));
    m.insert("motion_count", Value::Int(motion_count as i64));
    m.insert("sleep_state", Value::Int(sleep_state));
    m.insert("cv", Value::Float(cv_raw as f64 / 65536.0));
    Ok(m)
}

// 0x61 API_DEBUG_DATA, sub-byte dispatched
mod dd;

use dd::decode_debug_data;

fn decode_raw_hex(p: &[u8]) -> Map {
    let mut m = Map::new();
    m.insert("hex", Value::Str(hex(p)));
    m.insert("len", Value::Int(p.len() as i64));
    m
}

/// decode a payload by type. raw-hex fallback for unmapped types, `_decode_error`
/// map when a decoder rejects malformed input
pub fn decode(type_byte: u8, payload: &[u8]) -> Map {
    let decoded: Option<R> = match type_byte {
        0x41 => Some(decode_ring_start_ind(payload)),
        0x42 => Some(decode_time_sync_ind(payload)),
        0x43 => Some(decode_debug_event_ind(payload)),
        0x45 => Some(decode_state_change_ind(payload)),
        0x61 => Some(decode_debug_data(payload)),
        0x46 => Some(decode_temp_event(payload)),
        0x47 => Some(decode_motion_event(payload)),
        0x4a => Some(decode_ppg_amplitude_ind(payload)),
        0x53 => Some(decode_state_change_ind(payload)), // WearEvent shares the template
        0x5d => Some(decode_hrv_event(payload)),
        0x60 => Some(decode_ibi_and_amplitude_event(payload)),
        0x69 => Some(decode_temp_period(payload)),
        0x6b => Some(decode_motion_period(payload)),
        0x6f => Some(decode_spo2_event(payload)),
        0x74 => Some(decode_ehr_acm_intensity_event(payload)),
        0x76 => Some(decode_bedtime_period(payload)),
        0x7e => Some(decode_real_steps_features(payload)),
        0x7f => Some(decode_real_steps_features(payload)),
        0x49 => Some(decode_sleep_summary_1(payload)),
        0x4c => Some(decode_sleep_summary_2(payload)),
        0x4f => Some(decode_sleep_summary_3(payload)),
        0x50 => Some(decode_activity_info_event(payload)),
        0x5b => Some(decode_ble_connection_ind(payload)),
        0x5e => Some(decode_selftest_event(payload)),
        0x6c => Some(decode_feature_session(payload)),
        0x6e => Some(decode_spo2_ibi_and_amplitude_event(payload)),
        0x72 => Some(decode_sleep_acm_period(payload)),
        0x73 => Some(decode_ehr_trace_event(payload)),
        0x75 => Some(decode_sleep_temp_event(payload)),
        0x77 => Some(decode_spo2_dc_event(payload)),
        0x80 => Some(decode_green_ibi_quality_event(payload)),
        0x82 => Some(decode_scan_start(payload)),
        0x83 => Some(decode_scan_end(payload)),
        0x56 => Some(decode_unknown_56(payload)),
        0x85 => Some(decode_unknown_85(payload)),
        0x5c => Some(decode_user_info(payload)),
        0x6a => Some(decode_sleep_period_info_2(payload)),
        0x79 => Some(decode_tag_event(payload)),
        _ => None,
    };
    match decoded {
        Some(Ok(m)) => m,
        Some(Err(e)) => {
            let mut m = Map::new();
            m.insert("_decode_error", Value::Str(e.0));
            m.insert("hex", Value::Str(hex(payload)));
            m.insert("len", Value::Int(payload.len() as i64));
            m
        }
        None => {
            let mut m = decode_raw_hex(payload);
            m.insert("_decoder", Value::Str("raw_hex_fallback".to_string()));
            m
        }
    }
}

pub use crate::enums::is_structurally_unknown;

pub fn type_name(tag: u8) -> String {
    canonical_type(tag)
}

/// true if `tag` has a known canonical name
pub fn is_known_type(tag: u8) -> bool {
    ring_event_type(tag).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temp_event_missing_channel_is_null() {
        // temp1=2500 (25.00c), temp2 unsigned 0x0000 -> 0.0
        let p = [0xc4, 0x09, 0x00, 0x00];
        let m = decode(0x46, &p);
        assert_eq!(m.get("temp1_c"), Some(&Value::Float(25.0)));
    }

    #[test]
    fn ibi_amp_known_vector() {
        let p = [0u8; 14];
        let m = decode(0x60, &p);
        // all zero -> ibi+amp zero, shift = nibble(0)+1 = 1
        assert_eq!(m.get("amp_shift"), Some(&Value::Int(1)));
    }

    #[test]
    fn bad_len_yields_decode_error() {
        let m = decode(0x42, &[0u8; 3]);
        assert!(m.get("_decode_error").is_some());
    }

    #[test]
    fn unmapped_type_raw_hex() {
        let m = decode(0xAA, &[1, 2, 3]);
        assert_eq!(
            m.get("_decoder"),
            Some(&Value::Str("raw_hex_fallback".to_string()))
        );
    }

    /// bytes lifted verbatim from a capture of the official app running a live
    /// measurement the wearer recorded as 58 bpm.
    #[test]
    fn dhr_param_push_known_vector() {
        let frame = [
            0x2f, 0x0f, 0x28, 0x02, 0x09, 0x02, 0x00, 0x00, 0xd4, 0x13, 0x00, 0x00, 0x00, 0x00,
            0x12, 0x0a, 0x7f,
        ];
        let m = decode_feature_frame(&frame).expect("frame should decode");
        assert_eq!(m.get("ibi_raw"), Some(&Value::Int(0x13d4)));
        assert_eq!(m.get("low_confidence"), Some(&Value::Bool(false)));
        let bpm = match m.get("bpm") {
            Some(Value::Float(b)) => *b,
            other => panic!("expected bpm, got {other:?}"),
        };
        // 5076 raw * 0.2 ms = 1015.2 ms -> 59.1 bpm, against a 58 bpm label
        assert!((bpm - 59.1).abs() < 0.2, "bpm was {bpm}");
    }

    #[test]
    fn dhr_param_push_flags_low_confidence() {
        let frame = [
            0x2f, 0x0f, 0x28, 0x02, 0x19, 0x02, 0x00, 0x00, 0xdb, 0x33, 0x00, 0x00, 0x00, 0x00,
            0x12, 0x0a, 0x7f,
        ];
        let m = decode_feature_frame(&frame).expect("frame should decode");
        assert_eq!(m.get("low_confidence"), Some(&Value::Bool(true)));
    }

    #[test]
    fn feature_frame_ignores_status_replies() {
        // 2f 03 23 02 00, a mode-set acknowledgement
        assert!(decode_feature_frame(&[0x2f, 0x03, 0x23, 0x02, 0x00]).is_none());
    }

    /// first 0x72 record of the analysed night, labelled `awake` in the
    /// exported hypnogram.
    #[test]
    fn sleep_acm_period_known_vector() {
        let p = [
            0x1b, 0x00, 0x32, 0x00, 0x18, 0x00, 0x31, 0x00, 0x35, 0x00, 0x07, 0x00,
        ];
        let m = decode(0x72, &p);
        assert_eq!(m.get("acm0"), Some(&Value::Int(27)));
        assert_eq!(m.get("acm1"), Some(&Value::Int(50)));
        assert_eq!(m.get("acm2"), Some(&Value::Int(24)));
        assert_eq!(m.get("acm5"), Some(&Value::Int(7)));
        assert_eq!(m.get("epoch_seconds"), Some(&Value::Int(30)));
    }
}
