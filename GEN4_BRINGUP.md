# Connecting an Oura Ring 4

This document describes how to connect Mellow to an Oura Ring 4 and the three
independent secrets the connection requires. The protocol engine
(`oura_core`) was reverse-engineered against the Ring 4 (Gen4, firmware family
`oreo_2.10.x`).

## The three secrets

| Layer | Material | How it is established |
|---|---|---|
| Link-layer encryption | LTK | bonding (handled by the OS) |
| LE Privacy resolution | IRK | bonding (handled by the OS) |
| Application handshake | `auth_key` (16-byte AES-128) | provisioned over BLE |

The LTK and IRK are negotiated by CoreBluetooth during bonding. The `auth_key` is
the application-layer secret used by the handshake. Mellow provisions its own
`auth_key` to a factory-reset ring over BLE; see
[ENROLLMENT_FINDING.md](ENROLLMENT_FINDING.md). The key is stored in the iOS
Keychain and never leaves the device.

## Claiming the ring

A ring that has been onboarded to the official Oura app is bound to that account
and rejects other keys, returning handshake status `0x03` ("not the original
onboarded device"). To claim it with Mellow, factory-reset the ring in the Oura
app, place it on the charger, and run the claim flow. Mellow generates a 16-byte
key, writes the key-set frame, and runs the handshake. On `status 0x00` the ring
is provisioned and the key is saved.

## Bonding

The ring bonds to one central at a time. Two cases occur when a new central
connects:

- The ring accepts a new bond. iOS negotiates a fresh LTK and IRK, encryption
  comes up, and the handshake proceeds.
- The ring rejects the unknown central. The symptom is a connect followed by a
  disconnect after three to four seconds with reason `0x15` (IRK mismatch). Place
  the ring on its charger and re-add it so it bonds to the new central; the ring
  may need to be removed from the official app first.

| Symptom | Cause |
|---|---|
| Connect then disconnect after 3–4 s, reason `0x15` | IRK mismatch; a fresh bond is needed |
| Encryption Change Failed | LTK byte order |
| BLE up, handshake returns `2f 02 2e 01` | `auth_key` mismatch (wrong key) |
| BLE up, handshake returns `2f 02 2e 03` | ring is bound to an Oura account; factory-reset required |

The OS also prompts for Bluetooth permission, which must be granted or scanning
returns nothing.

## Data sync

The ring is a store-and-forward device. It records heart rate, temperature,
movement, and sleep data to its own flash on its own schedule, and the phone
downloads the stored history on connection through a cursor-based `GetEvent` loop
(cursor 0 requests the full history; the response paginates). Sleep and overnight
data are backfilled on connection rather than streamed live.

## Components

- `Mellow` (SwiftUI app): Bluetooth transport, the claim and handshake flow, the
  UI, and optional Apple Health write-through.
- `oura_core` (Rust): handshake crypto, framing, the per-record decoders, time
  resolution, and derived health metrics. The same core runs on the phone, on the
  command line, and under the test suite.

Bluetooth does not function in the iOS Simulator; the app must run on a physical
device.
