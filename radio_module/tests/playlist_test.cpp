// Standalone test for the playlist source (#86) and the child guard (#88). Qt + ffmpeg only, no Logos SDK.
// Build + run: tests/run-playlist-test.sh  (optional RADIO_MEDIAMTX_BIN → also tests a live MediaMTX path)
#include "../src/child_guard.h"
#include "../src/playlist_source.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>

#include <csignal>
#include <cstdio>
#include <unistd.h>

static int fails = 0;
static void check(bool c, const QString& msg)
{
    std::printf("%s: %s\n", c ? "PASS" : "FAIL", qPrintable(msg));
    if (!c) ++fails;
}

static void spin(int ms)
{
    QEventLoop loop;
    QTimer::singleShot(ms, &loop, &QEventLoop::quit);
    loop.exec();
}

template <typename Pred>
static bool spinUntil(Pred p, int timeoutMs)
{
    QElapsedTimer t;
    t.start();
    while (t.elapsed() < timeoutMs) {
        if (p()) return true;
        spin(50);
    }
    return p();
}

// Playlist binaries can differ from the fixture-making ffmpeg: RADIO_FFMPEG_BIN / RADIO_FFPROBE_BIN test a
// bundled (trimmed) build, which has no mp3/flac/vorbis encoders to make fixtures with.
static void useBins(PlaylistSource& pl)
{
    pl.setBinaries(qEnvironmentVariable("RADIO_FFMPEG_BIN", "ffmpeg"), qEnvironmentVariable("RADIO_FFPROBE_BIN", "ffprobe"));
}

