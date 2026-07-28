#ifndef STATION_CRYPTO_H
#define STATION_CRYPTO_H

#include <QByteArray>
#include <QString>

// Private-stream crypto (booth#66 / receiver#69).
//
// This file is BYTE-IDENTICAL in booth-basecamp and receiver-basecamp: the broadcaster and the
// listener MUST derive the same topic + key from the same (Title, Pass) or a private stream can't
// be found or decoded. Any change here must be mirrored in the sibling repo and re-checked against
// the golden vectors in selfTest(). Canonical spec: docs/private-stream-protocol.md.
//
// Approved primitive suite (Phase-1 human sign-off):
//   - Topic derivation: SHA-256 (QCryptographicHash) over canonical compact-JSON of (Title, Pass).
//   - Key derivation:   Argon2id (libsodium crypto_pwhash) — memory-hard, resists offline brute
//                       force of a weak passphrase.
//   - Payload AEAD:     XChaCha20-Poly1305 (libsodium) — 192-bit random nonce, no counter state.
// secp256k1 stays the ANNOUNCE-signature primitive (sign-then-encrypt); it is not used here.
namespace StationCrypto {

// Wraps sodium_init(). Call once before any other function; idempotent. false ⇒ libsodium failed.
bool init();

// Full private topic:  /radio-basecamp/1/<seg>/json   where seg = base32(SHA-256(canon(Title,Pass))[:16]).
QString deriveTopic(const QString& title, const QString& pass);
// Just the 26-char base32 <seg> (also used as AEAD associated data). See spec §3.2.
QString deriveTopicSegment(const QString& title, const QString& pass);

// 32-byte AEAD key from Pass via Argon2id + a deterministic Title-salt. Empty on failure (OOM). §4.2.
QByteArray deriveKey(const QString& title, const QString& pass);

// Encrypt plaintext → the {pv,enc,n,ct} envelope JSON (fresh random 192-bit nonce). §4.3.
QString encryptAnnounce(const QByteArray& key, const QByteArray& plaintext, const QString& topicSegment);
// Deterministic variant for golden test vectors — caller supplies the 24-byte nonce.
QString encryptAnnounceWithNonce(const QByteArray& key, const QByteArray& plaintext,
                                 const QString& topicSegment, const QByteArray& nonce24);

// Decrypt a {pv,enc,n,ct} envelope. true + fills out on success; false on ANY failure (wrong key,
// tamper, wrong topic/AAD, malformed, unknown suite) — fail closed. §4/§6.
bool decryptAnnounce(const QByteArray& key, const QString& envelopeJson,
                     const QString& topicSegment, QByteArray& out);

// true if a decoded delivery payload is an encrypted envelope (top-level pv+enc) vs a plaintext announce.
bool isEnvelope(const QString& payloadJson);

// derive→encrypt→decrypt round-trip + wrong-pass/tamper/wrong-topic negatives + golden cross-impl
// vectors (topic + key + deterministic ciphertext). true iff all pass. §7 — the cheapest real proof.
bool selfTest();

} // namespace StationCrypto

#endif // STATION_CRYPTO_H
