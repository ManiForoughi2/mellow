//! C ABI surface for embedding `oura_core` into the Swift app.
//!
//! `cabi` feature. all string/byte returns are caller-owned, free with
//! [`oura_string_free`] / [`oura_bytes_free`]. core surface is "value bytes in
//! -> JSON string out" plus handshake proof and command builders

use crate::value::{Map, Value};
use crate::{app_records_json, commands, crypto, decode_inner_records, metrics};
use std::os::raw::{c_char, c_int};
use std::ptr;

/// heap byte buffer handed to C, free with [`oura_bytes_free`]
#[repr(C)]
pub struct OuraBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

fn vec_to_ourabytes(mut v: Vec<u8>) -> OuraBytes {
    v.shrink_to_fit();
    let len = v.len();
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    OuraBytes { ptr, len }
}

fn cstring(s: String) -> *mut c_char {
    match std::ffi::CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

unsafe fn slice<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

/// decode all inner records in one notify-char value to a JSON array string,
/// caller frees with [`oura_string_free`]
///
/// # Safety
/// `value`/`len` must describe a readable buffer (or be null/0)
#[no_mangle]
pub unsafe extern "C" fn oura_decode_inner_records_json(
    value: *const u8,
    len: usize,
) -> *mut c_char {
    let bytes = slice(value, len);
    let recs = decode_inner_records(bytes);
    let mut json = String::from("[");
    for (i, r) in recs.iter().enumerate() {
        if i > 0 {
            json.push(',');
        }
        json.push_str(&r.to_json());
    }
    json.push(']');
    cstring(json)
}

/// app-facing JSON array (framing + derived metrics + inspector `fields`),
/// entry point the mobile UI uses. caller frees with [`oura_string_free`]
///
/// # Safety
/// `value`/`len` must describe a readable buffer (or be null/0)
#[no_mangle]
pub unsafe extern "C" fn oura_app_records_json(value: *const u8, len: usize) -> *mut c_char {
    let bytes = slice(value, len);
    cstring(app_records_json(bytes))
}

/// 16-byte handshake proof. `auth_key` 16 bytes, `nonce` 15 bytes. on success
/// returns 0 and writes 16 bytes into `out` (>=16); non-zero on bad lengths
///
/// # Safety
/// all pointers must reference readable/writable buffers of the stated sizes
#[no_mangle]
pub unsafe extern "C" fn oura_handshake_proof(
    auth_key: *const u8,
    auth_key_len: usize,
    nonce: *const u8,
    nonce_len: usize,
    out: *mut u8,
) -> c_int {
    let ak = slice(auth_key, auth_key_len);
    let nc = slice(nonce, nonce_len);
    match crypto::compute_handshake_proof(ak, nc) {
        Ok(proof) => {
            if !out.is_null() {
                ptr::copy_nonoverlapping(proof.as_ptr(), out, 16);
            }
            0
        }
        Err(_) => 1,
    }
}

/// extract 16-byte `auth_key` from raw `assa-store.realm` bytes. 0 + writes 16
/// bytes to `out` on success; 1 if not found, 2 if ambiguous
///
/// # Safety
/// `data`/`len` must describe a readable buffer; `out` >=16 writable bytes
#[no_mangle]
pub unsafe extern "C" fn oura_extract_auth_key(
    data: *const u8,
    len: usize,
    out: *mut u8,
) -> c_int {
    let blob = slice(data, len);
    match crypto::extract_auth_key_from_realm(blob) {
        Ok(key) => {
            if !out.is_null() {
                ptr::copy_nonoverlapping(key.as_ptr(), out, 16);
            }
            0
        }
        Err(crypto::CryptoError::MultipleCandidates(_)) => 2,
        Err(_) => 1,
    }
}

/// canonical `StateChange` name for a state byte, null if not a known state.
/// caller frees the non-null result with [`oura_string_free`]
#[no_mangle]
pub extern "C" fn oura_state_change_name(state: u8) -> *mut c_char {
    match crate::enums::state_change(state) {
        Some(name) => cstring(name.to_string()),
        None => ptr::null_mut(),
    }
}

/// canonical `API_*` type name for a tag, falls back to "UNKNOWN_0xNN", always
/// non-null. caller frees with [`oura_string_free`]
#[no_mangle]
pub extern "C" fn oura_type_name(tag: u8) -> *mut c_char {
    cstring(crate::enums::canonical_type(tag))
}

/// handshake-start frame `2F 01 2B`, free with [`oura_bytes_free`]
#[no_mangle]
pub extern "C" fn oura_cmd_handshake_start() -> OuraBytes {
    vec_to_ourabytes(commands::handshake_start().to_vec())
}

/// proof frame `2F 11 2D <proof:16>` from auth_key + nonce, empty buffer on bad
/// lengths. free with [`oura_bytes_free`]
///
/// # Safety
/// pointers must reference readable buffers of the stated sizes
#[no_mangle]
pub unsafe extern "C" fn oura_cmd_handshake_proof_frame(
    auth_key: *const u8,
    auth_key_len: usize,
    nonce: *const u8,
    nonce_len: usize,
) -> OuraBytes {
    let ak = slice(auth_key, auth_key_len);
    let nc = slice(nonce, nonce_len);
    match commands::handshake_proof_frame(ak, nc) {
        Ok(f) => vec_to_ourabytes(f),
        Err(_) => vec_to_ourabytes(Vec::new()),
    }
}

/// time-sync frame, free with [`oura_bytes_free`]
#[no_mangle]
pub extern "C" fn oura_cmd_time_sync(token: u8, unix_time_s: u64) -> OuraBytes {
    vec_to_ourabytes(commands::time_sync_frame(token, unix_time_s).to_vec())
}

/// `GetEvent` frame from `ring_timestamp` (255 events, all flags), free with
/// [`oura_bytes_free`]
#[no_mangle]
pub extern "C" fn oura_cmd_request_events_since(ring_timestamp: u32) -> OuraBytes {
    vec_to_ourabytes(commands::request_events_since_default(ring_timestamp).to_vec())
}

/// on-demand HR burst frames concatenated (read + two writes), free with
/// [`oura_bytes_free`]
#[no_mangle]
pub extern "C" fn oura_cmd_request_hr_on_demand() -> OuraBytes {
    let mut out = Vec::new();
    for f in commands::request_hr_on_demand() {
        out.extend_from_slice(&f);
    }
    vec_to_ourabytes(out)
}

/// single-anchor linear ring_time->UTC interpolation. 0 + writes unix-ms to
/// `out_utc_ms` when anchor valid; 1 (no write) when `anchor_ring_time == 0 ||
/// anchor_utc_ms == 0`. factor = 100 ms/tick (flag 0) or 1 ms/tick (flag 1),
/// backward underflow clamps to 0
///
/// # Safety
/// `out_utc_ms` must be a writable `u64` pointer
#[no_mangle]
pub unsafe extern "C" fn oura_time_to_utc_ms(
    anchor_ring_time: u64,
    anchor_utc_ms: u64,
    factor_flag: u8,
    target_rt: u32,
    out_utc_ms: *mut u64,
) -> c_int {
    if anchor_ring_time == 0 || anchor_utc_ms == 0 {
        return 1;
    }
    let factor: u64 = if factor_flag == 0 { 100 } else { 1 };
    let rt = target_rt as u64;
    let result = if rt >= anchor_ring_time {
        anchor_utc_ms + factor * (rt - anchor_ring_time)
    } else {
        let sub = factor * (anchor_ring_time - rt);
        if anchor_utc_ms < sub {
            0
        } else {
            anchor_utc_ms - sub
        }
    };
    if !out_utc_ms.is_null() {
        *out_utc_ms = result;
    }
    0
}

/// time anchor from a fresh 0x42 TIME_SYNC_IND. validates candidate UTC
/// (`ring_unix_approx_s * 1000`) within ±48h of `now_ms`. 0 + writes
/// `(out_ring_time, out_utc_ms, out_factor_flag)` when accepted; 1 (no write)
/// when too far from now. factor_flag = 1 when `token == 0xfd` (burst) else 0
///
/// # Safety
/// the three out-pointers must be writable
#[no_mangle]
pub unsafe extern "C" fn oura_anchor_from_time_sync(
    ring_time: u32,
    ring_unix_approx_s: i64,
    token: u8,
    now_ms: u64,
    out_ring_time: *mut u64,
    out_utc_ms: *mut u64,
    out_factor_flag: *mut u8,
) -> c_int {
    const WINDOW_MS: u64 = 48 * 3600 * 1000;
    let candidate_utc = (ring_unix_approx_s as u64).wrapping_mul(1000);
    let delta = if candidate_utc > now_ms {
        candidate_utc - now_ms
    } else {
        now_ms - candidate_utc
    };
    if delta > WINDOW_MS {
        return 1;
    }
    if !out_ring_time.is_null() {
        *out_ring_time = ring_time as u64;
    }
    if !out_utc_ms.is_null() {
        *out_utc_ms = candidate_utc;
    }
    if !out_factor_flag.is_null() {
        *out_factor_flag = if token == 0xfd { 1 } else { 0 };
    }
    0
}

/// minimal embedded JSON reader for the app's small request objects, avoids a
/// serde dep. flat objects of numbers / number-arrays / null only
mod minijson {
    /// parsed JSON value, limited to what the metrics requests need
    pub enum J {
        Null,
        Num(f64),
        Arr(Vec<f64>),
        Bool(bool),
    }

    pub struct Obj(pub Vec<(String, J)>);

    impl Obj {
        pub fn num(&self, key: &str) -> Option<f64> {
            self.0.iter().find(|(k, _)| k == key).and_then(|(_, v)| match v {
                J::Num(n) => Some(*n),
                _ => None,
            })
        }
        pub fn arr(&self, key: &str) -> Vec<f64> {
            self.0
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| match v {
                    J::Arr(a) => a.clone(),
                    _ => Vec::new(),
                })
                .unwrap_or_default()
        }
    }

    struct P<'a> {
        b: &'a [u8],
        i: usize,
    }

    impl<'a> P<'a> {
        fn ws(&mut self) {
            while self.i < self.b.len() && (self.b[self.i] as char).is_whitespace() {
                self.i += 1;
            }
        }
        fn num(&mut self) -> Option<f64> {
            let start = self.i;
            while self.i < self.b.len() {
                let c = self.b[self.i] as char;
                if c.is_ascii_digit() || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' {
                    self.i += 1;
                } else {
                    break;
                }
            }
            std::str::from_utf8(&self.b[start..self.i]).ok()?.parse().ok()
        }
        fn string(&mut self) -> Option<String> {
            if self.b.get(self.i) != Some(&b'"') {
                return None;
            }
            self.i += 1;
            let start = self.i;
            while self.i < self.b.len() && self.b[self.i] != b'"' {
                self.i += 1;
            }
            let s = std::str::from_utf8(&self.b[start..self.i]).ok()?.to_string();
            self.i += 1;
            Some(s)
        }
        fn value(&mut self) -> Option<J> {
            self.ws();
            match self.b.get(self.i) {
                Some(b'[') => {
                    self.i += 1;
                    let mut out = Vec::new();
                    loop {
                        self.ws();
                        if self.b.get(self.i) == Some(&b']') {
                            self.i += 1;
                            break;
                        }
                        out.push(self.num()?);
                        self.ws();
                        if self.b.get(self.i) == Some(&b',') {
                            self.i += 1;
                        }
                    }
                    Some(J::Arr(out))
                }
                Some(b'n') => {
                    self.i += 4; // "null"
                    Some(J::Null)
                }
                Some(b't') => {
                    self.i += 4;
                    Some(J::Bool(true))
                }
                Some(b'f') => {
                    self.i += 5;
                    Some(J::Bool(false))
                }
                _ => self.num().map(J::Num),
            }
        }
    }

    /// parse a flat JSON object, empty object on malformed input
    pub fn parse_obj(s: &str) -> Obj {
        let mut p = P { b: s.as_bytes(), i: 0 };
        let mut out = Vec::new();
        p.ws();
        if p.b.get(p.i) != Some(&b'{') {
            return Obj(out);
        }
        p.i += 1;
        loop {
            p.ws();
            if p.b.get(p.i) == Some(&b'}') || p.i >= p.b.len() {
                break;
            }
            let key = match p.string() {
                Some(k) => k,
                None => break,
            };
            p.ws();
            if p.b.get(p.i) == Some(&b':') {
                p.i += 1;
            }
            let val = match p.value() {
                Some(v) => v,
                None => break,
            };
            out.push((key, val));
            p.ws();
            if p.b.get(p.i) == Some(&b',') {
                p.i += 1;
            }
        }
        Obj(out)
    }
}

