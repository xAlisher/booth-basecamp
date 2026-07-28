// Headless crypto contract test for the private-stream protocol (booth#66 / receiver#69).
// Proves the derive→encrypt→decrypt round-trip, the wrong-pass/tamper/wrong-topic negatives, and
// (once baked) the golden cross-impl vectors — WITHOUT a Basecamp load. Compiled directly against
// libsodium + Qt Core. This is the cheapest real proof and it gates the UI work.
//
// Build+run: tests/run-crypto-test.sh
#include "../src/station_crypto.h"

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

int main()
{
    int fails = 0;
    auto check = [&](const char* name, bool ok) {
        printf("  %-34s %s\n", name, ok ? "OK" : "FAIL");
        if (!ok) ++fails;
    };

    check("init", StationCrypto::init());

    // The reference inputs used for the golden vectors (must match selfTest()).
    const QString title = QStringLiteral("Parallel Society Radio");
    const QString pass  = QStringLiteral("correct horse battery staple");

    const QString seg   = StationCrypto::deriveTopicSegment(title, pass);
    const QString topic = StationCrypto::deriveTopic(title, pass);
    const QByteArray key = StationCrypto::deriveKey(title, pass);

    // Emit the golden values so they can be baked into station_crypto.cpp::selfTest().
    printf("\n  --- GOLDEN VECTORS (title=%s) ---\n", title.toUtf8().constData());
    printf("  GOLD_SEG = %s\n", seg.toUtf8().constData());
    printf("  GOLD_TOPIC = %s\n", topic.toUtf8().constData());
    printf("  GOLD_KEY = %s\n", key.toHex().constData());

    const QByteArray plaintext =
        QByteArrayLiteral("{\"v\":1,\"name\":\"Parallel Society Radio\",\"streamUrl\":\"http://abc.onion/x/index.m3u8\"}");
    const QByteArray fixedNonce(24, '\x07');
    const QString detEnv = StationCrypto::encryptAnnounceWithNonce(key, plaintext, seg, fixedNonce);
    const QString detCt = QJsonDocument::fromJson(detEnv.toUtf8()).object()
                              .value(QStringLiteral("ct")).toString();
    printf("  GOLD_CT  = %s\n\n", detCt.toUtf8().constData());

    // Functional checks (independent of the baked golden equality).
    check("topic shape", topic.startsWith(QStringLiteral("/radio-basecamp/1/")) && topic.endsWith(QStringLiteral("/json")));
    check("segment length 26", seg.size() == 26);
    check("key is 32 bytes", key.size() == 32);
    check("payload is an envelope", StationCrypto::isEnvelope(detEnv));

    QByteArray rt;
    check("round-trip decrypt == plaintext",
          StationCrypto::decryptAnnounce(key, detEnv, seg, rt) && rt == plaintext);

    QByteArray dummy;
    const QByteArray wrongKey = StationCrypto::deriveKey(title, QStringLiteral("wrong pass"));
    check("wrong pass FAILS (negative)", !StationCrypto::decryptAnnounce(wrongKey, detEnv, seg, dummy));
    check("wrong topic/AAD FAILS (negative)",
          !StationCrypto::decryptAnnounce(key, detEnv, QStringLiteral("aaaaaaaaaaaaaaaaaaaaaaaaaa"), dummy));

    {
        QJsonObject o = QJsonDocument::fromJson(detEnv.toUtf8()).object();
        QByteArray ct = QByteArray::fromBase64(o.value(QStringLiteral("ct")).toString().toLatin1());
        ct[0] = ct[0] ^ 0x01;
        o[QStringLiteral("ct")] = QString::fromLatin1(ct.toBase64());
        const QString tampered = QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
        check("tamper FAILS (negative)", !StationCrypto::decryptAnnounce(key, tampered, seg, dummy));
    }

    // A different (Title, Pass) yields a different topic — a relay sees only a random-hash topic.
    check("different title → different topic",
          StationCrypto::deriveTopic(QStringLiteral("Other Show"), pass) != topic);
    check("different pass → different topic",
          StationCrypto::deriveTopic(title, QStringLiteral("other pass")) != topic);

    // The baked golden self-test (skips until vectors are filled in — see run script).
    printf("\n  selfTest() [golden] = %s\n", StationCrypto::selfTest() ? "OK" : "FAIL/PENDING-BAKE");

    printf("\n%s (%d functional failure(s))\n", fails == 0 ? "FUNCTIONAL: PASS" : "FUNCTIONAL: FAIL", fails);
    return fails;
}
