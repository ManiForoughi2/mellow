//! Ring-side state tracking from the decoded record stream.
//!
//! [`RingState`] reflects what the ring believes its own state is, inferred
//! from wire events (StateChangeInd / WearEvent, RingStartInd) and the ASCII
//! debug strings in `API_DEBUG_EVENT_IND` (0x43): DHR/CVA/A:SA/EHR/charging/
//! battery/orientation/SpO2 sub-machines. pure data + one `apply`, no IO.
//!
//! the reference driver's `ClientState` (driver-side telemetry) lives in the
//! Swift orchestrator on iOS, not duplicated here

use crate::enums::state_change;

/// parse the int following `prefix` in `text` when the remainder is all digits
fn parse_prefixed_uint(text: &str, prefix: &str) -> Option<i64> {
    let rest = text.strip_prefix(prefix)?;
    if rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    rest.parse::<i64>().ok()
}

/// what the ring believes its own state is, from the decoded record stream,
/// not authoritative (ring is source of truth)
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RingState {
    pub is_connected: bool,
    pub last_seen_ms: Option<i64>,

    // unified state machine (StateChangeInd / WearEvent, same enum)
    pub state: Option<i64>,
    pub state_name: Option<String>,
    pub state_text: Option<String>,
    pub state_changes_seen: u64,

    // sub-state machines from 0x43 debug strings
    pub dhr_state: Option<i64>,
    pub dhr_mode: Option<i64>,
    pub dhr_state_changes: u64,
    pub dhr_main_loop_count: u64,
    pub dhr_retry_count: u64,

    pub cva_state: Option<i64>,
    pub cva_revolutions: u64,

    /// last (x, y) from `A:SA:x,y>z`
    pub sleep_active: Option<(i64, i64)>,
    /// `>z` target from `A:SA`
    pub sleep_active_target: Option<i64>,
    pub sleep_active_transitions: u64,

    /// last (a, b, c) from `EHRst;a;b;c`
    pub ehr_state: Option<(i64, i64, i64)>,

    pub orientation: Option<i64>,
    pub o2_mode: Option<i64>,

    pub battery_pct: Option<i64>,
    pub battery_voltage_mv: Option<i64>,
    pub charging_state: Option<i64>,
    pub charging_validity: Option<i64>,

    pub last_debug_text: Option<String>,
    pub last_record_type: Option<String>,
}

impl RingState {
    pub fn new() -> Self {
        Self::default()
    }

    /// apply one decoded wire record. wire events drive the state machine,
    /// debug strings route through [`RingState::apply_debug`]
    pub fn apply_wire(&mut self, type_name: &str, t_ms: i64, state_byte: Option<i64>, text: Option<&str>) {
        self.last_seen_ms = Some(t_ms);
        self.is_connected = true;
        self.last_record_type = Some(type_name.to_string());

        match type_name {
            "API_RING_START_IND" => {
                self.state = None;
                self.state_changes_seen += 1;
            }
            "API_STATE_CHANGE_IND" | "API_WEAR_EVENT" => {
                if let Some(new) = state_byte {
                    if self.state != Some(new) {
                        self.state_changes_seen += 1;
                    }
                    self.state = Some(new);
                    self.state_name = state_change(new as u8).map(|s| s.to_string());
                } else {
                    self.state = None;
                    self.state_name = None;
                }
                self.state_text = text.filter(|t| !t.is_empty()).map(|t| t.to_string());
            }
            "API_DEBUG_EVENT_IND" => {
                self.apply_debug(text.unwrap_or(""));
            }
            _ => {}
        }
    }