unsafe fn cstr_in<'a>(s: *const c_char) -> &'a str {
    if s.is_null() {
        return "";
    }
    std::ffi::CStr::from_ptr(s).to_str().unwrap_or("")
}

fn opt_num(m: &mut Map, key: &str, v: Option<f64>) {
    match v {
        Some(x) => {
            m.insert(key, Value::Float(x));
        }
        None => {
            m.insert(key, Value::Null);
        }
    }
}

/// Tanaka age-predicted max HR (208 - 0.7*age)
#[no_mangle]
pub extern "C" fn oura_hr_max_tanaka(age_years: f64) -> f64 {
    metrics::hr_max_tanaka(age_years)
}

/// non-exercise VO2max estimate 15*HRmax/HRrest, 0.0 on bad input
#[no_mangle]
pub extern "C" fn oura_vo2max_hr_ratio(hr_max: f64, hr_rest: f64) -> f64 {
    metrics::vo2max_hr_ratio(hr_max, hr_rest).unwrap_or(0.0)
}

/// resting HR (low percentile of nightly HR). request JSON
/// `{"hr":[..bpm..],"percentile":0.05}`, returns bpm or 0.0
///
/// # Safety
/// `req_json` must be a valid C string or null
#[no_mangle]
pub unsafe extern "C" fn oura_resting_hr(req_json: *const c_char) -> f64 {
    let obj = minijson::parse_obj(cstr_in(req_json));
    let hr = obj.arr("hr");
    let p = obj.num("percentile").unwrap_or(0.05);
    metrics::resting_hr(&hr, p).unwrap_or(0.0)
}

