//! Wire framing.
//!
//! two layers:
//!  1. outer frame on either characteristic `<op:1><len:1><sub:1><payload:len-1>`,
//!     multiple frames pack into one ATT value, consume `2 + len` and loop
//!  2. inner record stream on notify char, TLV
//!     `<type:1><len:1><ctr_lo:1><ctr_hi:1><sess_lo:1><sess_hi:1><payload:len-4>`,
//!     records concatenate up to MTU
//!
//! one notification carries outer frames or inner records; first byte
//! disambiguates (known outer opcode = outer frames else inner stream)

/// outer-frame opcode name, None if unknown, bidirectional (phone<->ring)
pub fn opcode_name(op: u8) -> Option<&'static str> {
    Some(match op {
        0x06 => "identity_req",
        0x07 => "identity_resp",
        0x08 => "time_or_id_req",
        0x09 => "time_or_id_resp",
        0x0c => "battery_req",
        0x0d => "battery_resp",
        0x0e => "soft_reset_req",
        0x0f => "soft_reset_ack",
        0x10 => "history_fetch",
        0x11 => "history_fetch_resp",
        0x12 => "time_sync_req",
        0x13 => "time_sync_resp",
        0x16 => "subscribe",
        0x17 => "subscribe_ack",
        0x18 => "event_subscribe",
        0x19 => "event_resp",
        0x1c => "state_cmd",
        0x1d => "state_cmd_resp",
        0x1e => "state_query",
        0x1f => "state_query_resp",
        0x24 => "fw_authorize",
        0x28 => "data_flush",
        0x29 => "data_flush_ack",
        0x2b => "fw_progress",
        0x2c => "fw_bulk",
        0x2f => "secure_session",
        _ => return None,
    })
}

pub fn is_opcode(op: u8) -> bool {
    opcode_name(op).is_some()
}

/// one outer frame parsed from an ATT value
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OuterFrame {
    pub opcode: u8,
    /// first byte of payload, None if no body
    pub sub_op: Option<u8>,
    /// everything after the length byte, including `sub_op`
    pub body: Vec<u8>,
    /// entire frame including opcode + length
    pub raw: Vec<u8>,
}

impl OuterFrame {
    pub fn name(&self) -> String {
        match opcode_name(self.opcode) {
            Some(n) => n.to_string(),
            None => format!("unknown_{:02x}", self.opcode),
        }
    }
}

/// one inner record parsed from a notify-char value
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InnerRecord {
    pub type_byte: u8,
    /// uint16 LE, low 16 bits of `ring_time`
    pub counter: u16,
    /// uint16 LE, high 16 bits of `ring_time`
    pub session: u16,
    /// bytes after the 4-byte ctr+sess header
    pub payload: Vec<u8>,
}

impl InnerRecord {
    /// 32-bit `ringTimestamp`: `(session << 16) | counter`.
    /// monotonic per-stream event-sequence cursor not a wall-clock, see
    /// [`crate::sync_state::SyncState::to_utc_ms`] for the time mapping
    pub fn ring_time(&self) -> u32 {
        ((self.session as u32) << 16) | (self.counter as u32)
    }
}

/// parse outer frames packed into one ATT value, stops on first byte that is
/// not a known opcode (typically an inner-record stream)
pub fn parse_outer_frames(value: &[u8]) -> Vec<OuterFrame> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 2 <= value.len() {
        let op = value[i];
        let ln = value[i + 1] as usize;
        if !is_opcode(op) || i + 2 + ln > value.len() {
            break;
        }
        let body = value[i + 2..i + 2 + ln].to_vec();
        let sub = if ln >= 1 { Some(body[0]) } else { None };
        let raw = value[i..i + 2 + ln].to_vec();
        out.push(OuterFrame {
            opcode: op,
            sub_op: sub,
            body,
            raw,
        });
        i += 2 + ln;
    }
    out
}

/// parse inner records concatenated into one notification. stops when bytes
/// cant form a complete TLV (truncated body, or `ln < 4` so no room for the
/// ringTimestamp header). suspect-but-complete records still emitted, callers
/// check [`crate::enums::is_structurally_unknown`]
pub fn parse_inner_records(value: &[u8]) -> Vec<InnerRecord> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 2 <= value.len() {
        let t = value[i];
        let ln = value[i + 1] as usize;
        let body_end = i + 2 + ln;
        if body_end > value.len() || ln < 4 {
            break;
        }
        let body = &value[i + 2..body_end];
        let ctr = (body[0] as u16) | ((body[1] as u16) << 8);
        let sess = (body[2] as u16) | ((body[3] as u16) << 8);
        out.push(InnerRecord {
            type_byte: t,
            counter: ctr,
            session: sess,
            payload: body[4..].to_vec(),
        });
        i += 2 + ln;
    }
    out
}

/// first-byte test: outer-frame stream or inner-record stream
pub fn looks_like_outer_frame(value: &[u8]) -> bool {
    !value.is_empty() && is_opcode(value[0])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_time_packs_le() {
        let r = InnerRecord {
            type_byte: 0x60,
            counter: 0x1234,
            session: 0x00ab,
            payload: vec![],
        };
        assert_eq!(r.ring_time(), 0x00ab_1234);
    }

    #[test]
    fn outer_frame_handshake_start() {
        let frames = parse_outer_frames(&[0x2f, 0x01, 0x2b]);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].opcode, 0x2f);
        assert_eq!(frames[0].sub_op, Some(0x2b));
    }

    #[test]
    fn inner_record_basic() {
        // type=0x46 len=6: ctr=0x0001 sess=0x0002 payload=[0xaa,0xbb]
        let v = [0x46, 0x06, 0x01, 0x00, 0x02, 0x00, 0xaa, 0xbb];
        let recs = parse_inner_records(&v);
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].type_byte, 0x46);
        assert_eq!(recs[0].counter, 1);
        assert_eq!(recs[0].session, 2);
        assert_eq!(recs[0].payload, vec![0xaa, 0xbb]);
    }
}