static bool makeTone(const QString& out, int hz, double secs, const QString& title, const QString& artist)
{
    QStringList a{"-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                  "-i", QStringLiteral("sine=frequency=%1:duration=%2").arg(hz).arg(secs)};
    if (!title.isEmpty()) a << "-metadata" << "title=" + title;
    if (!artist.isEmpty()) a << "-metadata" << "artist=" + artist;
    a << out;
    return QProcess::execute("ffmpeg", a) == 0;
}

static double wavSeconds(const QString& path)
{
    QProcess p;
    p.start("ffprobe", {"-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", path});
    p.waitForFinished(5000);
    return p.readAllStandardOutput().trimmed().toDouble();
}

// Minimal HTTP/1.0 GET. Follows one redirect, echoing Set-Cookie (MediaMTX's HLS cookie check, as Receiver does).
static int httpGet(int port, const QString& path, QByteArray* body = nullptr, int hops = 1, const QByteArray& cookie = {})
{
    QTcpSocket s;
    s.connectToHost(QHostAddress::LocalHost, quint16(port));
    if (!s.waitForConnected(500)) return -1;
    QByteArray req = QStringLiteral("GET %1 HTTP/1.0\r\nHost: 127.0.0.1\r\n").arg(path).toUtf8();
    if (!cookie.isEmpty()) req += "Cookie: " + cookie + "\r\n";
    s.write(req + "\r\n");
    QByteArray raw;
    while (s.waitForReadyRead(500)) raw += s.readAll();
    const int sep = raw.indexOf("\r\n\r\n");
    if (body) *body = raw.mid(sep + 4);
    const QList<QByteArray> head = raw.left(sep).split('\n');
    const QList<QByteArray> st = head.value(0).split(' ');
    const int code = st.size() > 1 ? st[1].toInt() : -1;
    if ((code == 301 || code == 302) && hops > 0) {
        QByteArray loc, ck;
        for (const QByteArray& h : head) {
            const QByteArray l = h.trimmed();
            if (l.toLower().startsWith("location:")) loc = l.mid(9).trimmed();
            if (l.toLower().startsWith("set-cookie:")) ck = l.mid(11).trimmed().split(';').value(0);
        }
        if (loc.startsWith("http")) loc = "/" + loc.split('/').mid(3).join('/');
        if (!loc.startsWith('/')) loc = path.left(path.lastIndexOf('/') + 1).toUtf8() + loc;
        return httpGet(port, QString::fromUtf8(loc), body, hops - 1, ck);
    }
    return code;
}

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    QTemporaryDir tmp(qEnvironmentVariable("TEST_TMP", QDir::tempPath()) + "/playlist-test-XXXXXX");
    const QString music = tmp.path() + "/music", sub = music + "/sub";
    QDir().mkpath(sub);

    // --- fixtures: tags, no tags, a sub-folder, natural sort (2 before 10), one broken file ---
    check(makeTone(music + "/02 a.mp3", 440, 2.0, "Tone A", "Tester"), "fixture mp3 with title+artist");
    check(makeTone(music + "/10 b.flac", 660, 2.0, "Tone B", ""), "fixture flac with title only");
    check(makeTone(sub + "/c.ogg", 880, 1.5, "", ""), "fixture ogg without tags (sub-folder)");
    { QFile f(music + "/05 broken.mp3"); f.open(QIODevice::WriteOnly); f.write("not audio at all"); }
    { QFile f(music + "/notes.txt"); f.open(QIODevice::WriteOnly); f.write("ignored"); }

    // ===== 1. File output: order, titles, skip broken, one encoder, real-time pacing, ended =====
    {
        PlaylistSource pl;
        useBins(pl);
        const int n = pl.setPlaylist(QJsonObject{{"items", QJsonArray{music}}, {"shuffle", false}, {"loop", false}});
        check(n == 4, QStringLiteral("folder expands recursively to 4 audio files (got %1), .txt ignored").arg(n));
        QStringList titles;
        bool ended = false;
        QObject::connect(&pl, &PlaylistSource::trackChanged, [&](const QString& t) { if (!t.isEmpty()) titles << t; });
        QObject::connect(&pl, &PlaylistSource::ended, [&] { ended = true; });
        const QString wav = tmp.path() + "/out.wav";
        QElapsedTimer wall;
        wall.start();
        pl.start({"-c:a", "pcm_s16le", "-f", "wav", "-y", wav});
        bool sawPlaying = false;
        spinUntil([&] { if (pl.state().value("state").toString() == "playing") sawPlaying = true; return ended; }, 15000);
        const double playedFor = wall.elapsed() / 1000.0;
        spin(500);
        const QJsonObject endState = pl.state();
        pl.stop();

        std::printf("     titles: %s\n", qPrintable(titles.join(" | ")));
        check(sawPlaying, "state reported 'playing' while a track was on");
        check(ended, "non-looping list emits ended()");
        check(endState.value("state").toString() == "ended", "state is 'ended' after the last track");
        check(titles == QStringList({"Tester — Tone A", "Tone B", "c"}),
              "order is natural-sorted, titles from tags (artist — title / title / file name), broken file skipped");
        check(pl.encoderStarts() == 1, "one encoder for the whole playlist (stream never restarted)");
        const double audio = pl.audioBytes() / double(PlaylistSource::kBytesPerSec);
        check(audio > 5.2 && audio < 5.8, QStringLiteral("all 5.5 s of audio sent (got %1 s)").arg(audio, 0, 'f', 2));
        check(playedFor > 5.0 && playedFor < 8.0, QStringLiteral("paced in real time: 5.5 s of audio took %1 s").arg(playedFor, 0, 'f', 2));
        const double outSecs = wavSeconds(wav);
        const double fed = (pl.audioBytes() + pl.silenceBytes()) / double(PlaylistSource::kBytesPerSec);
        check(qAbs(outSecs - fed) < 0.3, QStringLiteral("encoder output (%1 s) = everything fed (%2 s): no data lost").arg(outSecs, 0, 'f', 2).arg(fed, 0, 'f', 2));
        const double gaps = pl.silenceBytes() / double(PlaylistSource::kBytesPerSec) - 0.5;   // ~0.5 s trails after ended
        check(gaps < 1.5, QStringLiteral("silence between tracks stays small (%1 s over 3 hand-overs + a skip)").arg(qMax(0.0, gaps), 0, 'f', 2));
    }

    // ===== 1b. A clean hand-over (no broken file between) is gapless: no silence between first and last audio =====
    {
        PlaylistSource pl;
        useBins(pl);
        pl.setPlaylist(QJsonObject{{"items", QJsonArray{music + "/02 a.mp3", music + "/10 b.flac", sub + "/c.ogg"}}, {"loop", false}});
        qint64 silenceAtFirstAudio = -1, silenceAtLastChange = -1;
        int changes = 0;
        QObject::connect(&pl, &PlaylistSource::trackChanged, [&](const QString& t) {
            if (t.isEmpty()) return;
            if (++changes == 1) silenceAtFirstAudio = pl.silenceBytes();
            silenceAtLastChange = pl.silenceBytes();
        });
        bool ended = false;
        QObject::connect(&pl, &PlaylistSource::ended, [&] { ended = true; });
        pl.start({"-c:a", "pcm_s16le", "-f", "null", "-"});
        spinUntil([&] { return ended; }, 12000);
        pl.stop();
        const double gapMs = (silenceAtLastChange - silenceAtFirstAudio) * 1000.0 / PlaylistSource::kBytesPerSec;
        check(changes == 3 && gapMs < 50, QStringLiteral("gapless hand-overs: %1 ms of silence across 2 track changes").arg(gapMs, 0, 'f', 0));
    }

    // ===== 2. Controls: next, pause (silence keeps flowing), resume at the same spot, shuffle+loop =====
    {
        PlaylistSource pl;
        useBins(pl);
        pl.setPlaylist(QJsonObject{{"items", QJsonArray{music + "/02 a.mp3", music + "/10 b.flac"}}, {"loop", true}});
        QStringList titles;
        QObject::connect(&pl, &PlaylistSource::trackChanged, [&](const QString& t) { titles << t; });
        pl.start({"-c:a", "pcm_s16le", "-f", "null", "-"});
        spinUntil([&] { return pl.state().value("state").toString() == "playing"; }, 5000);
        spin(600);
        const qint64 silenceBeforeNext = pl.silenceBytes();
        pl.next();
        spinUntil([&] { return pl.nowPlaying() == "Tone B"; }, 3000);
        check(pl.nowPlaying() == "Tone B", "next() moves to the next track");
        spin(700);
        // Regression: ffmpeg -re stalled FLAC output >1 s, so Next onto a .flac aired ~1 s of silence.
        const double nextGap = (pl.silenceBytes() - silenceBeforeNext) / double(PlaylistSource::kBytesPerSec);
        check(nextGap < 0.35, QStringLiteral("next() onto a FLAC track airs no stall (%1 s of silence)").arg(nextGap, 0, 'f', 2));
        const double before = pl.state().value("current").toObject().value("elapsed").toDouble();
        pl.setPaused(true);
        const qint64 silence0 = pl.silenceBytes();
        spin(1200);
        const QJsonObject ps = pl.state();
        check(ps.value("state").toString() == "paused", "state is 'paused'");
        check(pl.nowPlaying() == "Tone B", "the paused track is still the one shown");
        const double silent = (pl.silenceBytes() - silence0) / double(PlaylistSource::kBytesPerSec);
        check(silent > 0.9, QStringLiteral("pause sends silence so the stream stays up (%1 s in 1.2 s)").arg(silent, 0, 'f', 2));
        pl.setPaused(false);
        spinUntil([&] { return pl.state().value("state").toString() == "playing"; }, 3000);
        spin(300);
        const double after = pl.state().value("current").toObject().value("elapsed").toDouble();
        std::printf("     paused state: %s\n", QJsonDocument(ps).toJson(QJsonDocument::Compact).constData());
        check(before > 0.05 && after >= before - 0.05 && after < before + 1.0,
              QStringLiteral("resume continues from %1 s (now %2 s)").arg(before, 0, 'f', 2).arg(after, 0, 'f', 2));
        spinUntil([&] { return pl.nowPlaying() == "Tester — Tone A"; }, 4000);
        check(pl.nowPlaying() == "Tester — Tone A", "loop wraps back to the first track");
        check(pl.encoderStarts() == 1, "next/pause/resume never restart the encoder");
        pl.stop();
        check(pl.state().value("state").toString() == "idle", "stop() → idle");
    }

    // ===== 3. Empty / bad input =====
    {
        PlaylistSource pl;
        useBins(pl);
        check(pl.setPlaylist(QJsonObject{{"items", QJsonArray{tmp.path() + "/nope", music + "/notes.txt"}}}) == 0,
              "missing paths and non-audio files give an empty playlist");
        check(pl.state().value("error").toString() == "playlist_empty", "empty playlist reports playlist_empty");
        pl.setPlaylist(QJsonObject{{"items", QJsonArray{music}}, {"kbps", 64}});
        check(pl.bitrate() == 64 && pl.config().value("kbps").toInt() == 64, "kbps from the playlist config sets the encoder bitrate");
        pl.setPlaylist(QJsonObject{{"items", QJsonArray{music}}, {"kbps", 9999}});
        check(pl.bitrate() == 64, "an out-of-range kbps is ignored");
    }

    // ===== 4. Live MediaMTX path stays 'ready' across track changes (optional) =====
    const QString mtx = qEnvironmentVariable("RADIO_MEDIAMTX_BIN");
    if (!mtx.isEmpty()) {
        const int rtmp = 21935, hls = 28888, api = 29997;
        const QString cfgPath = tmp.path() + "/mediamtx.yml";
        QFile cfg(cfgPath);
        cfg.open(QIODevice::WriteOnly);
        cfg.write(QStringLiteral(
            "rtmpAddress: :%1\nhlsAddress: :%2\napiAddress: :%3\napi: yes\nhls: yes\nhlsAlwaysRemux: yes\n"
            "hlsVariant: mpegts\nhlsSegmentCount: 24\nhlsSegmentDuration: 1s\nwebrtc: no\nsrt: no\nrtsp: no\n"
            "authInternalUsers:\n- user: any\n  permissions:\n  - action: read\n  - action: api\n"
            "- user: publisher\n  pass: k3y\n  permissions:\n  - action: publish\npaths:\n  all_others:\n")
                      .arg(rtmp).arg(hls).arg(api).toUtf8());
        cfg.close();
        QProcess mediamtx;
        ChildGuard::prepare(&mediamtx);
        mediamtx.setProcessChannelMode(QProcess::MergedChannels);
        mediamtx.start(mtx, {cfgPath});
        check(mediamtx.waitForStarted(5000) && spinUntil([&] { return httpGet(api, "/v3/paths/list") == 200; }, 5000),
              "MediaMTX up on test ports");

        PlaylistSource pl;
        useBins(pl);
        pl.setPlaylist(QJsonObject{{"items", QJsonArray{music}}, {"loop", true}});
        QStringList titles;
        QObject::connect(&pl, &PlaylistSource::trackChanged, [&](const QString& t) { titles << t; });
        pl.start(PlaylistSource::rtmpOutput(QStringLiteral("rtmp://127.0.0.1:%1/teststation?user=publisher&pass=k3y").arg(rtmp)));
        auto ready = [&] {
            QByteArray b;
            return httpGet(api, "/v3/paths/get/teststation", &b) == 200
                && QJsonDocument::fromJson(b).object().value("ready").toBool();
        };
        check(spinUntil(ready, 8000), "path goes ready once the encoder connects");
        int polls = 0, notReady = 0;
        QElapsedTimer t;
        t.start();
        while (t.elapsed() < 9000) { ++polls; if (!ready()) ++notReady; spin(200); }
        std::printf("     tracks while polled: %s\n", qPrintable(titles.join(" | ")));
        check(titles.size() >= 4, QStringLiteral("several track changes happened while polling (%1)").arg(titles.size()));
        check(notReady == 0, QStringLiteral("path stayed ready through every track change (%1/%2 polls not ready)").arg(notReady).arg(polls));
        QByteArray m3u8;
        const int hc = httpGet(hls, "/teststation/index.m3u8", &m3u8);
        std::printf("     HLS GET -> %d: %s\n", hc, m3u8.left(160).replace('\n', ' ').constData());
        check(hc == 200 && m3u8.contains("#EXT"), "HLS playlist served");
        check(pl.encoderStarts() == 1, "one encoder session for the whole run");

        // Output dies (MediaMTX restart) → encoder reconnects on its own.
        mediamtx.kill();
        mediamtx.waitForFinished(2000);
        mediamtx.start(mtx, {cfgPath});
        mediamtx.waitForStarted(5000);
        check(spinUntil(ready, 15000), "after an origin restart the encoder reconnects and the path is ready again");
        check(pl.encoderStarts() >= 2, QStringLiteral("encoder was restarted (%1 starts)").arg(pl.encoderStarts()));
        pl.stop();
        mediamtx.kill();
        mediamtx.waitForFinished(2000);
    } else {
        std::printf("SKIP: MediaMTX path test (set RADIO_MEDIAMTX_BIN)\n");
    }

    // ===== 5. ChildGuard: reap only orphans whose parent is gone and whose name still matches =====
    {
        ChildGuard::setRegistryPath(tmp.path() + "/children.pids");
        auto sleeper = [] { auto* p = new QProcess; p->start("sleep", {"30"}); p->waitForStarted(); return p; };
        QProcess* orphan = sleeper();
        QProcess* ownedByLive = sleeper();
        QProcess* renamed = sleeper();
        QFile reg(ChildGuard::registryPath());
        reg.open(QIODevice::WriteOnly);
        const qint64 deadParent = 999999;   // no such pid
        reg.write(QStringLiteral("%1 %2 sleep\n%3 %4 sleep\n%5 %2 mediamtx\n")
                      .arg(orphan->processId()).arg(deadParent)
                      .arg(ownedByLive->processId()).arg(QCoreApplication::applicationPid())
                      .arg(renamed->processId()).toUtf8());
        reg.close();
        check(ChildGuard::processName(orphan->processId()) == "sleep", "processName() reads the child's name");
        const int killed = ChildGuard::reapStale();
        check(killed == 1, QStringLiteral("reapStale killed exactly one process (got %1)").arg(killed));
        check(orphan->waitForFinished(2000), "the orphan (dead parent, same name) was reaped");
        check(ownedByLive->state() == QProcess::Running, "a child whose parent is alive is left alone");
        check(renamed->state() == QProcess::Running, "a pid whose name no longer matches is left alone");
        for (QProcess* p : {orphan, ownedByLive, renamed}) { p->kill(); p->waitForFinished(1000); delete p; }

        QProcess tracked;
        ChildGuard::prepare(&tracked);
        tracked.start("sleep", {"30"});
        tracked.waitForStarted();
        ChildGuard::track(&tracked, "sleep");
        reg.open(QIODevice::ReadOnly);
        const QString line = QString::fromUtf8(reg.readAll());
        reg.close();
        check(line.contains(QString::number(tracked.processId())), "track() records the pid");
        const qint64 trackedPid = tracked.processId();   // processId() is 0 once it has exited
        tracked.kill();
        tracked.waitForFinished(2000);
        spin(100);
        reg.open(QIODevice::ReadOnly);
        check(!reg.readAll().contains(QByteArray::number(trackedPid) + ' '), "finished processes drop out of the registry");
        reg.close();
    }

    std::printf("\n%s (%d failed)\n", fails ? "FAILED" : "ALL PASSED", fails);
    return fails ? 1 : 0;
}
