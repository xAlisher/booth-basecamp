#include "station_identity.h"
#include "pgp_words.h"

#include <secp256k1.h>

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRandomGenerator>

namespace {
// Shared secp256k1 context (single-threaded module/ui-host use). Randomized once for side-channel
// resistance on signing. SECP256K1_CONTEXT_NONE is correct for modern libsecp256k1 (sign+verify).
secp256k1_context* ctx()
{
    static secp256k1_context* c = [] {
        secp256k1_context* x = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
        unsigned char seed[32];
        for (int i = 0; i < 32; ++i) seed[i] = static_cast<unsigned char>(QRandomGenerator::system()->bounded(256));
        (void)secp256k1_context_randomize(x, seed);
        return x;
    }();
    return c;
}

QByteArray sha256(const QByteArray& m) { return QCryptographicHash::hash(m, QCryptographicHash::Sha256); }

void randomSeckey(QByteArray& sk)
{
    sk.resize(32);
    do {
        for (int i = 0; i < 32; ++i) sk[i] = static_cast<char>(QRandomGenerator::system()->bounded(256));
    } while (!secp256k1_ec_seckey_verify(ctx(), reinterpret_cast<const unsigned char*>(sk.constData())));
}

QString compressedPubHex(const QByteArray& sk)
{
    secp256k1_pubkey pub;
    if (!secp256k1_ec_pubkey_create(ctx(), &pub, reinterpret_cast<const unsigned char*>(sk.constData())))
        return QString();
    unsigned char out[33];
    size_t olen = sizeof(out);
    secp256k1_ec_pubkey_serialize(ctx(), out, &olen, &pub, SECP256K1_EC_COMPRESSED);
    return QString::fromLatin1(QByteArray(reinterpret_cast<const char*>(out), 33).toHex());
}
} // namespace

bool StationIdentity::loadOrCreate(const QString& keyPath)
{
    m_valid = false;
    m_seckey.clear();
    m_pubHex.clear();

    QByteArray sk;
    QFile f(keyPath);
    if (f.exists() && f.open(QIODevice::ReadOnly)) {
        sk = QByteArray::fromHex(f.readAll().trimmed());
        f.close();
        if (sk.size() != 32 || !secp256k1_ec_seckey_verify(ctx(), reinterpret_cast<const unsigned char*>(sk.constData())))
            sk.clear();
    }
    if (sk.isEmpty()) {
        randomSeckey(sk);
        QDir().mkpath(QFileInfo(keyPath).absolutePath());
        QFile w(keyPath);
        if (!w.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
        w.write(sk.toHex());
        w.close();
        QFile::setPermissions(keyPath, QFile::ReadOwner | QFile::WriteOwner);  // 0600 — privkey on disk
    }

    const QString pub = compressedPubHex(sk);
    if (pub.isEmpty()) return false;
    m_seckey = sk;
    m_pubHex = pub;
    m_valid  = true;
    return true;
}

QString StationIdentity::signHex(const QByteArray& msg) const
{
    if (!m_valid) return QString();
    const QByteArray d = sha256(msg);
    secp256k1_ecdsa_signature sig;
    if (!secp256k1_ecdsa_sign(ctx(), &sig, reinterpret_cast<const unsigned char*>(d.constData()),
                              reinterpret_cast<const unsigned char*>(m_seckey.constData()), nullptr, nullptr))
        return QString();
    unsigned char out[64];
    secp256k1_ecdsa_signature_serialize_compact(ctx(), out, &sig);
    return QString::fromLatin1(QByteArray(reinterpret_cast<const char*>(out), 64).toHex());
}

bool StationIdentity::verify(const QString& pubkeyHex, const QString& sigHex, const QByteArray& msg)
{
    const QByteArray pub = QByteArray::fromHex(pubkeyHex.toUtf8());
    const QByteArray sg  = QByteArray::fromHex(sigHex.toUtf8());
    if (pub.size() != 33 || sg.size() != 64) return false;

    secp256k1_pubkey pk;
    if (!secp256k1_ec_pubkey_parse(ctx(), &pk, reinterpret_cast<const unsigned char*>(pub.constData()), 33))
        return false;
    secp256k1_ecdsa_signature sig;
    if (!secp256k1_ecdsa_signature_parse_compact(ctx(), &sig, reinterpret_cast<const unsigned char*>(sg.constData())))
        return false;
    const QByteArray d = sha256(msg);
    return secp256k1_ecdsa_verify(ctx(), &sig, reinterpret_cast<const unsigned char*>(d.constData()), &pk) == 1;
}

QString StationIdentity::fingerprint(const QString& pubkeyHex)
{
    const QByteArray pub = QByteArray::fromHex(pubkeyHex.toUtf8());
    if (pub.size() != 33) return QString();
    const QByteArray h = sha256(pub);
    // 3 PGP biometric words, alternating even(pos0)/odd(pos1)/even(pos2) tables — human recognition check.
    const int b0 = static_cast<unsigned char>(h[0]), b1 = static_cast<unsigned char>(h[1]), b2 = static_cast<unsigned char>(h[2]);
    return QStringLiteral("%1 %2 %3").arg(QLatin1String(kPgpEven[b0]), QLatin1String(kPgpOdd[b1]), QLatin1String(kPgpEven[b2]));
}

bool StationIdentity::selfTest()
{
    unsigned char skRaw[32];
    for (int i = 0; i < 32; ++i) skRaw[i] = static_cast<unsigned char>(i + 1);
    if (!secp256k1_ec_seckey_verify(ctx(), skRaw)) return false;

    StationIdentity id;
    id.m_seckey = QByteArray(reinterpret_cast<const char*>(skRaw), 32);
    id.m_pubHex = compressedPubHex(id.m_seckey);
    id.m_valid  = !id.m_pubHex.isEmpty();
    if (!id.m_valid) return false;

    const QByteArray msg = "station-identity-selftest";
    const QString sig = id.signHex(msg);
    if (sig.isEmpty()) return false;
    if (!verify(id.m_pubHex, sig, msg)) return false;
    if (verify(id.m_pubHex, sig, QByteArray("tampered"))) return false;  // tamper MUST fail
    return true;
}
