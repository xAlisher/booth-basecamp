// Headless crypto contract test for station identity (epic #24/#13). Exercises the FULL v:2 signing
// contract without a Basecamp load: selftest, keygen+persist, canonical-bytes round-trip, verify,
// tamper-reject, fingerprint. Compiled directly against nix secp256k1 + Qt Core (see run below).
#include "../src/station_identity.h"
#include <QByteArray>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

// Mirror the receiver's canonicalization exactly: object minus "sig", compact, UTF-8.
static QByteArray canon(QJsonObject o) { o.remove("sig"); return QJsonDocument(o).toJson(QJsonDocument::Compact); }

int main()
{
    int fails = 0;
    auto check = [&](const char* name, bool ok) { printf("  %-22s %s\n", name, ok ? "OK" : "FAIL"); if (!ok) ++fails; };

    check("selfTest", StationIdentity::selfTest());

    StationIdentity id;
    const QString keyPath = "/tmp/rid-identity-test.key";
    QFile::remove(keyPath);
    check("loadOrCreate", id.loadOrCreate(keyPath));
    printf("  pubkey = %s\n", id.pubkeyHex().toUtf8().constData());
    check("pubkey is 33B hex", id.pubkeyHex().size() == 66);

    // Broadcaster: build v:2 announce, sign canonical bytes, attach sig.
    QJsonObject a{{"v", 2}, {"name", "Parallel Society Radio"}, {"host", "anonymous"},
                  {"path", "33a5971eeba1d06a"}, {"streamUrl", "http://x.onion/index.m3u8"},
                  {"visibility", "public"}, {"description", "cypherpunk radio"},
                  {"startedAt", (qint64)1751713920123LL}, {"seq", 7}, {"nowPlaying", "Kode9 \u2014 Live Set (PS06)"},
                  {"announceTopic", "/radio-basecamp/1/directory/json"}, {"pubkey", id.pubkeyHex()}};
    const QByteArray signedBytes = canon(a);
    const QString sig = id.signHex(signedBytes);
    a["sig"] = sig;
    check("sign produced 64B hex", sig.size() == 128);

    // Receiver: strip sig, re-serialize identically, verify against the embedded pubkey.
    const QByteArray rxBytes = canon(a);
    check("canonical bytes match", signedBytes == rxBytes);
    check("verify valid sig", StationIdentity::verify(id.pubkeyHex(), sig, rxBytes));

    // Tamper: change a signed field → must fail.
    QJsonObject t = a;
    t["name"] = "IMPOSTOR";
    check("tamper rejected", !StationIdentity::verify(id.pubkeyHex(), sig, canon(t)));

    // Wrong key → must fail.
    StationIdentity other;
    QFile::remove("/tmp/rid-other.key");
    other.loadOrCreate("/tmp/rid-other.key");
    check("wrong pubkey rejected", !StationIdentity::verify(other.pubkeyHex(), sig, rxBytes));

    // Persistence: reload same file → same pubkey (survives restart).
    StationIdentity id2;
    check("persist stable", id2.loadOrCreate(keyPath) && id2.pubkeyHex() == id.pubkeyHex());

    // #24 Stage 3 — seed from a hex privkey (keycard path) → must sign + verify
    StationIdentity kc;
    const bool kok = kc.fromSeckeyHex(QString::fromLatin1(QByteArray(32, 2).toHex()));
    const QString ks = kok ? kc.signHex(QByteArray("kc")) : QString();
    check("fromSeckeyHex sign+verify", kok && StationIdentity::verify(kc.pubkeyHex(), ks, QByteArray("kc")));

    const QString fp = StationIdentity::fingerprint(id.pubkeyHex());
    printf("  fingerprint = %s\n", fp.toUtf8().constData());
    check("fingerprint non-empty", !fp.isEmpty());

    printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "FAILURES", fails);
    return fails == 0 ? 0 : 1;
}
