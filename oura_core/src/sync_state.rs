//! Persistent sync state: delta-resume cursor + ring_time->UTC anchor.
//!
//! ring streams events tagged with a monotonic 32-bit `ringTimestamp`. on
//! reconnect we send `GetEvent(eventStartTimestamp = T)`, ring streams every
//! event newer than `T`; response carries the latest timestamp, next `T`.
//!
//! `(anchor_ring_time, anchor_utc_ms, anchor_factor_flag)` interpolates
//! per-event wall-clock from a record's `ring_time`, fresh 0x42 updates it.
//!
//! pure state object, file persistence lives in the host app. `now_ms` is
//! caller-supplied so the crate has no clock dependency

/// candidate `utc_ms` must be within ±48h of the system clock to be accepted
pub const ANCHOR_VALIDATION_WINDOW_MS: i64 = 48 * 3600 * 1000;

pub const FORMAT_VERSION: u32 = 4;

/// cursor + ring_time->utc anchor
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncState {
    /// u32 catchup cursor for next `GetEvent`, 0 = no prior sync
    pub last_ring_timestamp: u32,
    /// ringTime of last valid anchor, 0 = none
    pub anchor_ring_time: u32,
    /// utc_ms of last valid anchor, 0 = none
    pub anchor_utc_ms: i64,
    /// 0 = 100 ms/tick (default), 1 = 1 ms/tick (burst)
    pub anchor_factor_flag: u8,
    /// ring serial once observed (which device this is for)
    pub ring_serial: Option<String>,
}

impl Default for SyncState {
    fn default() -> Self {
        SyncState {
            last_ring_timestamp: 0,
            anchor_ring_time: 0,
            anchor_utc_ms: 0,
            anchor_factor_flag: 0,
            ring_serial: None,
        }
    }
}

impl SyncState {
    pub fn new() -> Self {
        Self::default()
    }

    /// advance the saved timestamp, monotone never regresses (event log is
    /// append-only). true if the stored value changed
    pub fn update(&mut self, ring_timestamp: u32) -> bool {
        if ring_timestamp > self.last_ring_timestamp {
            self.last_ring_timestamp = ring_timestamp;
            true
        } else {
            false
        }
    }

    /// set the `(ring_time, utc_ms, factor_flag)` anchor from a fresh 0x42 or
    /// 0x41. true if the stored anchor changed.
    /// `Some(now_ms)` requires candidate within ±48h (rejects corrupt ring
    /// timestamps); `None` for offline replay where system time != capture time
    pub fn update_anchor(
        &mut self,
        ring_time: u32,
        utc_ms: i64,
        factor_flag: u8,
        validate_against_now: Option<i64>,
    ) -> bool {
        if let Some(now_ms) = validate_against_now {
            if (utc_ms - now_ms).abs() > ANCHOR_VALIDATION_WINDOW_MS {
                return false;
            }
        }
        if ring_time == 0 || utc_ms <= 0 {
            return false;
        }
        // only accept newer ring_time (or any if previously invalid), avoids
        // regressing on out-of-order events during catchup
        if self.anchor_ring_time != 0 && ring_time < self.anchor_ring_time {
            return false;
        }
        if ring_time == self.anchor_ring_time
            && utc_ms == self.anchor_utc_ms
            && factor_flag == self.anchor_factor_flag
        {
            return false;
        }
        self.anchor_ring_time = ring_time;
        self.anchor_utc_ms = utc_ms;
        self.anchor_factor_flag = factor_flag;
        true
    }

    pub fn invalidate_anchor(&mut self) {
        self.anchor_ring_time = 0;
        self.anchor_utc_ms = 0;
    }

    /// interpolate `ring_time` to unix-ms, single-anchor linear extrapolation:
    ///
    /// ```text
    /// factor = if anchor_factor_flag == 0 { 100 } else { 1 }   // ms per tick
    /// utc_ms = anchor_utc_ms + factor * (target - anchor_ring_time)
    /// ```
    ///
    /// None when no valid anchor or the result would be <= 0
    pub fn to_utc_ms(&self, target_ring_time: u32) -> Option<i64> {
        if self.anchor_ring_time == 0 || self.anchor_utc_ms == 0 {
            return None;
        }
        let factor: i64 = if self.anchor_factor_flag == 0 { 100 } else { 1 };
        let delta = target_ring_time as i64 - self.anchor_ring_time as i64;
        if delta >= 0 {
            Some(self.anchor_utc_ms + factor * delta)
        } else {
            let result = self.anchor_utc_ms - factor * (-delta);
            if result > 0 {
                Some(result)
            } else {
                None
            }
        }
    }

    /// true if serial is unset or matches, check before applying a loaded
    /// timestamp to a freshly-connected ring
    pub fn matches_ring(&self, serial: &str) -> bool {
        match &self.ring_serial {
            None => true,
            Some(s) => s == serial,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_is_monotone() {
        let mut s = SyncState::new();
        assert!(s.update(100));
        assert!(!s.update(50));
        assert_eq!(s.last_ring_timestamp, 100);
    }

    #[test]
    fn anchor_and_interpolation_default_mode() {
        let mut s = SyncState::new();
        let now = 1_777_258_345_000i64;
        assert!(s.update_anchor(8_638_042, now, 0, Some(now)));
        // +10 ticks * 100 ms = +1000 ms
        assert_eq!(s.to_utc_ms(8_638_052), Some(now + 1000));
    }

    #[test]
    fn anchor_burst_mode() {
        let mut s = SyncState::new();
        let now = 1_777_258_345_000i64;
        s.update_anchor(1000, now, 1, Some(now));
        assert_eq!(s.to_utc_ms(1100), Some(now + 100)); // 100 ticks * 1ms
    }

    #[test]
    fn no_anchor_returns_none() {
        let s = SyncState::new();
        assert_eq!(s.to_utc_ms(123), None);
    }

    #[test]
    fn anchor_rejected_outside_window() {
        let mut s = SyncState::new();
        let now = 1_777_258_345_000i64;
        assert!(!s.update_anchor(1000, 0, 0, Some(now)));
        assert!(!s.update_anchor(1000, now + ANCHOR_VALIDATION_WINDOW_MS + 1, 0, Some(now)));
    }
}
