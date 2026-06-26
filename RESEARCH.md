# Oura Ring 4 BLE — research notes

Technical reference for the Oura Ring 4 BLE protocol, the live heart-rate path,
and related public reverse-engineering work. Mellow's protocol logic is its own
Rust crate (`oura_core`) and does not depend on any external project; the
references below are comparison points.

## Live heart rate

Live heart rate is controlled by the `0x2F` Feature API rather than the record
subscription. The documented sequence to force live HR is `2f 02 20 02`, then
`2f 03 22 02 03` (set Daytime-HR mode to burst), then `2f 03 26 02 02` (set
subscription to Latest), re-triggered roughly every 15 seconds because the ring
reverts after about 20.

Sending this sequence on a self-provisioned ring does not by itself produce live
HR records. The likely causes, in order:

1. Self-provisioned gating. Public references assume the ring was onboarded by the
   official app. The `24 10 <key>` self-provision path is not covered by them, and
   the firmware may withhold sensor features until a fuller onboarding (for
   example `0x20 Set User Info`).
2. Wear-state gating. A feature-subscription failure of `0x03` means "not in
   finger." Feature status values include searching, no reliable PPG, cold
   fingers, and too much movement. Reading feature status (`2f 02 20 02`) and the
   state events (`0x45` / `0x53`) shows the cause before assuming a protocol
   error.
3. Skipping the full post-handshake capability exchange can delay the ring from
   emitting some event categories.

The way to resolve the remaining gap is to capture the official app on the ring
while triggering live HR, diff its `0x2f` writes and state-event timing against
the project's, and replay the difference. Re-onboarding overwrites a
self-provisioned key, so the ring must be re-provisioned afterward.

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
standard-service shortcut does not apply here. No public project has shipped a
working live-HR-over-BLE path for the Oura ring.

## Adjacent references

The Colmi R02 / R03 rings are fully open with no authentication
(`tahnok/colmi_r02_client`) and are a useful reference for capture-and-dissect
technique.
