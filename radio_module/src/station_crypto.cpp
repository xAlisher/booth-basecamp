#include "station_crypto.h"

#include <sodium.h>

#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>

// See station_crypto.h — this file is BYTE-IDENTICAL across booth-basecamp and receiver-basecamp.
namespace StationCrypto {
namespace {

// Domain separators — versioned so a future scheme change is a new tag, never a silent divergence.
constexpr char kTopicDomain[] = "radio-basecamp/private-topic/v1";
constexpr char kKdfDomain[]   = "radio-basecamp/private-kdf/v1";
constexpr char kEncSuite[]    = "xchacha20poly1305-argon2id";
constexpr int  kPayloadVer    = 1;                 // envelope "pv"
constexpr int  kTopicTruncBytes = 16;              // 128-bit topic segment

// Argon2id cost — pinned into the wire contract (both ends + any port MUST use these exact numbers).
// = libsodium crypto_pwhash INTERACTIVE profile: opslimit 2, memlimit 67108864 (64 MiB), ARGON2ID13.
const unsigned long long kOpsLimit = crypto_pwhash_OPSLIMIT_INTERACTIVE;   // 2
const size_t             kMemLimit = crypto_pwhash_MEMLIMIT_INTERACTIVE;   // 67108864

QByteArray sha256(const QByteArray& m) { return QCryptographicHash::hash(m, QCryptographicHash::Sha256); }

// NFC-normalize human text so visually identical strings from different keyboards hash the same.
QByteArray nfc(const QString& s) { return s.normalized(QString::NormalizationForm_C).toUtf8(); }

// Canonical compact-JSON preimage of (Title, Pass) — QJsonObject serializes keys alphabetically, so
// the bytes are deterministic and JSON escaping disambiguates every separator. Mirrors the
// station_identity sig-canonicalization convention.
QByteArray topicPreimage(const QString& title, const QString& pass)
{
    QJsonObject o;
    o.insert(QStringLiteral("d"), QString::fromLatin1(kTopicDomain));
    o.insert(QStringLiteral("p"), QString::fromUtf8(nfc(pass)));
    o.insert(QStringLiteral("t"), QString::fromUtf8(nfc(title)));
    return QJsonDocument(o).toJson(QJsonDocument::Compact);
}

// RFC 4648 base32, lowercase, no padding — topic-safe [a-z2-7]. 16 bytes → 26 chars.
QString base32Lower(const QByteArray& data)
{
    static const char* A = "abcdefghijklmnopqrstuvwxyz234567";
    QString out;
    quint32 buf = 0; int bits = 0;
    for (unsigned char c : data) {
        buf = (buf << 8) | c; bits += 8;
        while (bits >= 5) { out += QLatin1Char(A[(buf >> (bits - 5)) & 0x1f]); bits -= 5; }
    }
    if (bits > 0) out += QLatin1Char(A[(buf << (5 - bits)) & 0x1f]);
    return out;
}

QByteArray aadFor(const QString& topicSegment)
{
    // Bind the ciphertext to its topic + payload version — a captured ct can't be replayed onto a
    // different topic or spoofed as a different version. AAD = UTF-8("<seg>|pv=1").
    return (topicSegment + QStringLiteral("|pv=%1").arg(kPayloadVer)).toUtf8();
}

} // namespace

bool init() { return sodium_init() >= 0; }

QString deriveTopicSegment(const QString& title, const QString& pass)
{
    return base32Lower(sha256(topicPreimage(title, pass)).left(kTopicTruncBytes));
}

QString deriveTopic(const QString& title, const QString& pass)
{
    return QStringLiteral("/radio-basecamp/1/%1/json").arg(deriveTopicSegment(title, pass));
}

QByteArray deriveKey(const QString& title, const QString& pass)
{
    const QByteArray salt =
        sha256(QByteArray(kKdfDomain) + nfc(title)).left(crypto_pwhash_SALTBYTES);   // 16 bytes
    const QByteArray p = nfc(pass);
    QByteArray key(crypto_aead_xchacha20poly1305_ietf_KEYBYTES, Qt::Uninitialized);  // 32 bytes
    if (crypto_pwhash(reinterpret_cast<unsigned char*>(key.data()), key.size(),
                      p.constData(), static_cast<unsigned long long>(p.size()),
                      reinterpret_cast<const unsigned char*>(salt.constData()),
                      kOpsLimit, kMemLimit, crypto_pwhash_ALG_ARGON2ID13) != 0)
        return QByteArray();   // out of memory — caller treats as failure
    return key;
}

QString encryptAnnounceWithNonce(const QByteArray& key, const QByteArray& plaintext,
                                 const QString& topicSegment, const QByteArray& nonce24)
{
    if (key.size() != crypto_aead_xchacha20poly1305_ietf_KEYBYTES
        || nonce24.size() != crypto_aead_xchacha20poly1305_ietf_NPUBBYTES)
        return QString();
    const QByteArray aad = aadFor(topicSegment);
    QByteArray ct(plaintext.size() + crypto_aead_xchacha20poly1305_ietf_ABYTES, Qt::Uninitialized);
    unsigned long long ctLen = 0;
    crypto_aead_xchacha20poly1305_ietf_encrypt(
        reinterpret_cast<unsigned char*>(ct.data()), &ctLen,
        reinterpret_cast<const unsigned char*>(plaintext.constData()),
        static_cast<unsigned long long>(plaintext.size()),
        reinterpret_cast<const unsigned char*>(aad.constData()),
        static_cast<unsigned long long>(aad.size()),
        nullptr,
        reinterpret_cast<const unsigned char*>(nonce24.constData()),
        reinterpret_cast<const unsigned char*>(key.constData()));
    ct.resize(static_cast<int>(ctLen));

    QJsonObject env;
    env.insert(QStringLiteral("pv"),  kPayloadVer);
    env.insert(QStringLiteral("enc"), QString::fromLatin1(kEncSuite));
    env.insert(QStringLiteral("n"),   QString::fromLatin1(nonce24.toBase64()));
    env.insert(QStringLiteral("ct"),  QString::fromLatin1(ct.toBase64()));
    return QString::fromUtf8(QJsonDocument(env).toJson(QJsonDocument::Compact));
}

QString encryptAnnounce(const QByteArray& key, const QByteArray& plaintext, const QString& topicSegment)
{
    QByteArray nonce(crypto_aead_xchacha20poly1305_ietf_NPUBBYTES, Qt::Uninitialized);
    randombytes_buf(nonce.data(), nonce.size());
    return encryptAnnounceWithNonce(key, plaintext, topicSegment, nonce);
}

bool isEnvelope(const QString& payloadJson)
{
    const QJsonObject o = QJsonDocument::fromJson(payloadJson.toUtf8()).object();
    return o.contains(QStringLiteral("pv")) && o.contains(QStringLiteral("enc"));
}

bool decryptAnnounce(const QByteArray& key, const QString& envelopeJson,
                     const QString& topicSegment, QByteArray& out)
{
    if (key.size() != crypto_aead_xchacha20poly1305_ietf_KEYBYTES) return false;
    const QJsonObject env = QJsonDocument::fromJson(envelopeJson.toUtf8()).object();
    if (env.value(QStringLiteral("enc")).toString() != QLatin1String(kEncSuite)) return false;
    if (env.value(QStringLiteral("pv")).toInt(-1) != kPayloadVer) return false;

    const QByteArray nonce = QByteArray::fromBase64(env.value(QStringLiteral("n")).toString().toLatin1());
    const QByteArray ct    = QByteArray::fromBase64(env.value(QStringLiteral("ct")).toString().toLatin1());
    if (nonce.size() != crypto_aead_xchacha20poly1305_ietf_NPUBBYTES) return false;
    if (ct.size() < static_cast<int>(crypto_aead_xchacha20poly1305_ietf_ABYTES)) return false;

    const QByteArray aad = aadFor(topicSegment);
    QByteArray pt(ct.size() - crypto_aead_xchacha20poly1305_ietf_ABYTES, Qt::Uninitialized);
    unsigned long long ptLen = 0;
    if (crypto_aead_xchacha20poly1305_ietf_decrypt(
            reinterpret_cast<unsigned char*>(pt.data()), &ptLen, nullptr,
            reinterpret_cast<const unsigned char*>(ct.constData()),
            static_cast<unsigned long long>(ct.size()),
            reinterpret_cast<const unsigned char*>(aad.constData()),
            static_cast<unsigned long long>(aad.size()),
            reinterpret_cast<const unsigned char*>(nonce.constData()),
            reinterpret_cast<const unsigned char*>(key.constData())) != 0)
        return false;   // wrong key / tamper / wrong topic — fail closed
    pt.resize(static_cast<int>(ptLen));
    out = pt;
    return true;
}

bool selfTest()
{
    if (!init()) return false;

    // Fixed inputs → GOLDEN CROSS-IMPL VECTORS. Both repos + any port MUST reproduce these exactly.
    const QString title = QStringLiteral("Parallel Society Radio");
    const QString pass  = QStringLiteral("correct horse battery staple");

    const QString seg = deriveTopicSegment(title, pass);
    const QString topic = deriveTopic(title, pass);
    const QByteArray key = deriveKey(title, pass);
    if (key.size() != 32) return false;

    // Golden vector assertions (values baked from the reference run; a mismatch = a byte-level
    // divergence that would break interop).
    const QString kGoldSeg = QStringLiteral("rdbdcntqiiyuvqrx3c4uuukcuu");
    const QString kGoldKey = QStringLiteral("0206f36f316dfac61900a84f3b6d8860e9bd5443851646e25bc8bc2acd2d5ff1");
    if (seg != kGoldSeg) return false;
    if (QString::fromLatin1(key.toHex()) != kGoldKey) return false;
    if (topic != QStringLiteral("/radio-basecamp/1/") + kGoldSeg + QStringLiteral("/json")) return false;

    const QByteArray plaintext =
        QByteArrayLiteral("{\"v\":1,\"name\":\"Parallel Society Radio\",\"streamUrl\":\"http://abc.onion/x/index.m3u8\"}");

    // Round-trip.
    const QString env = encryptAnnounce(key, plaintext, seg);
    if (!isEnvelope(env)) return false;
    QByteArray rt;
    if (!decryptAnnounce(key, env, seg, rt) || rt != plaintext) return false;

    // Negative: wrong Pass fails to decrypt.
    const QByteArray wrongKey = deriveKey(title, QStringLiteral("wrong pass"));
    QByteArray dummy;
    if (decryptAnnounce(wrongKey, env, seg, dummy)) return false;

    // Negative: wrong topic (AAD mismatch) fails.
    if (decryptAnnounce(key, env, QStringLiteral("aaaaaaaaaaaaaaaaaaaaaaaaaa"), dummy)) return false;

    // Negative: tamper one ciphertext byte fails.
    {
        QJsonObject o = QJsonDocument::fromJson(env.toUtf8()).object();
        QByteArray ct = QByteArray::fromBase64(o.value(QStringLiteral("ct")).toString().toLatin1());
        ct[0] = ct[0] ^ 0x01;
        o[QStringLiteral("ct")] = QString::fromLatin1(ct.toBase64());
        const QString tampered = QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
        if (decryptAnnounce(key, tampered, seg, dummy)) return false;
    }

    // Deterministic ciphertext vector (fixed nonce) — proves the AEAD wire bytes are reproducible.
    const QByteArray fixedNonce(24, '\x07');
    const QString detEnv = encryptAnnounceWithNonce(key, plaintext, seg, fixedNonce);
    QByteArray detRt;
    if (!decryptAnnounce(key, detEnv, seg, detRt) || detRt != plaintext) return false;
    const QString kGoldCt = QStringLiteral("JATbvqazwSc1Juu0XKqw0e+4lulqBI4WhBJeOcMwTKRSeUkWqBx7HwlpHF1/ULUwfgaIsngt7k+0DF8kVZcsNEBaqIyWGhUdFDHqEX263olhnMcGdomUj9REcs8UL46xKYPR");
    const QString ctVal = QJsonDocument::fromJson(detEnv.toUtf8()).object()
                              .value(QStringLiteral("ct")).toString();
    if (ctVal != kGoldCt) return false;

    return true;
}

} // namespace StationCrypto
