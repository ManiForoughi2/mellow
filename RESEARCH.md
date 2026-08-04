# Oura Ring 4 BLE — research notes

Technical reference for the Oura Ring 4 BLE protocol, the live heart-rate path,
and related public reverse-engineering work. Mellow's protocol logic is its own
Rust crate (`oura_core`) and does not depend on any external project; the
references below are comparison points.

## Live heart rate

Live heart rate is controlled by the `0x2F` Feature API rather than the record
subscription.

The official app's start sequence is now known from a capture of it running on
a second ring, against measurements the wearer labelled by hand
([EXTERNAL_CAPTURE_FINDINGS.md](EXTERNAL_CAPTURE_FINDINGS.md)). It is **two writes**:

```
2f 03 22 02 03     Daytime-HR mode = 3 (requested-subscription / burst)
2f 03 26 02 02     Daytime-HR subscription = 2 (Latest)
```

and to stop, mode = 1 and subscription = 0. The ring also reverts on its own
after about 20 seconds, so a held measurement needs re-triggering roughly every
15.

This project previously prefixed the sequence with `2f 02 20 02` (get feature
status). **The app does not do that.** It sweeps feature status once per
connection, over `0x12, 0x0c, 0x0b, 0x04, 0x10`, unrelated to starting a
measurement. The prefix has been removed.

Once running, the ring emits parameter pushes:

```
2f 0f 28 02 <quality> 02 00 00 <ibi:u16le> 00 00 00 00 12 0a 7f
```

**The IBI unit is 0.2 ms.** Two captures the wearer labelled 58 bpm decode to
58.5 and 58.2 bpm at that scale; 0.25 ms gives 46.8 and 46.6 and is excluded.
`quality` is `0x09` clean, `0x19` suspect. See `decode_dhr_param_push`.

### What this does and does not settle

The captured ring was onboarded by the official app, so this does not directly
test a self-provisioned one. It does dispose of one theory: the app does
strictly *less* than this project did, so failure on a self-provisioned ring was
never caused by a missing step in the start sequence.

`0x20 Set User Info`, previously the leading hypothesis for a gate, **never
appears in any of the five captures.** The complete set of phone-to-ring opcodes
observed is `0x01 0x02 0x08 0x0c 0x10 0x12 0x16 0x18 0x1c 0x28 0x2f`. A fuller
onboarding therefore looks unlikely to be the missing ingredient.

The remaining live hypothesis is wear-state gating. A feature-subscription
failure of `0x03` means "not in finger"; status values also cover searching, no
reliable PPG, cold fingers and too much movement. Read feature status and the
`0x45` / `0x53` state events before assuming a protocol error.

## Ring clock

The time exchange is `12 09 <phone_epoch:u32le> 00 00 00 00 06`, answered with
`13 05 <ring_clock:u32le> 00`. Across 35 exchanges in one capture the ring
counter advances about **ten ticks per wall-clock second**: record timestamps
are deciseconds, not seconds. Reading them as seconds inflates every interval
tenfold. The epoch offset is per-ring and recovered from the exchange itself.

## Feature API reference

Transport: channel `0x0004`, write handle `0x0015`, notify handle `0x0012`, LE.

`0x2F` sub-ops: `0x20` get feature status, `0x21` status response, `0x22` set
feature mode (byte 0), `0x26` set feature subscription (byte 2), `0x28` parameter
push.

Feature IDs: `0x02` Daytime HR, `0x03` Exercise HR, `0x04` SpO2, `0x08` Resting
HR, `0x0B` Real steps, `0x0D` CVA raw PPG sampler.

Modes (byte 0): 0 off, 1 automatic, 2 requested, 3 requested-subscription / burst,
4 burst. Subscription (byte 2): 0 off, 1 state, 2 latest.

`0x31 Set Ring Mode` with `0x01` selects fast heart-rate measurement.

Live records, once active: `0x60` IBI with amplitude, `0x80` green IBI quality
(11-bit field is the IBI in ms), `0x81` raw 24-bit PPG, `0x46` temperature,
`0x6E` / `0x6F` / `0x77` SpO2, `0x45` / `0x53` state and wear events.

Hardware: the Ring 4 uses a MAX86178F analog front end and an Infineon PSoC 6,
with a green LED at roughly 50 Hz for heart rate. The official live-HR path
requires the ring worn palm-side, still for about 10 seconds, on warm skin.

## Sleep staging is not on the wire

The ring does not transmit a deep/light/REM/awake byte, and the evidence is now
direct rather than inferred.

`0x72 API_SLEEP_ACM_PERIOD` is the 30-second epoch record, arriving at exactly
300 ring ticks. Aligning 1146 of them against a labelled 30-second hypnogram
exported from an Oura account for the same night gives medians of awake
60/115/49, deep 14/27/13, light 15/30/14 and rem 21/41/19 on the first three
u16 fields. Wake separates decisively; deep and light are nearly identical.
That is a movement record.

The account export for the same night reports
`sleep_algorithm_version = v2` and
`sleep_analysis_reason = foreground_sleep_analysis`: the staging runs in the
app, from motion, IBI and temperature.

`0x6a SleepPeriodInfo`, which carries the coarse three-state `sleep_state` this
project decodes, **does not appear once in that capture**, while `0x69` and
`0x6b` both do at 30- and 26-minute cadence. It cannot be relied on as the
staging source.

The same pattern holds for steps. `0x7e` / `0x7f`
(`API_REAL_STEP_EVENT_FEATURE_ONE` / `_TWO`) carry 14 bytes of high-entropy data
at 30-second cadence and no step total; the app polls feature `0x0b`
(Real steps) and gets `01 01 02 00`. Two walks the wearer counted at 58 and 65
steps produced no field tracking either number.

The consistent picture is that the ring exports **features** and the phone runs
the classifier, for both staging and step counting. Reproducing either means
training a model, not finding a byte. A labelled night of aligned epochs plus
per-5-minute HR and HRV is the dataset for the sleep half of that.

## Prior art

- `ringverse/protocol` (https://github.com/ringverse/protocol/blob/main/oura/BLE.md):
  the most complete public Oura Ring 4 BLE specification, covering the opcodes, the
  event-tag enum, the Feature API, and the auth handshake.
- `LogosIsLife/open_ring` (https://github.com/LogosIsLife/open_ring): a clean-room
  Python driver and protocol document for the Ring 4, validated against a large
  capture corpus.
- `EIrno/Cracked-Oura` (https://github.com/EIrno/Cracked-Oura): a local viewer for
  Oura's GDPR data export. It does not use BLE and does not read the ring directly.

Unlike some fitness bands, the ring exposes no standard Bluetooth Heart Rate
Service; all data is behind the authenticated proprietary service, so the
standard-service shortcut does not apply here.

## Adjacent references

The Colmi R02 / R03 rings are fully open with no authentication
(`tahnok/colmi_r02_client`) and are a useful reference for capture-and-dissect
technique.
