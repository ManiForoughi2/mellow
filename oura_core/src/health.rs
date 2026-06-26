//! Derived health metrics on top of the raw decoders.
//!
//! [`crate::decoders`] return exact wire fields, here we derive app-facing
//! values (instant HR from IBIs, averaged SpO2, current HRV, skin temp).
//! shared in core so every platform computes identical numbers

fn median(xs: &[i64]) -> Option<f64> {
    if xs.is_empty() {
        return None;
    }
    let mut s = xs.to_vec();
    s.sort_unstable();
    let n = s.len();
    if n % 2 == 1 {
        Some(s[n / 2] as f64)
    } else {
        Some((s[n / 2 - 1] + s[n / 2]) as f64 / 2.0)
    }
}

/// instant HR (bpm) from inter-beat intervals (ms).
/// keeps plausible adult IBIs only (300-2000 ms = 30-200 bpm), median then bpm
pub fn hr_from_ibis(ibi_ms: &[i64]) -> Option<f64> {
    let filtered: Vec<i64> = ibi_ms
        .iter()
        .copied()
        .filter(|&v| (300..=2000).contains(&v))
        .collect();
    let m = median(&filtered)?;
    if m > 0.0 {
        Some(60000.0 / m)
    } else {
        None
    }
}

/// green-IBI quality filter on a 0x80 payload, returns surviving IBIs (ms).
/// keeps a sample when quality_a <= 1 && quality_b == 0; p is even len >= 2
pub fn green_ibi_filtered(p: &[u8]) -> Vec<i64> {
    if p.len() < 2 || p.len() % 2 != 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut i = 0;
    while i + 1 < p.len() {
        let b_low = p[i] as i64;
        let b_high = p[i + 1] as i64;
        let value = (b_low << 3) | (b_high & 0x07);
        let qa = (b_high >> 3) & 0x03;
        let qb = (b_high >> 5) & 0x07;
        if qa <= 1 && qb == 0 {
            out.push(value);
        }
        i += 2;
    }
    out
}

/// all IBIs (ms) from a 0x60 payload: 14 bytes, 6 bit-packed IBI/amp pairs
pub fn ibi60_intervals(p: &[u8]) -> Vec<i64> {
    if p.len() != 14 {
        return Vec::new();
    }
    let b12 = p[12] as i64;
    let b13 = p[13] as i64;
    let mid = [
        (b12 >> 5) & 0x6,
        (b12 >> 3) & 0x6,
        (b12 >> 1) & 0x6,
        (b12 << 1) & 0x6,
        (b13 >> 5) & 0x6,
        (b13 >> 3) & 0x6,
    ];
    (0..6)
        .map(|i| {
            let high = (p[i] as i64) << 3;
            let low = (p[6 + i] as i64) & 0x1;
            high | mid[i] | low
        })
        .collect()
}

/// avg SpO2 percent from a 0x6f payload: header byte + per-sample percents,
/// optional 0xff terminator
pub fn spo2_average(p: &[u8]) -> Option<i64> {
    if p.is_empty() {
        return None;
    }
    let end = if p.len() > 1 && p[p.len() - 1] == 0xff {
        p.len() - 1
    } else {
        p.len()
    };
    if end <= 1 {
        return None;
    }
    let samples = &p[1..end];
    let sum: i64 = samples.iter().map(|&b| b as i64).sum();
    Some(sum / samples.len() as i64)
}

/// current HRV pair (hr_bpm, rmssd_ms) from a 0x5d payload, the last (most
/// recent) 5-minute window
pub fn hrv_current(p: &[u8]) -> Option<(i64, i64)> {
    let n = p.len();
    if n < 2 || n > 12 || n % 2 != 0 {
        return None;
    }
    let last = n - 2;
    Some((p[last] as i64, p[last + 1] as i64))
}

/// primary skin temp (C) from a 0x46 payload, channel 1 (temp1_c).
/// None when channel is the missing-sentinel
pub fn temp_primary_c(p: &[u8]) -> Option<f64> {
    if p.len() < 2 {
        return None;
    }
    let raw = (p[0] as i64) | ((p[1] as i64) << 8); // channel 1 unsigned
    let v = raw as f64 / 100.0;
    if (v - (-327.68)).abs() < f64::EPSILON {
        None
    } else {
        Some(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hr_from_ibis_median() {
        // IBIs ~857ms ~= 70 bpm
        let ibis = [857, 860, 855, 5000 /* filtered out */];
        let hr = hr_from_ibis(&ibis).unwrap();
        assert!((hr - 70.0).abs() < 1.5, "hr={hr}");
    }

    #[test]
    fn green_filter_keeps_quality_zero() {
        // sample0 low=0x84 high=0x00 -> qa=0 qb=0 kept, value=(0x84<<3)|0=1056
        // sample1 qb set -> dropped
        let p = [0x84, 0x00, 0x10, 0x20];
        let out = green_ibi_filtered(&p);
        assert_eq!(out, vec![1056]);
    }

    #[test]
    fn spo2_avg() {
        let p = [0x68, 93, 95, 94, 0xff];
        assert_eq!(spo2_average(&p), Some(94));
    }

    #[test]
    fn hrv_takes_last_pair() {
        let p = [60, 42, 58, 40];
        assert_eq!(hrv_current(&p), Some((58, 40)));
    }

    #[test]
    fn temp_primary() {
        let p = [0xc4, 0x09]; // 2500/100 = 25.0c
        assert_eq!(temp_primary_c(&p), Some(25.0));
    }
}
