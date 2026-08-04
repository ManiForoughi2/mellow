//! Control-plane outer-frame builders.
//!
//! exact byte sequences the phone writes to the ring command characteristic.
//! pure functions (host supplies nonces/timestamps), bytes reproducible.
//! every sequence verified against captured phone<->ring traffic

use crate::crypto::{compute_handshake_proof, CryptoError};

// handshake (secure session, opcode 0x2f)

/// phone -> ring handshake start frame `2F 01 2B`
pub fn handshake_start() -> [u8; 3] {
    [0x2f, 0x01, 0x2b]
}

/// from the ring's 15-byte nonce (body of `2F 10 2C <nonce:15>`) and 16-byte
/// `auth_key`, build proof frame `2F 11 2D <proof:16>` (19 bytes)
pub fn handshake_proof_frame(
    auth_key: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let proof = compute_handshake_proof(auth_key, nonce)?;
    let mut frame = Vec::with_capacity(3 + 16);
    frame.extend_from_slice(&[0x2f, 0x11, 0x2d]);
    frame.extend_from_slice(&proof);
    Ok(frame)
}

// time sync (opcode 0x12)

/// time-sync request frame:
///
/// ```text
/// 12 09 <token:1> <counter:3 LE> 00 00 00 00 f6
/// ```
///
/// counter = unix_time_s / 256. token is a host-supplied random byte (ring does
/// not validate it)
pub fn time_sync_frame(token: u8, unix_time_s: u64) -> [u8; 11] {
    let counter = (unix_time_s / 256) as u32;
    [
        0x12,
        0x09,
        token,
        (counter & 0xff) as u8,
        ((counter >> 8) & 0xff) as u8,
        ((counter >> 16) & 0xff) as u8,
        0x00,
        0x00,
        0x00,
        0x00,
        0xf6,
    ]
}

// parameter RPC (opcode 0x2f feature/param plane)

/// documented parameter IDs
pub mod param {
    /// Daytime Heart Rate, bytes 0/2 are mode/sub-mode
    pub const DHR: u8 = 0x02;
    /// activity HR enable, byte 0 toggle
    pub const ACTIVITY_HR: u8 = 0x03;
    /// SpO2 enable, byte 0 toggle
    pub const SPO2: u8 = 0x04;
    /// companion to ACTIVITY_HR, read-only in observed traffic
    pub const ACTIVITY_HR_AUX: u8 = 0x0B;
    pub const UNMAPPED_0D: u8 = 0x0D;
    pub const UNMAPPED_10: u8 = 0x10;
    /// polled by the official app at connection, answers all zeroes
    pub const UNMAPPED_12: u8 = 0x12;
}

/// the param sweep the official app performs once per connection, in order.
/// not required to start a measurement; recorded so the connection flow can be
/// matched against the app when diagnosing a ring that withholds features.
pub const CONNECT_PARAM_SWEEP: [u8; 5] = [0x12, 0x0c, 0x0b, 0x04, 0x10];

/// `2F 02 20 <param>` request the 4-byte param value
pub fn read_param(param_id: u8) -> [u8; 4] {
    [0x2f, 0x02, 0x20, param_id]
}

/// `2F 03 22 <param> <value>` set BYTE 0 of the param
pub fn write_param_byte0(param_id: u8, value: u8) -> [u8; 5] {
    [0x2f, 0x03, 0x22, param_id, value]
}

/// `2F 03 26 <param> <value>` set BYTE 2 of the param
pub fn write_param_byte2(param_id: u8, value: u8) -> [u8; 5] {
    [0x2f, 0x03, 0x26, param_id, value]
}

/// byte-perfect Daytime-HR mode write: byte-0 (mode) then byte-2 (sub-mode).
/// frames in send order.
///
/// no `read_param` prefix. a capture of the official app on a second ring
/// (2026-08-04, see EXTERNAL_CAPTURE_FINDINGS.md) shows it starts a measurement
/// with exactly these two writes. it does issue `read_param` sweeps, but at
/// connection time over params 0x12/0x0c/0x0b/0x04/0x10, unrelated to starting
/// a measurement.
pub fn set_dhr_mode(mode: u8, sub_mode: u8) -> Vec<Vec<u8>> {
    vec![
        write_param_byte0(param::DHR, mode).to_vec(),
        write_param_byte2(param::DHR, sub_mode).to_vec(),
    ]
}

/// on-demand HR burst: DHR mode=3 / sub-mode=2
pub fn request_hr_on_demand() -> Vec<Vec<u8>> {
    set_dhr_mode(3, 2)
}