    /// parse one ASCII debug string into the sub-state machines
    pub fn apply_debug(&mut self, text: &str) {
        self.last_debug_text = Some(text.to_string());

        if let Some(n) = parse_prefixed_uint(text, "DHR_state:") {
            let prev = self.dhr_state;
            if let Some(p) = prev {
                if p != n {
                    self.dhr_state_changes += 1;
                    if p == 2 && n == 0 {
                        self.dhr_main_loop_count += 1;
                    }
                    if n == 5 {
                        self.dhr_retry_count += 1;
                    }
                }
            }
            self.dhr_state = Some(n);
            return;
        }
        if let Some(n) = parse_prefixed_uint(text, "DHR_mode:") {
            self.dhr_mode = Some(n);
            return;
        }
        if let Some(n) = parse_prefixed_uint(text, "CVA_state;") {
            if self.cva_state == Some(5) && n == 1 {
                self.cva_revolutions += 1;
            }
            self.cva_state = Some(n);
            return;
        }
        if let Some((x, y, z)) = parse_a_sa(text) {
            let new_pair = (x, y);
            if let Some(prev) = self.sleep_active {
                if prev != new_pair {
                    self.sleep_active_transitions += 1;
                }
            }
            self.sleep_active = Some(new_pair);
            self.sleep_active_target = Some(z);
            return;
        }
        if let Some((a, b, c)) = parse_ehr(text) {
            self.ehr_state = Some((a, b, c));
            return;
        }
        if let Some(n) = parse_prefixed_uint(text, "batt:").or_else(|| parse_prefixed_uint(text, "batt: ")) {
            self.battery_pct = Some(n);
            return;
        }
        if let Some(n) = parse_prefixed_uint(text, "orientation ") {
            self.orientation = Some(n);
            return;
        }
        if let Some((s, v)) = parse_two(text, "chg_ind;") {
            self.charging_state = Some(s);
            self.charging_validity = Some(v);
            return;
        }
        if let Some(n) = parse_prefixed_uint(text, "O2Mode;") {
            self.o2_mode = Some(n);
        }
    }
}

/// parse `A:SA:x,y>z`
fn parse_a_sa(text: &str) -> Option<(i64, i64, i64)> {
    let rest = text.strip_prefix("A:SA:")?;
    let (xy, z) = rest.split_once('>')?;
    let (x, y) = xy.split_once(',')?;
    Some((x.parse().ok()?, y.parse().ok()?, z.parse().ok()?))
}

/// parse `EHRst;a;b;c`
fn parse_ehr(text: &str) -> Option<(i64, i64, i64)> {
    let rest = text.strip_prefix("EHRst;")?;
    let parts: Vec<&str> = rest.split(';').collect();
    if parts.len() != 3 {
        return None;
    }
    Some((
        parts[0].parse().ok()?,
        parts[1].parse().ok()?,
        parts[2].parse().ok()?,
    ))
}

/// parse `<prefix>a;b`
fn parse_two(text: &str, prefix: &str) -> Option<(i64, i64)> {
    let rest = text.strip_prefix(prefix)?;
    let (a, b) = rest.split_once(';')?;
    Some((a.parse().ok()?, b.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dhr_main_loop_counted_on_2_to_0() {
        let mut s = RingState::new();
        s.apply_debug("DHR_state:2");
        s.apply_debug("DHR_state:0");
        assert_eq!(s.dhr_main_loop_count, 1);
        assert_eq!(s.dhr_state, Some(0));
    }

    #[test]
    fn cva_revolution_on_5_to_1() {
        let mut s = RingState::new();
        s.apply_debug("CVA_state;5");
        s.apply_debug("CVA_state;1");
        assert_eq!(s.cva_revolutions, 1);
    }

    #[test]
    fn a_sa_parsed() {
        let mut s = RingState::new();
        s.apply_debug("A:SA:1,2>3");
        assert_eq!(s.sleep_active, Some((1, 2)));
        assert_eq!(s.sleep_active_target, Some(3));
    }

    #[test]
    fn battery_and_charging() {
        let mut s = RingState::new();
        s.apply_debug("batt:87");
        assert_eq!(s.battery_pct, Some(87));
        s.apply_debug("chg_ind;2;1");
        assert_eq!(s.charging_state, Some(2));
        assert_eq!(s.charging_validity, Some(1));
    }

    #[test]
    fn wear_event_updates_state() {
        let mut s = RingState::new();
        s.apply_wire("API_WEAR_EVENT", 1000, Some(3), Some("worn"));
        assert_eq!(s.state, Some(3));
        assert_eq!(s.state_name.as_deref(), Some("STATE_FINGER_USER_ACTIVE"));
    }
}
