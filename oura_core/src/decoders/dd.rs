//! `0x61 API_DEBUG_DATA` sub-byte dispatched decoders.
//!
//! first payload byte selects one of ~46 sub-types, table covers ~96% of 0x61
//! records. firmware default-throw sub-bytes get a `lib_no_parser` marker to
//! tell "firmware errors here" apart from "decoder not written yet"

use super::{DecodeError, R};
use crate::value::{hex, i32_le, u16_le, u32_le, Value, Map};

fn err(s: impl Into<String>) -> DecodeError {
    DecodeError(s.into())
}

fn ascii_replace(b: &[u8]) -> String {
    b.iter()
        .map(|&c| if c < 0x80 { c as char } else { '\u{FFFD}' })
        .collect()
}

fn dd(label: &str) -> Map {
    let mut m = Map::new();
    m.insert("_dd", Value::Str(label.to_string()));
    m
}

fn dd_sleep_statistics(p: &[u8]) -> R {
    if p.len() < 14 {
        return Err(err(format!(
            "sleep_statistics payload must be >=14 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataSleepStatistics");
    m.insert("ticks_in_deep_sleep", Value::Int(u32_le(p, 1)));
    m.insert("ticks_in_sleep", Value::Int(u32_le(p, 5)));
    m.insert("ticks_awake", Value::Int(u32_le(p, 9)));
    m.insert("pfsm_state", Value::Int(p[13] as i64));
    Ok(m)
}

fn dd_flash_usage_statistics(p: &[u8]) -> R {
    if p.len() < 13 {
        return Err(err(format!(
            "flash_usage payload must be >=13 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataFlashUsageStatistics");
    m.insert("ticks_reading_flash", Value::Int(u32_le(p, 1)));
    m.insert("ticks_writing_flash", Value::Int(u32_le(p, 5)));
    m.insert("ticks_erasing_flash", Value::Int(u32_le(p, 9)));
    Ok(m)
}

fn dd_period_info_statistics(p: &[u8]) -> R {
    if p.len() < 10 {
        return Err(err(format!(
            "period_info payload must be >=10 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataPeriodInfoStatistics");
    m.insert("ticks_measuring_last_period", Value::Int(u32_le(p, 1)));
    m.insert(
        "systime_spent_in_last_state_s",
        Value::Float(u32_le(p, 5) as f64 / 10.0),
    );
    m.insert("pfsm_state", Value::Int(p[9] as i64));
    Ok(m)
}

fn dd_ble_usage_statistics(p: &[u8]) -> R {
    if p.len() < 13 {
        return Err(err(format!(
            "ble_usage payload must be >=13 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataBleUsageStatistics");
    m.insert("ticks_fast_mode", Value::Int(u32_le(p, 1)));
    m.insert("ticks_slow_mode", Value::Int(u32_le(p, 5)));
    m.insert("ticks_advertising_mode", Value::Int(u32_le(p, 9)));
    Ok(m)
}

fn dd_fuel_gauge_statistics(p: &[u8]) -> R {
    if p.len() < 14 {
        return Err(err(format!(
            "fuel_gauge payload must be >=14 bytes, got {}",
            p.len()
        )));
    }
    let cc = ((crate::value::i8_of(p[11])) << 16) | ((p[12] as i64) << 8) | p[13] as i64;
    let mut m = dd("DebugDataFuelGaugeStatistics");
    m.insert(
        "battery_percentage",
        Value::Float(u16_le(p, 1) as f64 / 256.0),
    );
    m.insert("average_battery_voltage_mv", Value::Int(u16_le(p, 3)));
    m.insert("average_current_consumption", Value::Int(i32_le(p, 5)));
    m.insert("remaining_capacity", Value::Int(u16_le(p, 9)));
    m.insert("coulomb_counter", Value::Int(cc));
    Ok(m)
}

fn dd_event_sync_statistics(p: &[u8]) -> R {
    if p.len() < 12 {
        return Err(err(format!(
            "event_sync payload must be >=12 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataEventSyncStatistics");
    m.insert("connection_interval", Value::Int(u16_le(p, 1)));
    m.insert("synced_bytes_count", Value::Int(u32_le(p, 3)));
    m.insert("sync_duration_in_ms", Value::Int(u32_le(p, 7)));
    m.insert("mtu", Value::Int(p[11] as i64));
    Ok(m)
}

fn dd_event_sync_cache_statistics(p: &[u8]) -> R {
    if p.len() < 13 {
        return Err(err(format!(
            "event_sync_cache payload must be >=13 bytes, got {}",
            p.len()
        )));
    }
    let u24 = |lo: usize, hi: usize| u16_le(p, lo) | ((p[hi] as i64) << 16);
    let mut m = dd("DebugDataEventSyncCacheStatistics");
    m.insert("header_read_count_from_cache", Value::Int(u24(1, 3)));
    m.insert("header_read_count_from_flash", Value::Int(u24(4, 6)));
    m.insert("event_read_count_from_cache", Value::Int(u24(7, 9)));
    m.insert("event_read_count_from_flash", Value::Int(u24(10, 12)));
    Ok(m)
}

fn dd_acm_configuration_changed(p: &[u8]) -> R {
    if p.len() < 8 {
        return Err(err(format!(
            "acm_config payload must be >=8 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataAcmConfigurationChanged");
    m.insert("accelerometer_mode", Value::Int(p[1] as i64));
    m.insert("accelerometer_odr", Value::Int(p[2] as i64));
    m.insert("accelerometer_range", Value::Int(p[3] as i64));
    m.insert("gyroscope_odr", Value::Int(p[4] as i64));
    m.insert("gyroscope_range", Value::Int(p[5] as i64));
    m.insert("event_mask_and_fifo_u16", Value::Int(u16_le(p, 6)));
    Ok(m)
}

/// LSB-first within each byte, MSB-first across the stream
struct BitStream<'a> {
    buf: &'a [u8],
    byte_off: usize,
    bit_off: u32,
}

impl<'a> BitStream<'a> {
    fn new(buf: &'a [u8], start_off: usize) -> Self {
        BitStream {
            buf,
            byte_off: start_off,
            bit_off: 0,
        }
    }

    fn read(&mut self, nbits: u32) -> Result<i64, DecodeError> {
        if nbits > 32 {
            return Err(err(format!("nbits {nbits} out of range")));
        }
        let mut out: i64 = 0;
        let mut consumed = 0u32;
        while consumed < nbits {
            if self.byte_off >= self.buf.len() {
                return Err(err("bit-stream underflow"));
            }
            let byte = self.buf[self.byte_off];
            let avail = 8 - self.bit_off;
            let take = (nbits - consumed).min(avail);
            let mask = (1u32 << take) - 1;
            let val = ((byte as u32) >> self.bit_off) & mask;
            out = (out << take) | val as i64;
            self.bit_off += take;
            if self.bit_off == 8 {
                self.bit_off = 0;
                self.byte_off += 1;
            }
            consumed += take;
        }
        Ok(out)
    }
}

fn dd_ppg_signal_quality_stats(p: &[u8]) -> R {
    if p.len() < 5 {
        return Err(err(format!(
            "ppg_signal_quality_stats payload must be >=5 bytes, got {}",
            p.len()
        )));
    }
    let b1 = p[1];
    let b2 = p[2];
    let b3 = p[3];
    let b4 = p[4];
    if b2 & 0x80 != 0 || b4 & 0x80 != 0 {
        return Err(err("ppg_signal_quality_stats validity bit set"));
    }
    let content_mask = b4 & 0x3F;
    let mut m = dd("DebugDataPpgSignalQualityStats");
    m.insert("ppg_measurement_slot_1", Value::Int((b1 >> 4) as i64));
    m.insert("ppg_measurement_slot_2", Value::Int((b1 & 0x0F) as i64));
    m.insert("tune_reason", Value::Int((b2 & 0x7F) as i64));
    m.insert("led_channel_description_1", Value::Int(b3 as i64));
    m.insert("content_mask", Value::Int(content_mask as i64));
    if b4 & 0x40 != 0 {
        m.insert("stateful_flag_set", Value::Bool(true));
        m.insert("bit_payload_hex", Value::Str(hex(&p[5..])));
        return Ok(m);
    }
    if p.len() > 5 {
        let mut bs = BitStream::new(p, 5);
        let res = (|| -> Result<(), DecodeError> {
            if content_mask & 0x01 != 0 {
                m.insert("snr_value", Value::Int(bs.read(9)?));
            }
            if content_mask & 0x02 != 0 {
                let shift = bs.read(4)?;
                let val = bs.read(8)?;
                m.insert("ac_amplitude", Value::Int(val << shift));
            }
            if content_mask & 0x04 != 0 {
                m.insert("dc_value", Value::Int(bs.read(15)?));
            }
            if content_mask & 0x08 != 0 {
                m.insert("coupling_index", Value::Int(bs.read(9)?));
            }
            if content_mask & 0x10 != 0 {
                m.insert("tune_reason_extended", Value::Int(bs.read(4)?));
            }
            if content_mask & 0x20 != 0 {
                m.insert("ibi_quality_percentage", Value::Int(bs.read(7)?));
            }
            Ok(())
        })();
        if res.is_err() {
            m.insert("bit_payload_truncated", Value::Bool(true));
            m.insert("bit_payload_hex", Value::Str(hex(&p[5..])));
        }
    }
    Ok(m)
}

fn dd_afe_statistics_values(p: &[u8]) -> R {
    if p.len() < 14 {
        return Err(err(format!(
            "afe_statistics_values payload must be >=14 bytes, got {}",
            p.len()
        )));
    }
    let kind_byte = p[1];
    let record_kind = match kind_byte {
        1 => "header".to_string(),
        0 => "continuation".to_string(),
        k => format!("unknown_{k}"),
    };
    let mut m = dd("DebugDataAfeStatisticsValues");
    m.insert("record_kind", Value::Str(record_kind));
    m.insert("kind_byte", Value::Int(kind_byte as i64));
    m.insert("stats_hex", Value::Str(hex(&p[2..])));
    m.insert("all_stats_zero", Value::Bool(p[2..].iter().all(|&b| b == 0)));
    Ok(m)
}

fn dd_finger_detection(p: &[u8]) -> R {
    if p.len() < 9 {
        return Err(err(format!(
            "finger_detection payload must be >=9 bytes, got {}",
            p.len()
        )));
    }
    let mut v: u64 = 0;
    for i in 0..8 {
        v |= (p[1 + i] as u64) << (8 * i);
    }
    let mut m = dd("DebugDataFingerDetection");
    m.insert("detection_u64", Value::UInt(v));
    Ok(m)
}

fn dd_battery_level_changed(p: &[u8]) -> R {
    if p.len() < 5 {
        return Err(err(format!(
            "battery_level_changed payload must be >=5 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataBatteryLevelChanged");
    m.insert("battery_percentage", Value::Int(p[1] as i64));
    m.insert("battery_voltage_mv", Value::Int(u16_le(p, 2)));
    m.insert("reason", Value::Int(p[4] as i64));
    Ok(m)
}

fn dd_security_failure(p: &[u8]) -> R {
    if p.len() < 5 {
        return Err(err("security_failure payload too short"));
    }
    let mut m = dd("DebugDataSecurityFailure");
    m.insert("kind", Value::Int(p[1] as i64));
    m.insert("fields_hex", Value::Str(hex(&p[2..])));
    Ok(m)
}

fn dd_bootloader_debug_log(p: &[u8]) -> R {
    let mut m = dd("DebugDataBootLoaderDebugLog");
    m.insert("fields_hex", Value::Str(hex(&p[1..])));
    m.insert("len", Value::Int(p.len() as i64));
    Ok(m)
}

fn dd_fuel_gauge_register_dump(p: &[u8]) -> R {
    if p.len() < 14 {
        return Err(err("fuel_gauge_register_dump payload too short"));
    }
    let mut m = dd("DebugDataFuelGaugeRegisterDump");
    m.insert("reg_id_a", Value::Int(u16_le(p, 2)));
    m.insert("reg_id_b", Value::Int(u16_le(p, 12)));
    m.insert("body_hex", Value::Str(hex(&p[4..12])));
    Ok(m)
}

fn dd_ring_hw_information(p: &[u8]) -> R {
    if p.len() < 9 {
        return Err(err("ring_hw_information payload too short"));
    }
    let mut m = dd("DebugDataRingHwInformation");
    m.insert("u32_at_3", Value::Int(u32_le(p, 3)));
    m.insert("fields_hex", Value::Str(hex(&p[1..])));
    Ok(m)
}

fn dd_charging_ended_statistics(p: &[u8]) -> R {
    if p.len() < 12 {
        return Err(err("charging_ended_statistics payload too short"));
    }
    let mut m = dd("DebugDataChargingEndStatistics");
    m.insert("u32_at_1", Value::Int(u32_le(p, 1)));
    m.insert("u32_at_7", Value::Int(u32_le(p, 7)));
    m.insert("fields_hex", Value::Str(hex(&p[1..])));
    Ok(m)
}

fn dd_fuel_gauge_logging_registers(p: &[u8]) -> R {
    if p.len() < 9 {
        return Err(err("fuel_gauge_logging_registers payload too short"));
    }
    let mut m = dd("DebugDataFuelGaugeLoggingRegisters");
    m.insert("registers_hex", Value::Str(hex(&p[1..9])));
    Ok(m)
}

fn dd_hardware_test_start_values(p: &[u8]) -> R {
    if p.len() < 13 {
        return Err(err("hardware_test_start_values payload too short"));
    }
    let mut m = dd("DebugDataHardwareTestStartValues");
    m.insert("u16_at_2", Value::Int(u16_le(p, 2)));
    m.insert("body_hex", Value::Str(hex(&p[5..13])));
    Ok(m)
}

fn dd_charging_ended_statistics_continued(p: &[u8]) -> R {
    if p.len() < 13 {
        return Err(err("charging_ended_statistics_continued payload too short"));
    }
    let mut m = dd("DebugDataChargingEndStatisticsContinued");
    m.insert("body_hex", Value::Str(hex(&p[1..9])));
    m.insert("u32_at_9", Value::Int(u32_le(p, 9)));
    Ok(m)
}

fn dd_field_test_information(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err("field_test_information payload too short"));
    }
    let mut m = dd("DebugDataFieldTestInformation");
    m.insert("kind", Value::Int(p[1] as i64));
    m.insert("fields_hex", Value::Str(hex(&p[2..])));
    Ok(m)
}

fn dd_stack_usage_statistics(p: &[u8]) -> R {
    if p.len() < 13 {
        return Err(err("stack_usage_statistics payload too short"));
    }
    let mut m = dd("DebugDataStackUsageStatistics");
    m.insert("stack_high_watermarks_hex", Value::Str(hex(&p[1..9])));
    m.insert("u32_at_9", Value::Int(u32_le(p, 9)));
    Ok(m)
}

fn dd_daily_drop_sample(p: &[u8]) -> R {
    if p.len() < 4 {
        return Err(err("daily_drop_sample payload too short"));
    }
    let mut m = dd("DebugDataDailyDropSample");
    m.insert("byte_1", Value::Int(p[1] as i64));
    m.insert("byte_2", Value::Int(p[2] as i64));
    m.insert("byte_3", Value::Int(p[3] as i64));
    m.insert("fields_hex", Value::Str(hex(&p[4..])));
    Ok(m)
}

fn dd_charger_information(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err("charger_information payload too short"));
    }
    let kind = p[1];
    let sst = kind & 0x7F;
    let is_start = (kind >> 7) != 0;
    let mut m = dd("DebugDataChargerInformation");
    m.insert("is_session_start", Value::Bool(is_start));
    m.insert("sub_sub_type", Value::Int(sst as i64));
    let body = &p[2..];
    if sst == 0x01 && !body.is_empty() {
        m.insert("text", Value::Str(ascii_replace(body)));
    } else if sst == 0x04 && body.len() >= 8 {
        m.insert("link_param_a", Value::Int(u32_le(body, 0)));
        m.insert("link_param_b", Value::Int(u32_le(body, 4)));
        if body.len() > 8 {
            m.insert("body_tail_hex", Value::Str(hex(&body[8..])));
        }
    } else {
        m.insert("body_hex", Value::Str(hex(body)));
    }
    Ok(m)
}

fn dd_charger_debug_information(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err("charger_debug_information payload too short"));
    }
    let kind = p[1];
    let mut m = dd("DebugDataChargerDebugInformation");
    m.insert("kind_byte", Value::Int(kind as i64));
    let body = &p[2..];
    match kind {
        0 => {
            m.insert("record_kind", Value::Str("header".to_string()));
            m.insert("meta_hex", Value::Str(hex(body)));
        }
        1 => {
            m.insert("record_kind", Value::Str("continuation".to_string()));
            m.insert("data_hex", Value::Str(hex(body)));
        }
        k => {
            m.insert("record_kind", Value::Str(format!("unknown_{k}")));
            m.insert("body_hex", Value::Str(hex(body)));
        }
    }
    Ok(m)
}

fn dd_hardware_test_result_values(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err("hardware_test_result_values payload too short"));
    }
    let phase = p[1];
    let mut m = dd("DebugDataHardwareTestResultValues");
    m.insert("phase_byte", Value::Int(phase as i64));
    let body = &p[2..];
    match phase {
        0 => {
            m.insert("phase", Value::Str("init".to_string()));
            if body.len() >= 12 {
                m.insert("init_byte_2", Value::Int(body[0] as i64));
                m.insert("init_byte_3", Value::Int(body[1] as i64));
                m.insert("init_i32_at_4", Value::Int(i32_le(body, 2)));
                m.insert(
                    "init_i32_at_8",
                    if body.len() >= 10 {
                        Value::Int(i32_le(body, 6))
                    } else {
                        Value::Null
                    },
                );
                if body.len() > 10 {
                    m.insert("init_tail_hex", Value::Str(hex(&body[10..])));
                }
            } else {
                m.insert("body_hex", Value::Str(hex(body)));
            }
        }
        1 => {
            m.insert("phase", Value::Str("mid".to_string()));
            if body.len() >= 4 {
                m.insert("mid_u16_a", Value::Int(u16_le(body, 0)));
                m.insert("mid_u16_b", Value::Int(u16_le(body, 2)));
            } else {
                m.insert("body_hex", Value::Str(hex(body)));
            }
        }
        2 => {
            m.insert("phase", Value::Str("final".to_string()));
            if body.len() >= 8 {
                m.insert("final_i32_at_2", Value::Int(i32_le(body, 0)));
                m.insert("final_u32_at_6", Value::Int(u32_le(body, 4)));
            } else {
                m.insert("body_hex", Value::Str(hex(body)));
            }
        }
        k => {
            m.insert("phase", Value::Str(format!("unknown_{k}")));
            m.insert("body_hex", Value::Str(hex(body)));
        }
    }
    Ok(m)
}

fn dd_alt_text(p: &[u8]) -> R {
    let mut m = dd("DebugDataText");
    m.insert("text", Value::Str(ascii_replace(&p[1..])));
    Ok(m)
}

fn dd_alt_periodic_counter(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err(format!(
            "alt_periodic payload must be >=2 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataPeriodicCounter");
    m.insert("counter_byte", Value::Int(p[1] as i64));
    m.insert("trailing_hex", Value::Str(hex(&p[2..])));
    Ok(m)
}

fn dd_alt_afe_period_tick(p: &[u8]) -> R {
    if p.len() < 7 {
        return Err(err(format!(
            "afe_period_tick payload must be >=7 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataAfePeriodTick");
    m.insert("period_us", Value::Int(u16_le(p, 3)));
    Ok(m)
}

fn dd_alt_ppg_cont(p: &[u8]) -> R {
    if p.len() < 5 {
        return Err(err(format!(
            "alt_ppg_cont payload must be >=5 bytes, got {}",
            p.len()
        )));
    }
    let mut m = dd("DebugDataPpgCont");
    m.insert("header_3b_hex", Value::Str(hex(&p[1..4])));
    m.insert("sub_sub_byte", Value::Int(p[4] as i64));
    m.insert("tail_hex", Value::Str(hex(&p[5..])));
    Ok(m)
}

fn dd_open_afe_ppg_settings_data(p: &[u8]) -> R {
    if p.len() < 2 {
        return Err(err(format!(
            "open_afe_ppg_settings payload must be >=2 bytes, got {}",
            p.len()
        )));
    }
    let chip = p[1];
    let chip_name = match chip {
        0x01 => "MAX86171".to_string(),
        0x02 => "MAX86173".to_string(),
        0x03 => "MAX86178".to_string(),
        c => format!("unknown_0x{c:02x}"),
    };
    let mut m = dd("DebugDataOpenAfePpgSettingsData");
    m.insert("chip_variant", Value::Int(chip as i64));
    m.insert("chip_variant_name", Value::Str(chip_name));
    if p.len() >= 14 {
        m.insert("settings_hex", Value::Str(hex(&p[2..])));
    } else {
        m.insert("truncated", Value::Bool(true));
        m.insert("payload_hex", Value::Str(hex(&p[2..])));
    }
    Ok(m)
}

fn dd_lib_no_parser(p: &[u8]) -> Map {
    let mut m = dd("lib_no_parser");
    m.insert("sub_byte", Value::Int(p[0] as i64));
    m.insert("hex", Value::Str(hex(&p[1..])));
    m.insert("len", Value::Int(p.len() as i64));
    m
}

/// sub-bytes mapping to the firmware default-throw branch that we havent seen
/// enough of to RE
fn is_lib_no_parser(sub: u8) -> bool {
    matches!(
        sub,
        0x03 | 0x05 | 0x06 | 0x07 | 0x08 | 0x0b | 0x13 | 0x16 | 0x2f | 0x39
    )
}

fn dispatch(sub: u8, p: &[u8]) -> Option<R> {
    Some(match sub {
        0x04 => dd_alt_text(p),
        0x09 => dd_sleep_statistics(p),
        0x0a => dd_flash_usage_statistics(p),
        0x0c => dd_period_info_statistics(p),
        0x0d => dd_ble_usage_statistics(p),
        0x0f => dd_security_failure(p),
        0x14 => dd_fuel_gauge_statistics(p),
        0x15 => dd_finger_detection(p),
        0x1a => dd_event_sync_statistics(p),
        0x1b => dd_bootloader_debug_log(p),
        0x1e => dd_fuel_gauge_register_dump(p),
        0x1f => dd_ring_hw_information(p),
        0x20 => dd_charging_ended_statistics(p),
        0x21 => dd_fuel_gauge_logging_registers(p),
        0x23 => dd_event_sync_cache_statistics(p),
        0x24 => dd_battery_level_changed(p),
        0x25 => dd_hardware_test_start_values(p),
        0x26 => dd_hardware_test_result_values(p),
        0x27 => dd_charging_ended_statistics_continued(p),
        0x28 => dd_afe_statistics_values(p),
        0x29 => dd_acm_configuration_changed(p),
        0x2a => dd_field_test_information(p),
        0x2b => dd_stack_usage_statistics(p),
        0x30 => dd_alt_periodic_counter(p),
        0x33 => dd_open_afe_ppg_settings_data(p),
        0x35 => dd_ppg_signal_quality_stats(p),
        0x36 => dd_charger_information(p),
        0x3b => dd_alt_afe_period_tick(p),
        0x3c => dd_alt_ppg_cont(p),
        0x3d => dd_charger_debug_information(p),
        0x3f => dd_daily_drop_sample(p),
        _ => return None,
    })
}

/// `0x61 API_DEBUG_DATA`, first byte selects the sub-type
pub fn decode_debug_data(p: &[u8]) -> R {
    if p.is_empty() {
        return Err(err("DebugData payload is empty"));
    }
    let sub = p[0];
    match dispatch(sub, p) {
        Some(Ok(mut m)) => {
            m.insert("sub_byte", Value::Int(sub as i64));
            Ok(m)
        }
        Some(Err(e)) => Err(e),
        None => {
            let mut m = if is_lib_no_parser(sub) {
                dd_lib_no_parser(p)
            } else {
                let mut m = Map::new();
                m.insert("_dd", Value::Str(format!("unknown_sub_0x{sub:02x}")));
                m.insert("sub_byte", Value::Int(sub as i64));
                m.insert("hex", Value::Str(hex(p)));
                m.insert("len", Value::Int(p.len() as i64));
                m
            };
            // sub_byte set on the no-parser/unknown maps too
            m.insert("sub_byte", Value::Int(sub as i64));
            Ok(m)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_level_changed() {
        // sub=0x24 pct=80 mv=4000 (0x0fa0) reason=2
        let p = [0x24, 80, 0xa0, 0x0f, 2];
        let m = decode_debug_data(&p).unwrap();
        assert_eq!(m.get("battery_percentage"), Some(&Value::Int(80)));
        assert_eq!(m.get("battery_voltage_mv"), Some(&Value::Int(4000)));
    }

    #[test]
    fn lib_no_parser_marked() {
        let p = [0x03, 1, 2, 3];
        let m = decode_debug_data(&p).unwrap();
        assert_eq!(m.get("_dd"), Some(&Value::Str("lib_no_parser".to_string())));
    }
}
