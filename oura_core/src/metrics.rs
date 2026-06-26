//! derived scores on top of [`crate::health`] signals.
//!
//! [`crate::health`] gives one instant value per record; this turns aggregates
//! (a day of HR, a night of RMSSD, a baseline) into Strain (0-21), Recovery
//! (0-100), resting HR, HRV baseline, VO2max, sleep score.
//!
//! pure functions of inputs (no clock/IO), identical on every platform.
//!
//! formulas are published / community-RE methods, not Oura's proprietary
//! weights (unpublished). computed over the
//! user's own ring data, not bit-exact vendor parity

/// natural log that maps non-positive input to ln(tiny epsilon) so a zero load
/// never yields -inf/NaN
fn ln_safe(x: f64) -> f64 {
    if x > 0.0 {
        x.ln()
    } else {
        f64::MIN_POSITIVE.ln()
    }
}

fn clamp(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

fn mean(xs: &[f64]) -> Option<f64> {
    if xs.is_empty() {
        None
    } else {
        Some(xs.iter().sum::<f64>() / xs.len() as f64)
    }
}

fn std_dev(xs: &[f64]) -> Option<f64> {
    if xs.len() < 2 {
        return None;
    }
    let m = mean(xs)?;
    let var = xs.iter().map(|&x| (x - m).powi(2)).sum::<f64>() / (xs.len() as f64 - 1.0);
    Some(var.sqrt())
}

/// age-predicted max HR via Tanaka 2001: 208 - 0.7*age.
/// lower error + no sex dependence vs classic 220-age. default HRmax for strain
/// zones and VO2max ratio. source: Tanaka, Monahan & Seals, JACC 2001
pub fn hr_max_tanaka(age_years: f64) -> f64 {
    208.0 - 0.7 * age_years
}

/// resting HR from a night of samples: lowest sustained HR, approximated as a
/// low percentile (Oura "lowest resting HR"). percentile robust to outliers a
/// true minimum would catch. `percentile` in 0..=1 (0.05 = 5th)
pub fn resting_hr(hr_samples: &[f64], percentile: f64) -> Option<f64> {
    if hr_samples.is_empty() {
        return None;
    }
    let mut s: Vec<f64> = hr_samples.iter().copied().filter(|v| v.is_finite()).collect();
    if s.is_empty() {
        return None;
    }
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p = clamp(percentile, 0.0, 1.0);
    let idx = ((s.len() - 1) as f64 * p).round() as usize;
    Some(s[idx])
}

/// Edwards 5-zone TRIMP denominator mapping a full day at top zone to scale
/// top: zone-5 weight 5 * 1440 min = 7200, +1 = 7201 so ln(7201)/ln(7201)=1.
/// Edwards TRIMP, standard exercise-physiology method
pub const STRAIN_DENOMINATOR: f64 = 7201.0;

pub const STRAIN_MAX: f64 = 21.0;

/// one HR sample with the wall-clock duration it covers (minutes)
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HrSample {
    pub bpm: f64,
    pub minutes: f64,
}

/// Edwards TRIMP from HR-over-time, Karvonen %HRR assigns each sample a 1-5 zone.
/// zone weights by %HRR: >=90->5, >=80->4, >=70->3, >=60->2, >=50->1, else 0;
/// sample contributes zone_weight * minutes. source: Edwards 1993, Karvonen HRR
pub fn edwards_trimp(samples: &[HrSample], hr_max: f64, hr_rest: f64) -> f64 {
    let denom = (hr_max - hr_rest).max(1.0);
    samples
        .iter()
        .map(|s| {
            let pct = clamp((s.bpm - hr_rest) / denom * 100.0, 0.0, 100.0);
            let w = if pct >= 90.0 {
                5.0
            } else if pct >= 80.0 {
                4.0
            } else if pct >= 70.0 {
                3.0
            } else if pct >= 60.0 {
                2.0
            } else if pct >= 50.0 {
                1.0
            } else {
                0.0
            };
            w * s.minutes.max(0.0)
        })
        .sum()
}

/// log-compress a TRIMP load to 0-21 strain: 21 * ln(TRIMP+1) / ln(7201).
/// 18->19 costs far more load than 10->11. loads are additive before the
/// transform, sum TRIMP then call once, never add resulting strains.
/// source: `NoopApp/noop` (`StrainScorer.swift`)
pub fn strain_from_trimp(trimp: f64) -> f64 {
    clamp(
        STRAIN_MAX * ln_safe(trimp + 1.0) / STRAIN_DENOMINATOR.ln(),
        0.0,
        STRAIN_MAX,
    )
}

/// HR-over-time -> 0-21 strain in one call (Edwards TRIMP then log transform)
pub fn strain(samples: &[HrSample], hr_max: f64, hr_rest: f64) -> f64 {
    strain_from_trimp(edwards_trimp(samples, hr_max, hr_rest))
}

/// RMSSD (ms) from IBIs: root-mean-square of successive diffs, the vagal-tone
/// HRV metric. RMSSD = sqrt(mean((RR[i+1]-RR[i])^2)), None for <2 intervals.
/// source: Task Force 1996 / Shaffer & Ginsberg 2017
pub fn rmssd(ibi_ms: &[f64]) -> Option<f64> {
    if ibi_ms.len() < 2 {
        return None;
    }
    let mut sum_sq = 0.0;
    for w in ibi_ms.windows(2) {
        let d = w[1] - w[0];
        sum_sq += d * d;
    }
    Some((sum_sq / (ibi_ms.len() - 1) as f64).sqrt())
}

/// personal HRV baseline from recent nightly RMSSD.
/// judged against your own rolling baseline not a population norm. carries mean
/// + SD of lnRMSSD (RMSSD right-skewed, ln normalizes it) + day-to-day CV
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HrvBaseline {
    /// mean of ln(RMSSD) over the window
    pub mean_ln: f64,
    /// SD of ln(RMSSD), 0.0 if <2 samples
    pub sd_ln: f64,
    /// coefficient of variation of RMSSD (%), autonomic stability, lower steadier
    pub cv_pct: f64,
    /// nights in the baseline
    pub n: usize,
}

/// [`HrvBaseline`] from nightly RMSSD (order irrelevant), None if no positive
/// samples. window (e.g. last 10-14 nights) is the caller's slice.
/// source: Elite-HRV / HRV4Training rolling baseline
pub fn hrv_baseline(nightly_rmssd: &[f64]) -> Option<HrvBaseline> {
    let valid: Vec<f64> = nightly_rmssd
        .iter()
        .copied()
        .filter(|v| v.is_finite() && *v > 0.0)
        .collect();
    if valid.is_empty() {
        return None;
    }
    let lns: Vec<f64> = valid.iter().map(|&v| v.ln()).collect();
    let mean_ln = mean(&lns)?;
    let sd_ln = std_dev(&lns).unwrap_or(0.0);
    let raw_mean = mean(&valid)?;
    let raw_sd = std_dev(&valid).unwrap_or(0.0);
    let cv_pct = if raw_mean > 0.0 {
        raw_sd / raw_mean * 100.0
    } else {
        0.0
    };
    Some(HrvBaseline {
        mean_ln,
        sd_ln,
        cv_pct,
        n: valid.len(),
    })
}

/// tonight's RMSSD -> 0-100 sub-score vs personal baseline via z-score of
/// lnRMSSD: baseline -> 50, +1 SD -> ~75, -1 SD -> ~25. no spread yet (sd~0 or
/// single night) falls back to a ratio around baseline mean
pub fn hrv_score(tonight_rmssd: f64, baseline: &HrvBaseline) -> f64 {
    if !(tonight_rmssd.is_finite() && tonight_rmssd > 0.0) {
        return 0.0;
    }
    let ln = tonight_rmssd.ln();
    if baseline.sd_ln > 0.05 && baseline.n >= 3 {
        let z = (ln - baseline.mean_ln) / baseline.sd_ln;
        clamp(50.0 + z * 25.0, 0.0, 100.0)
    } else {
        // no spread for a z-score: ratio vs baseline mean, ±50% -> ±50pts
        let ratio = (ln - baseline.mean_ln) / baseline.mean_ln.abs().max(0.01);
        clamp(50.0 + ratio * 100.0, 0.0, 100.0)
    }
}

/// nightly inputs to recovery, each reduced to a representative nightly value
/// (sampled from deep/SWS where autonomic state is most stable)
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RecoveryInputs {
    /// tonight's RMSSD (ms), dominant driver
    pub rmssd_ms: Option<f64>,
    /// tonight's resting HR (bpm), lower than baseline is good
    pub resting_hr: Option<f64>,
    /// tonight's respiratory rate (br/min), elevation vs baseline is bad
    pub respiratory_rate: Option<f64>,
    /// sleep performance 0-100 (slept / needed), lower weight
    pub sleep_performance: Option<f64>,
}

/// personal baselines recovery normalizes each input against
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryBaselines {
    pub hrv: HrvBaseline,
    /// mean resting HR over the window (bpm)
    pub resting_hr_mean: Option<f64>,
    /// mean respiratory rate over the window (br/min)
    pub respiratory_rate_mean: Option<f64>,
}

/// default recovery component weights.
/// vendor weights are unpublished, community estimate ~70/20/10 HRV/RHR/sleep,
/// we add a small RR term (adds signal independent of HRV/RHR/sleep). weights
/// renormalize over present components so a missing input never zeroes the score
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryWeights {
    pub hrv: f64,
    pub resting_hr: f64,
    pub respiratory_rate: f64,
    pub sleep: f64,
}

impl Default for RecoveryWeights {
    fn default() -> Self {
        RecoveryWeights {
            hrv: 0.60,
            resting_hr: 0.20,
            respiratory_rate: 0.08,
            sleep: 0.12,
        }
    }
}

/// recovery score + per-component sub-scores so the UI can show why
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Recovery {
    /// overall 0-100 recovery (green >=67, yellow 34-66, red <34)
    pub score: f64,
    pub hrv_score: Option<f64>,
    pub resting_hr_score: Option<f64>,
    pub respiratory_rate_score: Option<f64>,
    pub sleep_score: Option<f64>,
}

/// resting-HR sub-score (0-100) vs baseline: baseline -> 50, each bpm below
/// baseline adds points (lower RHR better), ±10 bpm spans the range
fn rhr_score(tonight: f64, baseline_mean: Option<f64>) -> Option<f64> {
    let base = baseline_mean?;
    let delta = base - tonight;
    Some(clamp(50.0 + delta * 5.0, 0.0, 100.0))
}

/// respiratory-rate sub-score (0-100) vs baseline: baseline -> 50, elevation
/// penalized (raised overnight RR is an early strain/illness marker), ±4
/// br/min spans the range
fn rr_score(tonight: f64, baseline_mean: Option<f64>) -> Option<f64> {
    let base = baseline_mean?;
    let delta = base - tonight;
    Some(clamp(50.0 + delta * 12.5, 0.0, 100.0))
}

/// recovery score from tonight's inputs, baselines, weights. HRV-dominant,
/// weights renormalize over present components so partial nights still score
pub fn recovery(
    inputs: &RecoveryInputs,
    baselines: &RecoveryBaselines,
    weights: &RecoveryWeights,
) -> Recovery {
    let hrv_s = inputs.rmssd_ms.map(|r| hrv_score(r, &baselines.hrv));
    let rhr_s = inputs
        .resting_hr
        .and_then(|h| rhr_score(h, baselines.resting_hr_mean));
    let rr_s = inputs
        .respiratory_rate
        .and_then(|r| rr_score(r, baselines.respiratory_rate_mean));
    let sleep_s = inputs.sleep_performance.map(|s| clamp(s, 0.0, 100.0));

    let mut total_w = 0.0;
    let mut acc = 0.0;
    let mut add = |sub: Option<f64>, w: f64| {
        if let Some(v) = sub {
            acc += v * w;
            total_w += w;
        }
    };
    add(hrv_s, weights.hrv);
    add(rhr_s, weights.resting_hr);
    add(rr_s, weights.respiratory_rate);
    add(sleep_s, weights.sleep);

    let score = if total_w > 0.0 {
        clamp(acc / total_w, 0.0, 100.0)
    } else {
        0.0
    };
    Recovery {
        score,
        hrv_score: hrv_s,
        resting_hr_score: rhr_s,
        respiratory_rate_score: rr_s,
        sleep_score: sleep_s,
    }
}

/// non-exercise VO2max from HRmax/HRrest ratio (Uth-Sorensen-Overgaard-Pedersen
/// 2004): VO2max ~= 15 * (HRmax/HRrest) mL/kg/min.
/// zero-effort tier from resting HR + HRmax estimate; HRmax is the dominant
/// error source so prefer an observed max. source: Uth et al. 2004
pub fn vo2max_hr_ratio(hr_max: f64, hr_rest: f64) -> Option<f64> {
    if hr_rest <= 0.0 || hr_max <= 0.0 {
        return None;
    }
    Some(15.0 * (hr_max / hr_rest))
}

/// per-night sleep facts a score is composed from, durations in minutes. any
/// field None (sub-component skipped, weights renormalize). from ring sleep
/// records (`0x6a` stage info, `0x76` bedtime period, HR/temp coverage)
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct SleepInputs {
    /// time asleep (min)
    pub total_sleep_min: Option<f64>,
    /// time in bed (min), for efficiency
    pub time_in_bed_min: Option<f64>,
    /// REM (min)
    pub rem_min: Option<f64>,
    /// deep / slow-wave (min)
    pub deep_min: Option<f64>,
    /// sleep-onset latency (min)
    pub latency_min: Option<f64>,
    /// awakenings / disturbances, for restfulness
    pub awakenings: Option<u32>,
    /// sleep-midpoint local hour (0-24 fractional) for timing
    pub midpoint_hour: Option<f64>,
}

/// sleep score + sub-components for a why breakdown
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SleepScore {
    pub score: f64,
    pub duration: Option<f64>,
    pub efficiency: Option<f64>,
    pub rem: Option<f64>,
    pub deep: Option<f64>,
    pub latency: Option<f64>,
    pub restfulness: Option<f64>,
    pub timing: Option<f64>,
}

/// triangular score (0-100) peaking at `ideal`, 0 at ±span
fn peak_score(value: f64, ideal: f64, span: f64) -> f64 {
    if span <= 0.0 {
        return 0.0;
    }
    clamp(100.0 * (1.0 - (value - ideal).abs() / span), 0.0, 100.0)
}

/// ramp score (0-100): 0 at `floor`, 100 at `target`+. for more-is-better
/// components (duration, REM, deep)
fn ramp_score(value: f64, floor: f64, target: f64) -> f64 {
    if target <= floor {
        return if value >= target { 100.0 } else { 0.0 };
    }
    clamp((value - floor) / (target - floor) * 100.0, 0.0, 100.0)
}

/// 0-100 sleep score from a night's facts, target ranges from sleep literature:
/// - duration: ramp to 7h (420 min) full marks
/// - efficiency: ramp, 85%+ full marks (Oura benchmark)
/// - REM: ramp to 90 min (~20-25% of a night)
/// - deep: ramp to 75 min (~15-20%)
/// - latency: peak ~15 min, penalizes long (>20) and very short (<5, over-tired)
/// - restfulness: 0 awakenings -> 100, decaying
/// - timing: midpoint ideal 00:00-03:00, peak at 01:30
///
/// weights skew to total sleep, renormalized over present components
pub fn sleep_score(inp: &SleepInputs) -> SleepScore {
    let duration = inp.total_sleep_min.map(|m| ramp_score(m, 0.0, 420.0));
    let efficiency = match (inp.total_sleep_min, inp.time_in_bed_min) {
        (Some(asleep), Some(bed)) if bed > 0.0 => {
            Some(ramp_score(asleep / bed * 100.0, 50.0, 85.0))
        }
        _ => None,
    };
    let rem = inp.rem_min.map(|m| ramp_score(m, 0.0, 90.0));
    let deep = inp.deep_min.map(|m| ramp_score(m, 0.0, 75.0));
    let latency = inp.latency_min.map(|m| peak_score(m, 15.0, 30.0));
    let restfulness = inp
        .awakenings
        .map(|a| clamp(100.0 - a as f64 * 12.0, 0.0, 100.0));
    let timing = inp.midpoint_hour.map(|h| {
        // wrap so 23:00 reads as -1h relative to a 01:30 ideal
        let h = if h > 12.0 { h - 24.0 } else { h };
        peak_score(h, 1.5, 5.0)
    });

    let mut total_w = 0.0;
    let mut acc = 0.0;
    let mut add = |sub: Option<f64>, w: f64| {
        if let Some(v) = sub {
            acc += v * w;
            total_w += w;
        }
    };
    add(duration, 0.30);
    add(efficiency, 0.18);
    add(rem, 0.12);
    add(deep, 0.14);
    add(latency, 0.10);
    add(restfulness, 0.10);
    add(timing, 0.06);

    let score = if total_w > 0.0 {
        clamp(acc / total_w, 0.0, 100.0)
    } else {
        0.0
    };
    SleepScore {
        score,
        duration,
        efficiency,
        rem,
        deep,
        latency,
        restfulness,
        timing,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    #[test]
    fn tanaka_hr_max() {
        assert!(approx(hr_max_tanaka(30.0), 187.0, 0.01));
    }

    #[test]
    fn resting_hr_low_percentile() {
        let hrs: Vec<f64> = (50..=90).map(|x| x as f64).collect();
        // 5th percentile of 50..90 near the low end
        let r = resting_hr(&hrs, 0.05).unwrap();
        assert!(r <= 55.0, "r={r}");
    }

    #[test]
    fn strain_zero_load_is_zero() {
        assert!(approx(strain_from_trimp(0.0), 0.0, 1e-9));
    }

    #[test]
    fn strain_full_day_top_zone_is_max() {
        // 1440 min at zone 5 = TRIMP 7200 -> strain ~= 21
        assert!(approx(strain_from_trimp(7200.0), 21.0, 0.01));
    }

    #[test]
    fn strain_is_logarithmic() {
        // same load increment adds less strain higher up the curve
        // (10->510 vs 5000->5500)
        let low_gain = strain_from_trimp(510.0) - strain_from_trimp(10.0);
        let high_gain = strain_from_trimp(5500.0) - strain_from_trimp(5000.0);
        assert!(low_gain > high_gain, "low={low_gain} high={high_gain}");
    }

    #[test]
    fn edwards_zones_weight_correctly() {
        // hr_rest=60 hr_max=180 -> reserve 120. 90%HRR = 60 + 0.9*120 = 168
        let s = [HrSample { bpm: 168.0, minutes: 10.0 }]; // zone 5 (w=5)
        assert!(approx(edwards_trimp(&s, 180.0, 60.0), 50.0, 0.01));
        // 50%HRR = 120 -> zone 1 (w=1)
        let s2 = [HrSample { bpm: 120.0, minutes: 10.0 }];
        assert!(approx(edwards_trimp(&s2, 180.0, 60.0), 10.0, 0.01));
        // below 50% -> zone 0
        let s3 = [HrSample { bpm: 100.0, minutes: 10.0 }];
        assert!(approx(edwards_trimp(&s3, 180.0, 60.0), 0.0, 0.01));
    }

    #[test]
    fn rmssd_known_vector() {
        // RRs differ by constant 50ms -> diffs all 50 -> RMSSD=50
        let rr = [800.0, 850.0, 900.0, 950.0];
        assert!(approx(rmssd(&rr).unwrap(), 50.0, 1e-9));
    }

    #[test]
    fn hrv_baseline_and_score() {
        // stable ~50ms nights -> baseline mean_ln ~= ln(50)
        let nights = [48.0, 50.0, 52.0, 49.0, 51.0, 50.0, 50.0];
        let b = hrv_baseline(&nights).unwrap();
        assert!(approx(b.mean_ln, 50.0_f64.ln(), 0.05));
        let s_at = hrv_score(50.0, &b);
        assert!(approx(s_at, 50.0, 8.0), "s_at={s_at}");
        assert!(hrv_score(70.0, &b) > s_at);
        assert!(hrv_score(35.0, &b) < s_at);
    }

    #[test]
    fn recovery_hrv_dominant() {
        let b = hrv_baseline(&[48.0, 50.0, 52.0, 49.0, 51.0]).unwrap();
        let baselines = RecoveryBaselines {
            hrv: b,
            resting_hr_mean: Some(55.0),
            respiratory_rate_mean: Some(15.0),
        };
        let w = RecoveryWeights::default();
        let good = recovery(
            &RecoveryInputs {
                rmssd_ms: Some(72.0),
                resting_hr: Some(52.0),
                respiratory_rate: Some(14.0),
                sleep_performance: Some(90.0),
            },
            &baselines,
            &w,
        );
        let bad = recovery(
            &RecoveryInputs {
                rmssd_ms: Some(32.0),
                resting_hr: Some(60.0),
                respiratory_rate: Some(17.0),
                sleep_performance: Some(60.0),
            },
            &baselines,
            &w,
        );
        assert!(good.score > bad.score, "good={} bad={}", good.score, bad.score);
        assert!(good.score > 60.0 && bad.score < 50.0);
    }

    #[test]
    fn recovery_partial_inputs_renormalize() {
        let b = hrv_baseline(&[50.0, 50.0, 50.0]).unwrap();
        let baselines = RecoveryBaselines {
            hrv: b,
            resting_hr_mean: None,
            respiratory_rate_mean: None,
        };
        // only HRV present -> score is the HRV sub-score
        let r = recovery(
            &RecoveryInputs {
                rmssd_ms: Some(50.0),
                ..Default::default()
            },
            &baselines,
            &RecoveryWeights::default(),
        );
        assert!(approx(r.score, r.hrv_score.unwrap(), 1e-6));
    }

    #[test]
    fn vo2max_ratio() {
        // HRmax 190, HRrest 50 -> 15 * 3.8 = 57
        assert!(approx(vo2max_hr_ratio(190.0, 50.0).unwrap(), 57.0, 0.01));
        assert!(vo2max_hr_ratio(190.0, 0.0).is_none());
    }

    #[test]
    fn sleep_score_good_night() {
        let s = sleep_score(&SleepInputs {
            total_sleep_min: Some(450.0), // 7.5h
            time_in_bed_min: Some(480.0), // 93.75% efficiency
            rem_min: Some(100.0),
            deep_min: Some(80.0),
            latency_min: Some(15.0),
            awakenings: Some(1),
            midpoint_hour: Some(2.0),
        });
        assert!(s.score > 85.0, "score={}", s.score);
        assert!(approx(s.duration.unwrap(), 100.0, 0.01));
    }

    #[test]
    fn sleep_score_poor_night() {
        let s = sleep_score(&SleepInputs {
            total_sleep_min: Some(240.0), // 4h
            time_in_bed_min: Some(420.0), // 57% efficiency
            rem_min: Some(20.0),
            deep_min: Some(15.0),
            latency_min: Some(75.0),
            awakenings: Some(6),
            midpoint_hour: Some(6.0), // very late
        });
        assert!(s.score < 50.0, "score={}", s.score);
    }

    #[test]
    fn sleep_latency_too_short_penalized() {
        // 0-min latency (asleep instantly = over-tired) scores below ideal
        let instant = peak_score(0.0, 15.0, 30.0);
        let ideal = peak_score(15.0, 15.0, 30.0);
        assert!(instant < ideal);
    }

    #[test]
    fn sleep_partial_inputs() {
        // only duration known -> score is the duration sub-score
        let s = sleep_score(&SleepInputs {
            total_sleep_min: Some(420.0),
            ..Default::default()
        });
        assert!(approx(s.score, 100.0, 0.01));
    }
}
