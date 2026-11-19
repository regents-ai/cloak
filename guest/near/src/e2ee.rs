//! NEAR AI Cloud's end-to-end encryption, version 2, for Ed25519 keys, as
//! NEAR's guide documents it (`cloud/guides/e2ee-chat-completions.mdx` in
//! github.com/nearai/docs). Each field is sealed on its own: X25519 with a
//! fresh ephemeral key against the recipient's Ed25519 key in its X25519
//! form, HKDF-SHA256 with no salt and the info `ed25519_encryption`, then
//! XChaCha20-Poly1305 with a random 24-byte nonce and no associated data. A
//! sealed field travels as hex of the ephemeral public key (32 bytes), the
//! nonce (24) and the ciphertext with its tag. Nothing is copied from NEAR's
//! code; its published vectors check this in the gate check.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use curve25519_dalek::edwards::{CompressedEdwardsY, EdwardsPoint};
use curve25519_dalek::montgomery::MontgomeryPoint;
use hkdf::Hkdf;
use sha2::Sha256;

/// What sealing adds to a field: the ephemeral key, the nonce and the tag.
const OVERHEAD: usize = 32 + 24 + 16;

/// A key fields are sealed for: an Ed25519 key, checked to be a point of the
/// curve's prime-order subgroup, in its X25519 form.
pub(crate) struct SealKey(MontgomeryPoint);

impl SealKey {
    /// None for a key that is not such a point.
    pub(crate) fn from_ed25519(key: &[u8; 32]) -> Option<SealKey> {
        let point = CompressedEdwardsY(*key).decompress()?;
        (!point.is_small_order() && point.is_torsion_free()).then(|| SealKey(point.to_montgomery()))
    }

    /// `text` sealed, as hex; None only when there is no randomness.
    pub(crate) fn seal(&self, text: &str) -> Option<String> {
        let ephemeral = crate::random::<32>()?;
        let nonce = crate::random::<24>()?;
        let cipher = XChaCha20Poly1305::new(&derive(&self.0.mul_clamped(ephemeral)));
        let sealed = cipher.encrypt(&XNonce::from(nonce), text.as_bytes()).ok()?;
        let mut out = Vec::with_capacity(OVERHEAD + text.len());
        out.extend_from_slice(MontgomeryPoint::mul_base_clamped(ephemeral).as_bytes());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&sealed);
        Some(hex::encode(out))
    }
}

/// The client's key for one request's reply: 32 secret bytes, clamped into a
/// scalar when used. A new one is made for every request, and it is never
/// printed or kept.
pub(crate) struct ReplyKey(pub(crate) [u8; 32]);

impl ReplyKey {
    /// None only when there is no randomness.
    pub(crate) fn fresh() -> Option<ReplyKey> {
        crate::random().map(ReplyKey)
    }

    /// Its public half in Ed25519 form, as `X-Client-Pub-Key` carries it;
    /// NEAR seals the reply for its X25519 form.
    pub(crate) fn public(&self) -> [u8; 32] {
        EdwardsPoint::mul_base_clamped(self.0).compress().to_bytes()
    }

    /// A field sealed for this key, opened; None when it does not open. NEAR
    /// sends an empty field as it is, so an empty string stays empty.
    pub(crate) fn open(&self, sealed: &str) -> Option<String> {
        if sealed.is_empty() {
            return Some(String::new());
        }
        let data = hex::decode(sealed).ok()?;
        if data.len() < OVERHEAD {
            return None;
        }
        let ephemeral: [u8; 32] = data[..32].try_into().ok()?;
        let shared = MontgomeryPoint(ephemeral).mul_clamped(self.0);
        if shared.as_bytes() == &[0; 32] {
            return None;
        }
        let nonce: [u8; 24] = data[32..56].try_into().ok()?;
        let text = XChaCha20Poly1305::new(&derive(&shared))
            .decrypt(&XNonce::from(nonce), &data[56..])
            .ok()?;
        String::from_utf8(text).ok()
    }
}

/// The field key: HKDF-SHA256 of the shared secret, no salt.
fn derive(shared: &MontgomeryPoint) -> Key {
    let mut key = Key::default();
    Hkdf::<Sha256>::new(None, shared.as_bytes())
        .expand(b"ed25519_encryption", &mut key)
        .expect("32 bytes is a length HKDF-SHA256 gives");
    key
}
