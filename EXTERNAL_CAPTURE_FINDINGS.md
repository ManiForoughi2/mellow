# Findings from the 2026-08-04 external capture set

Analysis of a PacketLogger capture set recorded by an outside contributor on a
second Ring 4 that was still paired to the official Oura app, with the account
data export for the same night as ground truth. This is the first data in the
project from a ring other than the developer's own.

Contents analysed: one full night (`Night.pklg`, 4.3 MB, 100786 HCI records),
two live-heart-rate sessions labelled 58 bpm, two walks labelled 58 and 65
steps, and the Oura API export for the same night (30-second and 5-minute
hypnograms, per-5-minute HR and HRV series, sleep and readiness summaries).

## 1. Live heart rate: resolved

The official app starts live HR with **two writes**, not three:

```
2f 03 22 02 03     set feature 0x02 (Daytime HR) mode = 3
2f 03 26 02 02     set feature 0x02 subscription = 2 (Latest)
```

`commands.rs` currently emits `2f 02 20 02` (get feature status) first. The app
never sends it before starting. It does the status get only at connection time,
as a sweep over features `0x12, 0x0c, 0x0b, 0x04, 0x10`, unrelated to starting a
measurement. To stop, the app writes mode = 1 and subscription = 0.

Records then arrive on handle `0x0012` as parameter pushes:

```
2f 0f 28 02 <st> 02 00 00 <ibi:u16le> 00 00 00 00 12 0a 7f
      |  |  |     ^ offset 4 of the payload
      |  |  feature id 0x02
      |  sub-op 0x28 (parameter push)
      length 15
```

**The IBI unit is 0.2 ms.** Decoding both labelled captures at that scale:

| capture | samples | median IBI | implied HR | label |
|---|---|---|---|---|
| `HeartRate58bpm.pklg` | 19 | 1025.1 ms | **58.5 bpm** | 58 bpm |
| `HeartRate58bpm-2.pklg` | 21 | 1030.3 ms | **58.2 bpm** | 58 bpm |

The 0.25 ms alternative yields 46.8 / 46.6 bpm and is excluded.

Payload byte 0 is a quality flag. `0x09` samples are almost all physiological
(2 of 31 outside 4000–7000 raw); `0x19` samples are frequently not (4 of 9).
Treat `0x19` as low confidence rather than discarding it outright.

**Caveat that matters.** This capture is from a ring onboarded by the official
app. It shows the exact target sequence but does not by itself disprove the
self-provisioning gate in RESEARCH.md, because the contributor's ring was never
self-provisioned. What it does establish is that the sequence is not the
problem: the app does strictly *less* than Mellow, so failure on a
self-provisioned ring is not caused by a missing step in the start sequence.

`0x20 Set User Info` — hypothesis 1 in RESEARCH.md — **is never sent by the app
in any of the five captures**. Phone-to-ring opcodes observed across the whole
set: `0x01 0x02 0x08 0x0c 0x10 0x12 0x16 0x18 0x1c 0x28 0x2f`. That weakens the
"fuller onboarding is required" theory considerably.

## 2. Ring clock runs at 10 Hz

The time exchange is:

```
-> 12 09 <phone_epoch:u32le> 00 00 00 00 06
<- 13 05 <ring_clock:u32le> 00
```

Across all 35 exchanges in the night capture, the ring counter advances about
ten ticks per wall-clock second (phone +903 s against ring +9030, +902 against
+9024, and so on). **Record timestamps are deciseconds, not seconds.** For this
capture the epoch offset is 1783047348, i.e.
`utc = 1783047348 + ticks / 10`.

Reading them as seconds inflates every interval by 10x and makes the history
stream appear to span 97 hours instead of 9.7.

## 3. Sleep stages: there is no stage byte

The 30-second epoch record is `0x72` (`API_SLEEP_ACM_PERIOD`). In the night
capture it appears 1160 times at exactly 300 ticks (30.0 s) spacing, spanning
20:44:32Z to 06:26:59Z. 1146 of those align to within 15 s of a labelled epoch
in the exported 30-second hypnogram (1152 rows).

The payload is **six little-endian u16 fields**, not the six raw bytes the
current `decode_sleep_acm_period` stub reports. Medians by labelled stage:

| field | awake | deep | light | rem |
|---|---|---|---|---|
| f0 | 60 | 14 | 15 | 21 |
| f1 | 115 | 27 | 30 | 41 |
| f2 | 49 | 13 | 14 | 19 |
| f3 | 27 | 22 | 23 | 24 |
| f4 | 38 | 28 | 29 | 32 |
| f5 | 8 | 6 | 6 | 6 |

