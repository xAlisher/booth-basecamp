#ifndef STATION_IDENTITY_H
#define STATION_IDENTITY_H

#include <QByteArray>
#include <QString>

// secp256k1 station identity (epic radio#24 / receiver#13 / receiver#46).
//
// Autogen tier: load-or-create a persistent keypair; sign the announce so listeners can verify the
// station is the same host across name/onion changes and reject impostors. The SAME sign/verify math
// runs on the receiver side (verify only) — keep the canonical-bytes + digest scheme byte-identical
// (see docs/design/station-identity-v2.md). Stage 3 (Keycard) reuses signHex; only the seckey source
// changes (deriveKey("bc:radio")).
class StationIdentity {
public:
    // Load the 32-byte secp256k1 private key from keyPath (hex); generate + persist (0600) if absent.
    // Returns false on any crypto/IO failure (caller falls back to the anonymous/unsigned tier).
    bool loadOrCreate(const QString& keyPath);

    bool    isValid()   const { return m_valid; }
    QString pubkeyHex() const { return m_pubHex; }   // 33-byte COMPRESSED pubkey, lowercase hex (66 chars)

    // #24 Stage 3 — seed the identity from a 32-byte hex private key (e.g. keycard deriveKey), in memory
    // only (NOT persisted — the card re-derives it deterministically each session). false on bad input.
    bool fromSeckeyHex(const QString& seckeyHex);

    // ECDSA-secp256k1 signature over SHA-256(msg), as 64-byte compact lowercase hex. "" on failure.
    QString signHex(const QByteArray& msg) const;

    // Verify a compact-hex sig against a compressed-pubkey-hex over SHA-256(msg). Pure/static (receiver side).
    static bool verify(const QString& pubkeyHex, const QString& sigHex, const QByteArray& msg);

    // 3-word PGP-biometric fingerprint of a compressed-pubkey-hex (SHA-256 → first 3 bytes → words).
    // Same word tables compiled into radio + receiver, or fingerprints diverge. "" on bad input.
    static QString fingerprint(const QString& pubkeyHex);

    // keygen → sign → verify round-trip on a fixed vector. Proves the lib links + works at runtime.
    static bool selfTest();

private:
    bool       m_valid = false;
    QByteArray m_seckey;   // 32 bytes (kept in memory only; never logged)
    QString    m_pubHex;
};

#endif // STATION_IDENTITY_H
