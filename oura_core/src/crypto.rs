//! AES-128-ECB handshake proof + `auth_key` extraction.
//!
//! ring only returns data after the app handshake. from a 15-byte ring nonce
//! and 16-byte `auth_key`:
//!
//! ```text
//! proof = AES_128_ECB(auth_key, nonce || 0x01 || 0x10*16)[:16]
//! ```
//!
//! plaintext `nonce || 0x01` PKCS#5-padded to a full second block (16x 0x10),
//! ECB-encrypt, first 16 bytes of ciphertext are the proof. verified against
//! captured nonce/proof pairs

use crate::aes::aes128_ecb_encrypt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    /// `auth_key` not exactly 16 bytes
    BadAuthKeyLen(usize),
    /// `nonce` not exactly 15 bytes
    BadNonceLen(usize),
    /// `auth_key` signature not found in the realm blob
    SignatureNotFound,
    /// more than one `auth_key` candidate in the realm blob
    MultipleCandidates(usize),
}

impl core::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            CryptoError::BadAuthKeyLen(n) => write!(f, "auth_key must be 16 bytes, got {n}"),
            CryptoError::BadNonceLen(n) => write!(f, "nonce must be 15 bytes, got {n}"),
            CryptoError::SignatureNotFound => write!(f, "auth_key signature not found"),
            CryptoError::MultipleCandidates(n) => {
                write!(f, "multiple auth_key candidates found: {n}")
            }
        }
    }
}

impl std::error::Error for CryptoError {}

/// 16-byte handshake proof for `auth_key` (16 bytes) and `nonce` (15 bytes)
pub fn compute_handshake_proof(
    auth_key: &[u8],
    nonce: &[u8],
) -> Result<[u8; 16], CryptoError> {
    if auth_key.len() != 16 {
        return Err(CryptoError::BadAuthKeyLen(auth_key.len()));
    }
    if nonce.len() != 15 {
        return Err(CryptoError::BadNonceLen(nonce.len()));
    }
    let mut key = [0u8; 16];
    key.copy_from_slice(auth_key);

    // plaintext = nonce || 0x01 (16 bytes), padded = + 0x10*16 (32 bytes,
    // PKCS#5 full-block pad)
    let mut padded = [0u8; 32];
    padded[..15].copy_from_slice(nonce);
    padded[15] = 0x01;
    for b in padded[16..].iter_mut() {
        *b = 0x10;
    }

    let ct = aes128_ecb_encrypt(&key, &padded);
    let mut proof = [0u8; 16];
    proof.copy_from_slice(&ct[..16]);
    Ok(proof)
}

/// marker bytes immediately before the 16-byte `auth_key` in the Oura app's
/// `assa-store.realm`: `41 41 41 41 11 00 00 10`
pub const AUTH_KEY_SIG: [u8; 8] = [0x41, 0x41, 0x41, 0x41, 0x11, 0x00, 0x00, 0x10];

/// extract 16-byte `auth_key` from raw `assa-store.realm` bytes, err if the
/// signature is missing or ambiguous
pub fn extract_auth_key_from_realm(data: &[u8]) -> Result<[u8; 16], CryptoError> {
    let sig = &AUTH_KEY_SIG;
    let mut matches: Vec<usize> = Vec::new();
    if data.len() >= sig.len() {
        for i in 0..=(data.len() - sig.len()) {
            if &data[i..i + sig.len()] == sig.as_slice() {
                matches.push(i);
            }
        }
    }
    match matches.len() {
        0 => Err(CryptoError::SignatureNotFound),
        1 => {
            let off = matches[0] + sig.len();
            if off + 16 > data.len() {
                return Err(CryptoError::SignatureNotFound);
            }
            let mut key = [0u8; 16];
            key.copy_from_slice(&data[off..off + 16]);
            Ok(key)
        }
        n => Err(CryptoError::MultipleCandidates(n)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proof_is_deterministic_and_16_bytes() {
        let key = [0u8; 16];
        let nonce = [0u8; 15];
        let p1 = compute_handshake_proof(&key, &nonce).unwrap();
        let p2 = compute_handshake_proof(&key, &nonce).unwrap();
        assert_eq!(p1, p2);
        assert_eq!(p1.len(), 16);
    }

    #[test]
    fn proof_matches_manual_aes() {
        let key: [u8; 16] = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ];
        let nonce: [u8; 15] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
            0x0f,
        ];
        let mut padded = [0u8; 32];
        padded[..15].copy_from_slice(&nonce);
        padded[15] = 0x01;
        for b in padded[16..].iter_mut() {
            *b = 0x10;
        }
        let ct = aes128_ecb_encrypt(&key, &padded);
        let proof = compute_handshake_proof(&key, &nonce).unwrap();
        assert_eq!(&proof[..], &ct[..16]);
    }

    #[test]
    fn realm_extraction() {
        let mut blob = vec![0u8; 64];
        let key = [0xABu8; 16];
        blob.extend_from_slice(&AUTH_KEY_SIG);
        blob.extend_from_slice(&key);
        blob.extend_from_slice(&[0u8; 32]);
        assert_eq!(extract_auth_key_from_realm(&blob).unwrap(), key);
    }

    #[test]
    fn realm_extraction_missing() {
        let blob = vec![0u8; 128];
        assert_eq!(
            extract_auth_key_from_realm(&blob),
            Err(CryptoError::SignatureNotFound)
        );
    }
}
