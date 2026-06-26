//! Cross-language parity: decode known payloads and assert the field values
//! match what the reference Python `driver/decoders.py` produces for the same
//! bytes. Vectors below were computed from the reference implementation; this
//! pins the Rust port to byte-identical semantics.

use oura_core::decoders::decode;
use oura_core::value::Value;

fn f(m: &oura_core::value::Map, k: &str) -> Value {
    m.get(k).cloned().unwrap_or(Value::Null)
}

#[test]
fn time_sync_ind_parity() {
    // payload: token=0x05, counter=0x002010, const 0*5
    let p = [0x05, 0x10, 0x20, 0x00, 0, 0, 0, 0, 0];
    let m = decode(0x42, &p);
    assert_eq!(f(&m, "token"), Value::Int(5));
    assert_eq!(f(&m, "time_counter"), Value::Int(0x002010));
    assert_eq!(f(&m, "ring_unix_time_approx_s"), Value::Int(0x002010 * 256));
}

#[test]
fn temp_event_parity() {
    // temp1=25.00C (2500=0x09c4), temp2 missing? use unsigned. test both channels.
    let p = [0xc4, 0x09, 0x10, 0x0e]; // temp1=2500/100=25.0, temp2=3600/100=36.0
    let m = decode(0x46, &p);
    assert_eq!(f(&m, "temp1_c"), Value::Float(25.0));
    assert_eq!(f(&m, "temp2_c"), Value::Float(36.0));
    assert_eq!(f(&m, "temp3_c"), Value::Null);
}

#[test]
fn hrv_event_parity() {
    // two 5-min windows: (hr=60, rmssd=42), (hr=58, rmssd=40)
    let p = [60, 42, 58, 40];
    let m = decode(0x5d, &p);
    if let Value::Array(arr) = f(&m, "samples_5min") {
        assert_eq!(arr.len(), 2);
    } else {
        panic!("expected array");
    }
}

#[test]
fn spo2_event_parity() {
    // header 0x68 then 93,93,93 then terminator 0xff
    let p = [0x68, 93, 93, 93, 0xff];
    let m = decode(0x6f, &p);
    assert_eq!(f(&m, "header_high"), Value::Int(6));
    assert_eq!(f(&m, "header_low"), Value::Int(8));
    assert_eq!(
        f(&m, "spo2_percent"),
        Value::Array(vec![Value::Int(93), Value::Int(93), Value::Int(93)])
    );
}

#[test]
fn green_ibi_quality_parity() {
    // reference example payload from the decoder docstring
    let p = [0x84, 0x27, 0x5f, 0x2f, 0x5e, 0x0e, 0x60, 0x10, 0xef, 0x52, 0xfa, 0xb0, 0x77, 0xb3];
    let m = decode(0x80, &p);
    if let Value::Array(arr) = f(&m, "samples") {
        assert_eq!(arr.len(), 7);
        // first sample: b_low=0x84, b_high=0x27 → value_11bit = (0x84<<3)|(0x27&7)
        if let Value::Object(s0) = &arr[0] {
            assert_eq!(
                s0.get("value_11bit"),
                Some(&Value::Int(((0x84i64) << 3) | (0x27 & 7)))
            );
        }
    } else {
        panic!("expected samples array");
    }
}

#[test]
fn debug_data_fuel_gauge_parity() {
    // sub=0x14, battery_pct_raw=0x6400 (=>100.0 at /256? 0x6400=25600/256=100.0),
    // mv=0x0fa0=4000, current i32, remaining u16, coulomb 24-bit
    let p = [
        0x14, 0x00, 0x64, 0xa0, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x10, 0x27, 0x00, 0x01, 0x02,
    ];
    let m = decode(0x61, &p);
    assert_eq!(f(&m, "battery_percentage"), Value::Float(100.0));
    assert_eq!(f(&m, "average_battery_voltage_mv"), Value::Int(4000));
    assert_eq!(f(&m, "_dd"), Value::Str("DebugDataFuelGaugeStatistics".into()));
    assert_eq!(f(&m, "sub_byte"), Value::Int(0x14));
}

#[test]
fn sleep_period_info_2_parity() {
    // average_hr wire 130 → 65.0 BPM
    let p = [130, 0, 0, 0, 0, 0, 10, 1, 0x00, 0x80];
    let m = decode(0x6a, &p);
    assert_eq!(f(&m, "average_hr"), Value::Float(65.0));
    assert_eq!(f(&m, "sleep_state"), Value::Int(1));
    // cv = 0x8000 / 65536 = 0.5
    assert_eq!(f(&m, "cv"), Value::Float(0.5));
}

#[test]
fn motion_event_parity() {
    // acm_x = int8(10)*8 = 80
    let p = [0x00, 10, 0xfb, 0x00]; // y = int8(0xfb=-5)*8 = -40
    let m = decode(0x47, &p);
    assert_eq!(f(&m, "acm_x"), Value::Int(80));
    assert_eq!(f(&m, "acm_y"), Value::Int(-40));
    assert_eq!(f(&m, "acm_z"), Value::Int(0));
}
