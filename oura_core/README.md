# oura_core

A pure-Rust, dependency-free, read-only decoder for the **Oura Ring 4** BLE
wire protocol. This is the portable protocol core for the Mellow app: it owns
everything that is platform-independent so the same byte-exact logic runs on
iOS, the command line, and in tests.

It is **clock-, RNG-, and I/O-free** — the host supplies nonces, timestamps,
and "now", and handles BLE transport and persistence. That keeps the core
deterministic and trivially unit-testable.

## Modules

| Module        | Responsibility                                                         |
|---------------|------------------------------------------------------------------------|
| `aes`         | AES-128-ECB block encryption (the one primitive the handshake needs).  |
| `crypto`      | Handshake proof + `auth_key` extraction from `assa-store.realm`.       |
| `framing`     | Outer-frame and inner-TLV parsers; `ring_time` reconstruction.         |
| `enums`       | Canonical `API_*` / state-change / motion-state names.                 |
| `decoders`    | Every per-type wire decoder + the `0x61` debug-data sub-decoders.      |
| `sync_state`  | Delta-resume cursor + `ring_time → UTC` anchor math.                   |
| `commands`    | Control-plane frame builders (handshake, time-sync, param RPC, etc.).  |
| `state`       | Ring-side state machine driven by the decoded record stream.           |
| `value`       | A small JSON-like value/map type the decoders emit.                    |
| `cabi`        | (feature `cabi`) C ABI for embedding into the Swift app.               |

## Build

```sh
cargo test --all-features          # unit + cross-language parity tests
cargo build --release --features cabi   # produces target/release/liboura_core.a
```

`tests/parity.rs` pins the decoders to byte-identical output against the
original reference implementation's known vectors.

## Embedding in iOS

Link `liboura_core.a` and import [`include/oura_core.h`](include/oura_core.h)
through a bridging header. The header exposes `oura_decode_inner_records_json`
(value bytes → JSON), the handshake proof / key-extraction calls, and the
common command builders. See the header for ownership rules.

## Provenance & license

This is an independent Rust reimplementation of the Oura Ring 4 BLE protocol
based on our own captured-traffic analysis. The protocol derives from
clean-room reverse-engineering and the project is distributed under
**GPL-3.0-or-later**. For personal interoperability with a ring you own.