The fields separate wake from sleep decisively and deep from light barely at
all. That is the signature of a motion record, not a classification.

Corroborating this, the account export for the same night carries
`sleep_algorithm_version = v2` and
`sleep_analysis_reason = foreground_sleep_analysis`. **Staging is computed off
the ring**, from motion, IBI and temperature.

Note on `0x6a SleepPeriodInfo`, which carries the coarse three-state
`sleep_state` this project already decodes: **it does not appear even once in
this capture.** `0x69` (22 records) and `0x6b` (24 records) are present at 30-
and 26-minute cadence, so this is a real absence rather than a framing artefact.
Whatever emits `0x6a` on the developer's ring did not emit it here, so it cannot
be relied on as the staging source. Combined with `0x72` being motion-only, a
four-stage hypnogram has to be classified rather than read.

This reframes the work: the remaining task is a classifier, not a decode. The
capture set is a usable supervised dataset for exactly that — 1146 aligned
30-second epochs with motion, plus per-5-minute HR and HRV series and the
labels, for one night.

## 4. The 0x60 IBI decoder is externally validated

Running the existing `decode_ibi_and_amplitude_event` over the night's 0x60
records yields 36486 IBI values, 35947 physiological, median **63.2 bpm**, p5
**56**, p95 80. The account export for that night reports
`average_heart_rate = 62.875` and `lowest_heart_rate = 58`.

The README lists live streaming as "only run against my ring". For the 0x60
path that is no longer true: it reproduces another person's ring against
Oura's own numbers.

## 4b. Open discrepancy in `time_sync_frame`, deliberately not changed

`commands::time_sync_frame` builds:

```
12 09 <token:1> <counter:3 LE> 00 00 00 00 f6      counter = unix_s / 256
```

Every time-set write in this capture instead looks like:

```
12 09 <unix_s:4 LE> 00 00 00 00 06
```

Concretely, `12 09 c4 f5 70 6a 00 00 00 00 06`. Read as a full little-endian
u32, `6a70f5c4` is 1785787844, which matches the capture's own wall clock to the
second. Read the current way, token `0xc4` and counter `0x6a70f5` times 256 is
1785656576, off by about a day and a half. The trailer byte also differs, `0x06`
against `0xf6`.

**This has not been changed.** The handshake and sync currently work against the
developer's ring, the difference could be firmware- or direction-specific, and
guessing wrong here breaks connection rather than one metric. It needs a
decision by someone who can test against the ring: if the current frame is a
stale reading of the same field, the fix is to write the full u32 and send
trailer `0x06`.

Note that `0x42 API_TIME_SYNC_IND`, the ring-to-phone record handled in
`lib.rs`, is a separate message and its `counter * 256` handling is not
implicated by this.

## 5. Unknowns worth naming

- **`0x8b`** is absent from `enums.rs` and is the fourth-heaviest record of the
  night: 2231 occurrences, 13-byte payload, roughly 4.6 s cadence. Sample
  payload `00 1a 55 4a 1a 32 51 1c 09 64 1a 93 8a`.
- **Feature IDs `0x10` and `0x12`** are polled by the app at connection and are
  not in the RESEARCH.md feature table. `0x10` answers `00 00 00 02`, `0x12`
  answers all zeroes.
- **Steps are still not decoded.** The app polls feature `0x0b` (Real steps) and
  gets `01 01 02 00` back, but neither walk capture was traced to a step count.
  The two walks are short (54 and 86 ATT PDUs) and may simply not contain a
  step total; the count likely rides in the periodic history rather than in a
  live record.

## 6. Suggested changes

1. `commands.rs` — drop `2f 02 20 02` from the live-HR start sequence, keeping
   only mode 3 then subscription 2, and update the assertion at
   `commands.rs:199-201`.
2. `decoders.rs` — add a decoder for the `2f .. 28 02` parameter push with IBI
   at payload offset 4, u16 LE, 0.2 ms units, and the byte-0 quality flag.
3. `decoders.rs` — replace the `decode_sleep_acm_period` stub with six named
   u16 LE fields.
4. Time handling — treat ring timestamps as deciseconds.
5. `enums.rs` — add `0x8b`, and extend the feature table with `0x10` and `0x12`.
6. `RESEARCH.md` — rewrite the live-HR section: the sequence is now known, and
   the `0x20 Set User Info` hypothesis is not supported by the captures.
7. `README.md` — the 0x60 path is no longer single-ring unverified.
