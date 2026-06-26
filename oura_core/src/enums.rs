//! Canonical enum names for the Oura Ring 4 wire protocol.
//!
//! names emitted in decoded `type` / `state_name`, from the official firmware
//! ring-event parser

/// 1-byte type tag -> canonical `API_*` name, None if not in the known enum
pub fn ring_event_type(tag: u8) -> Option<&'static str> {
    Some(match tag {
        0x33 => "(not_in_enum_33)",
        0x41 => "API_RING_START_IND",
        0x42 => "API_TIME_SYNC_IND",
        0x43 => "API_DEBUG_EVENT_IND",
        0x44 => "API_IBI_EVENT",
        0x45 => "API_STATE_CHANGE_IND",
        0x46 => "API_TEMP_EVENT",
        0x47 => "API_MOTION_EVENT",
        0x48 => "API_SLEEP_PERIOD_INFO",
        0x49 => "API_SLEEP_SUMMARY_1",
        0x4a => "API_PPG_AMPLITUDE_IND",
        0x4b => "API_SLEEP_PHASE_INFO",
        0x4c => "API_SLEEP_SUMMARY_2",
        0x4d => "API_RING_SLEEP_FEATURE_INFO",
        0x4e => "API_SLEEP_PHASE_DETAILS",
        0x4f => "API_SLEEP_SUMMARY_3",
        0x50 => "API_ACTIVITY_INFO",
        0x51 => "API_ACTIVITY_SUMMARY_1",
        0x52 => "API_ACTIVITY_SUMMARY_2",
        0x53 => "API_WEAR_EVENT",
        0x54 => "API_RECOVERY_SUMMARY",
        0x56 => "(not_in_enum_56)",
        0x5b => "API_BLE_CONNECTION_IND",
        0x5c => "API_USER_INFO",
        0x5d => "API_HRV_EVENT",
        0x5e => "API_SELFTEST_EVENT",
        0x60 => "API_IBI_AND_AMPLITUDE_EVENT",
        0x61 => "API_DEBUG_DATA",
        0x67 => "API_RING_HW_TIME_INFO",
        0x68 => "API_RAW_PPG_DATA",
        0x69 => "API_TEMP_PERIOD",
        0x6a => "API_SLEEP_PERIOD_INFO_2",
        0x6b => "API_MOTION_PERIOD",
        0x6c => "API_FEATURE_SESSION",
        0x6e => "API_SPO2_IBI_AND_AMPLITUDE_EVENT",
        0x6f => "API_SPO2_EVENT",
        0x72 => "API_SLEEP_ACM_PERIOD",
        0x73 => "API_EHR_TRACE_EVENT",
        0x74 => "API_EHR_ACM_INTENSITY_EVENT",
        0x75 => "API_SLEEP_TEMP_EVENT",
        0x76 => "API_BEDTIME_PERIOD",
        0x77 => "API_SPO2_DC_EVENT",
        0x79 => "API_TAG_EVENT",
        0x7e => "API_REAL_STEP_EVENT_FEATURE_ONE",
        0x7f => "API_REAL_STEP_EVENT_FEATURE_TWO",
        0x80 => "API_GREEN_IBI_QUALITY_EVENT",
        0x81 => "API_CVA_RAW_PPG_DATA",
        0x82 => "API_SCAN_START",
        0x83 => "API_SCAN_END",
        0x85 => "API_RTC_BEACON_IND",
        _ => return None,
    })
}

/// canonical type name for a tag, falls back to `UNKNOWN_0xNN`
pub fn canonical_type(tag: u8) -> String {
    match ring_event_type(tag) {
        Some(name) => name.to_string(),
        None => format!("UNKNOWN_0x{tag:02x}"),
    }
}

/// `StateChange` enum, shared by `StateChangeInd` (0x45) and `WearEvent` (0x53)
pub fn state_change(v: u8) -> Option<&'static str> {
    Some(match v {
        0 => "STATE_UNSPECIFIED",
        1 => "STATE_NOT_IN_FINGER",
        2 => "STATE_FINGER_DETECTION",
        3 => "STATE_FINGER_USER_ACTIVE",
        4 => "STATE_FINGER_USER_IN_REST",
        5 => "STATE_FINGER_HR_USER_ACTIVE",
        6 => "STATE_FINGER_HR_USER_IN_REST",
        7 => "STATE_OUT_OF_POWER",
        8 => "STATE_CHARGING_PHASE",
        9 => "STATE_RING_HIBERNATE_LOW_POWER",
        20 => "STATE_PRODUCTION_DIAGNOSTIC",
        21 => "STATE_PRODUCTION_TESTING",
        22 => "STATE_PRODUCTION_TESTING_CHARGING",
        30 => "STATE_HW_TEST",
        _ => return None,
    })
}

/// `MotionState` enum, used by `MotionPeriod` (0x6b)
pub fn motion_state(v: u8) -> Option<&'static str> {
    Some(match v {
        0 => "NO_MOTION",
        1 => "RESTLESS",
        2 => "TOSSING_AND_TURNING",
        3 => "ACTIVE",
        _ => return None,
    })
}

/// true if `tag` is not a trusted well-framed inner record, suppresses cursor
/// advance + time-anchor interpolation for misparse fragments and unknown tags
pub fn is_structurally_unknown(tag: u8) -> bool {
    let name = canonical_type(tag);
    name.starts_with("(not_in_enum_") || name.starts_with("UNKNOWN_")
}
