/* oura_core — C ABI for the pure-Rust Oura Ring 4 protocol decoder.
 *
 * Link the staticlib built with `cargo build --release --features cabi`
 * (`target/release/liboura_core.a`) and import this header from Swift via a
 * bridging header / module map.
 *
 * Memory ownership: any `char*` returned must be freed with
 * `oura_string_free`; any `OuraBytes` must be freed with `oura_bytes_free`.
 */
#ifndef OURA_CORE_H
#define OURA_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OuraBytes {
  uint8_t *ptr;
  size_t len;
} OuraBytes;

/* Decode every inner TLV record in one notify-char value into a JSON array
 * string (one object per record). Caller frees with oura_string_free. */
char *oura_decode_inner_records_json(const uint8_t *value, size_t len);

/* App-facing decode: each record carries framing fields + derived health
 * metrics (instant_hr_bpm, spo2_percent, hrv_*, temp_c, state_name,
 * debug_text, time_sync, step_feature_bytes) + an inspector `fields` array.
 * Returns a JSON array string. Caller frees with oura_string_free. */
char *oura_app_records_json(const uint8_t *value, size_t len);

/* Compute the 16-byte handshake proof. auth_key=16 bytes, nonce=15 bytes.
 * Returns 0 on success (writes 16 bytes into out), non-zero on bad lengths. */
int oura_handshake_proof(const uint8_t *auth_key, size_t auth_key_len,
                         const uint8_t *nonce, size_t nonce_len, uint8_t *out);

/* Extract the 16-byte auth_key from raw assa-store.realm bytes.
 * Returns 0 (writes 16 bytes to out), 1 if not found, 2 if ambiguous. */
int oura_extract_auth_key(const uint8_t *data, size_t len, uint8_t *out);

/* Canonical StateChange name for a state byte, or null if unknown.
 * Free the non-null result with oura_string_free. */
char *oura_state_change_name(uint8_t state);

/* Canonical API_* type name for an inner-record tag (falls back to
 * "UNKNOWN_0xNN"). Always non-null; free with oura_string_free. */
char *oura_type_name(uint8_t tag);

/* Control-plane frame builders. Each returns an OuraBytes the caller frees
 * with oura_bytes_free. */
OuraBytes oura_cmd_handshake_start(void);
OuraBytes oura_cmd_handshake_proof_frame(const uint8_t *auth_key,
                                         size_t auth_key_len,
                                         const uint8_t *nonce,
                                         size_t nonce_len);
OuraBytes oura_cmd_time_sync(uint8_t token, uint64_t unix_time_s);
OuraBytes oura_cmd_request_events_since(uint32_t ring_timestamp);
OuraBytes oura_cmd_request_hr_on_demand(void);

/* ring_time → UTC interpolation. Returns 0 (writes out_utc_ms) when the anchor
 * is valid, 1 otherwise. factor_flag: 0 = 100ms/tick, 1 = 1ms/tick. */
int oura_time_to_utc_ms(uint64_t anchor_ring_time, uint64_t anchor_utc_ms,
                        uint8_t factor_flag, uint32_t target_rt,
                        uint64_t *out_utc_ms);

/* Build a time anchor from a 0x42 TIME_SYNC_IND, validating ±48h vs now_ms.
 * Returns 0 (writes the three out params) when accepted, 1 when rejected. */
int oura_anchor_from_time_sync(uint32_t ring_time, int64_t ring_unix_approx_s,
                               uint8_t token, uint64_t now_ms,
                               uint64_t *out_ring_time, uint64_t *out_utc_ms,
                               uint8_t *out_factor_flag);

/* ---- Derived scores (metrics) ---------------------------------------------
 * Compound scores take a small JSON request string and return a JSON object
 * string (free with oura_string_free); scalar helpers return a double directly.
 * See cabi.rs for each request/response schema. */

/* Tanaka age-predicted max HR (208 - 0.7*age). */
double oura_hr_max_tanaka(double age_years);

/* Non-exercise VO2max estimate (15 * HRmax/HRrest); 0.0 on bad input. */
double oura_vo2max_hr_ratio(double hr_max, double hr_rest);

/* Resting HR (low percentile). req: {"hr":[..],"percentile":0.05}. */
double oura_resting_hr(const char *req_json);

/* RMSSD from IBIs. req: {"ibi":[..ms..]}. 0.0 for <2 intervals. */
double oura_rmssd(const char *req_json);

/* Day strain 0-21. req: {"bpm":[..],"minutes":[..],"hr_max":190,"hr_rest":55}. */
double oura_strain(const char *req_json);

/* Recovery 0-100 + sub-scores as JSON. req includes tonight's values and the
 * personal baselines; see cabi.rs. Caller frees with oura_string_free. */
char *oura_recovery_json(const char *req_json);

/* Sleep score 0-100 + sub-scores as JSON. req: per-night minutes/counts; see
 * cabi.rs. Caller frees with oura_string_free. */
char *oura_sleep_score_json(const char *req_json);

void oura_string_free(char *s);
void oura_bytes_free(OuraBytes b);

#ifdef __cplusplus
}
#endif

#endif /* OURA_CORE_H */