/// day strain (0-21) from HR-over-time. request JSON
/// `{"bpm":[..],"minutes":[..],"hr_max":190,"hr_rest":55}`, `bpm[i]` lasts
/// `minutes[i]`, returns 0-21 strain
///
/// # Safety
/// `req_json` must be a valid C string or null
#[no_mangle]
pub unsafe extern "C" fn oura_strain(req_json: *const c_char) -> f64 {
    let obj = minijson::parse_obj(cstr_in(req_json));
    let bpm = obj.arr("bpm");
    let mins = obj.arr("minutes");
    let hr_max = obj.num("hr_max").unwrap_or(190.0);
    let hr_rest = obj.num("hr_rest").unwrap_or(60.0);
    let samples: Vec<metrics::HrSample> = bpm
        .iter()
        .enumerate()
        .map(|(i, &b)| metrics::HrSample {
            bpm: b,
            minutes: *mins.get(i).unwrap_or(&1.0),
        })
        .collect();
    metrics::strain(&samples, hr_max, hr_rest)
}

/// recovery (0-100) + sub-scores as a JSON object. request JSON
/// ```json
/// {"rmssd":48,"resting_hr":54,"respiratory_rate":15,"sleep_performance":88,
///  "baseline_rmssd":[..nightly..],"baseline_resting_hr":55,
///  "baseline_respiratory_rate":15}
/// ```
/// any field omittable/null. response
/// `{"score":..,"hrv_score":..|null,"resting_hr_score":..|null,
///   "respiratory_rate_score":..|null,"sleep_score":..|null}`.
/// caller frees with [`oura_string_free`]
///
/// # Safety
/// `req_json` must be a valid C string or null
#[no_mangle]
pub unsafe extern "C" fn oura_recovery_json(req_json: *const c_char) -> *mut c_char {
    let obj = minijson::parse_obj(cstr_in(req_json));
    let baseline = metrics::hrv_baseline(&obj.arr("baseline_rmssd")).unwrap_or(
        // no nightly history yet: anchor on tonight's value or a neutral 40ms
        metrics::HrvBaseline {
            mean_ln: obj.num("rmssd").unwrap_or(40.0).max(1.0).ln(),
            sd_ln: 0.0,
            cv_pct: 0.0,
            n: 0,
        },
    );
    let baselines = metrics::RecoveryBaselines {
        hrv: baseline,
        resting_hr_mean: obj.num("baseline_resting_hr"),
        respiratory_rate_mean: obj.num("baseline_respiratory_rate"),
    };
    let inputs = metrics::RecoveryInputs {
        rmssd_ms: obj.num("rmssd"),
        resting_hr: obj.num("resting_hr"),
        respiratory_rate: obj.num("respiratory_rate"),
        sleep_performance: obj.num("sleep_performance"),
    };
    let r = metrics::recovery(&inputs, &baselines, &metrics::RecoveryWeights::default());
    let mut m = Map::new();
    m.insert("score", Value::Float(r.score));
    opt_num(&mut m, "hrv_score", r.hrv_score);
    opt_num(&mut m, "resting_hr_score", r.resting_hr_score);
    opt_num(&mut m, "respiratory_rate_score", r.respiratory_rate_score);
    opt_num(&mut m, "sleep_score", r.sleep_score);
    cstring(Value::Object(m).to_json())
}