/// stop an on-demand burst the way the app does: mode back to 1 (automatic),
/// subscription back to 0 (off). the ring also reverts on its own after ~20 s.
pub fn stop_hr_on_demand() -> Vec<Vec<u8>> {
    set_dhr_mode(1, 0)
}

/// toggle SpO2 sampling (byte-0 write to the SpO2 param)
pub fn set_spo2(on: bool) -> [u8; 5] {
    write_param_byte0(param::SPO2, if on { 0x01 } else { 0x00 })
}

pub fn set_activity_hr(on: bool) -> [u8; 5] {
    write_param_byte0(param::ACTIVITY_HR, if on { 0x01 } else { 0x00 })
}

// history fetch / reset / subscribe

/// phone -> ring `10 09 <ring_timestamp:4 LE> <max_events:1> <flags:4 LE>` 11
/// bytes. ring streams every event with `ringTimestamp > ring_timestamp`
pub fn request_events_since(ring_timestamp: u32, max_events: u8, flags: u32) -> [u8; 11] {
    [
        0x10,
        0x09,
        (ring_timestamp & 0xff) as u8,
        ((ring_timestamp >> 8) & 0xff) as u8,
        ((ring_timestamp >> 16) & 0xff) as u8,
        ((ring_timestamp >> 24) & 0xff) as u8,
        max_events,
        (flags & 0xff) as u8,
        ((flags >> 8) & 0xff) as u8,
        ((flags >> 16) & 0xff) as u8,
        ((flags >> 24) & 0xff) as u8,
    ]
}

/// default catch-up: from `ring_timestamp`, up to 255 events, all flags
pub fn request_events_since_default(ring_timestamp: u32) -> [u8; 11] {
    request_events_since(ring_timestamp, 255, 0xFFFF_FFFF)
}

/// soft reset: phone sends `0E 01 FF`, ring acks `0F 01 00` and reboots
pub fn soft_reset() -> [u8; 3] {
    [0x0e, 0x01, 0xff]
}

/// per-category event-subscribe frame `18 03 <category:u8> <flags:u16 LE>`
pub fn event_subscribe(category: u8, flags: u16) -> [u8; 5] {
    [
        0x18,
        0x03,
        category,
        (flags & 0xff) as u8,
        ((flags >> 8) & 0xff) as u8,
    ]
}

/// subscribe-enable toggle `16 01 02`
pub fn subscribe_enable() -> [u8; 3] {
    [0x16, 0x01, 0x02]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handshake_start_bytes() {
        assert_eq!(handshake_start(), [0x2f, 0x01, 0x2b]);
    }

    #[test]
    fn proof_frame_shape() {
        let key = [0u8; 16];
        let nonce = [0u8; 15];
        let f = handshake_proof_frame(&key, &nonce).unwrap();
        assert_eq!(f.len(), 19);
        assert_eq!(&f[..3], &[0x2f, 0x11, 0x2d]);
    }

    #[test]
    fn time_sync_trailer_is_f6() {
        let f = time_sync_frame(0xAB, 256 * 5);
        assert_eq!(f[0], 0x12);
        assert_eq!(f[1], 0x09);
        assert_eq!(f[2], 0xAB);
        assert_eq!(&f[3..6], &[5, 0, 0]);
        assert_eq!(f[10], 0xf6);
    }

    #[test]
    fn get_event_frame() {
        let f = request_events_since_default(0x0083_dd11);
        assert_eq!(f[0], 0x10);
        assert_eq!(f[1], 0x09);
        assert_eq!(&f[2..6], &[0x11, 0xdd, 0x83, 0x00]);
        assert_eq!(f[6], 255);
        assert_eq!(&f[7..11], &[0xff, 0xff, 0xff, 0xff]);
    }

    #[test]
    fn dhr_burst_sequence() {
        // exactly what the official app writes to start a measurement
        let seq = request_hr_on_demand();
        assert_eq!(seq.len(), 2);
        assert_eq!(seq[0], vec![0x2f, 0x03, 0x22, 0x02, 0x03]);
        assert_eq!(seq[1], vec![0x2f, 0x03, 0x26, 0x02, 0x02]);
    }

    #[test]
    fn dhr_stop_sequence() {
        let seq = stop_hr_on_demand();
        assert_eq!(seq.len(), 2);
        assert_eq!(seq[0], vec![0x2f, 0x03, 0x22, 0x02, 0x01]);
        assert_eq!(seq[1], vec![0x2f, 0x03, 0x26, 0x02, 0x00]);
    }
}