/// sleep score (0-100) + sub-scores as JSON. request JSON (minutes for
/// durations, any field omittable)
/// ```json
/// {"total_sleep_min":450,"time_in_bed_min":480,"rem_min":100,"deep_min":80,
///  "latency_min":15,"awakenings":1,"midpoint_hour":2.0}
/// ```
/// response `{"score":..,"duration":..|null,"efficiency":..|null,"rem":..|null,
/// "deep":..|null,"latency":..|null,"restfulness":..|null,"timing":..|null}`.
/// caller frees with [`oura_string_free`]
///
/// # Safety
/// `req_json` must be a valid C string or null
#[no_mangle]
pub unsafe extern "C" fn oura_sleep_score_json(req_json: *const c_char) -> *mut c_char {
    let obj = minijson::parse_obj(cstr_in(req_json));
    let inp = metrics::SleepInputs {
        total_sleep_min: obj.num("total_sleep_min"),
        time_in_bed_min: obj.num("time_in_bed_min"),
        rem_min: obj.num("rem_min"),
        deep_min: obj.num("deep_min"),
        latency_min: obj.num("latency_min"),
        awakenings: obj.num("awakenings").map(|a| a as u32),
        midpoint_hour: obj.num("midpoint_hour"),
    };
    let s = metrics::sleep_score(&inp);
    let mut m = Map::new();
    m.insert("score", Value::Float(s.score));
    opt_num(&mut m, "duration", s.duration);
    opt_num(&mut m, "efficiency", s.efficiency);
    opt_num(&mut m, "rem", s.rem);
    opt_num(&mut m, "deep", s.deep);
    opt_num(&mut m, "latency", s.latency);
    opt_num(&mut m, "restfulness", s.restfulness);
    opt_num(&mut m, "timing", s.timing);
    cstring(Value::Object(m).to_json())
}

/// RMSSD (ms) from JSON IBI list `{"ibi":[..ms..]}`, 0.0 for <2 intervals
///
/// # Safety
/// `req_json` must be a valid C string or null
#[no_mangle]
pub unsafe extern "C" fn oura_rmssd(req_json: *const c_char) -> f64 {
    let obj = minijson::parse_obj(cstr_in(req_json));
    metrics::rmssd(&obj.arr("ibi")).unwrap_or(0.0)
}

/// free a string returned by this module
///
/// # Safety
/// `s` must be a pointer previously returned by an `oura_*` function, or null
#[no_mangle]
pub unsafe extern "C" fn oura_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(std::ffi::CString::from_raw(s));
    }
}

/// free an [`OuraBytes`] buffer returned by this module
///
/// # Safety
/// `b` must have been produced by an `oura_*` function in this module
#[no_mangle]
pub unsafe extern "C" fn oura_bytes_free(b: OuraBytes) {
    if !b.ptr.is_null() && b.len > 0 {
        drop(Vec::from_raw_parts(b.ptr, b.len, b.len));
    }
}
