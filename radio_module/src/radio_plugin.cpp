#include "radio_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include <QDebug>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QNetworkInterface>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QTcpSocket>
#include <QJsonArray>
#include <QSysInfo>
#include <QUrl>
#include <QRegularExpression>
#include <csignal>
#include <sys/prctl.h>

namespace {
// Make a spawned child receive SIGKILL if THIS process (logos_host) dies — otherwise a
// kill -9 of the module (e.g. during relaunch) orphans mediamtx/ffplay, leaking the ports.
void dieWithParent(QProcess* p) { p->setChildProcessModifier([]{ ::prctl(PR_SET_PDEATHSIG, SIGKILL); }); }
}

// Uniform JSON return shape so the QML bridge is stable. Implemented per-issue
// (see docs/plans/radio-implementation.md); remaining methods are stubs.

namespace {
QString ok(const QString& extra = QString())
{
    return extra.isEmpty() ? QStringLiteral("{\"ok\":true}")
                           : QStringLiteral("{\"ok\":true,%1}").arg(extra);
}
QString err(const QString& code)
{
    return QStringLiteral("{\"ok\":false,\"error\":\"%1\"}").arg(code);
}
QString notImplemented(const QString& method)
{
    return QStringLiteral("{\"ok\":false,\"error\":\"not_implemented\",\"method\":\"%1\"}").arg(method);
}
} // namespace

RadioModulePlugin::RadioModulePlugin(QObject* parent) : QObject(parent)
{
    qDebug() << "RadioModulePlugin: constructed";
    // #10 heartbeat: re-announce on a fixed interval while streaming.
    connect(&m_heartbeat, &QTimer::timeout, this, [this]{ announceOnce(); });
    // Status pill: poll delivery_module reachability.
    connect(&m_deliveryHealth, &QTimer::timeout, this, [this]{ checkDeliveryHealth(); });
    // Onion mode: poll for the hidden-service hostname + descriptor publish.
    connect(&m_onionPublishPoll, &QTimer::timeout, this, [this]{ pollOnionStatus(); });
}

RadioModulePlugin::~RadioModulePlugin()
{
    qDebug() << "RadioModulePlugin: destroyed";
    killMediaMtx();  // never leak the origin process
    killPlayer();
    killTor();
}

void RadioModulePlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;  // base PluginInterface member — ModuleProxy reads this for IPC. Do NOT shadow it.
    qDebug() << "RadioModulePlugin: initLogos";
    // Start the delivery-health poll deferred (skill ipc-client-eager-init: don't getClient in initLogos directly).
    QTimer::singleShot(2500, this, [this]{ checkDeliveryHealth(); m_deliveryHealth.start(5000); });
    emit eventResponse("initialized", QVariantList() << "radio_module" << "0.1.0");
}

QString RadioModulePlugin::ping() { return ok("\"version\":\"0.1.0\""); }

// ---------------------------------------------------------------------------
// #2 spawn + #3 mint — start/stop the MediaMTX origin and return the OBS card.
// ---------------------------------------------------------------------------

int RadioModulePlugin::port(const char* envVar, int fallback) const
{
    bool ok = false;
    const int v = qEnvironmentVariableIntValue(envVar, &ok);
    return ok && v > 0 ? v : fallback;
}

QString RadioModulePlugin::randomHex(int bytes)
{
    QByteArray b(bytes, Qt::Uninitialized);
    for (int i = 0; i < bytes; ++i)
        b[i] = static_cast<char>(QRandomGenerator::system()->bounded(256));
    return QString::fromLatin1(b.toHex());
}

QString RadioModulePlugin::lanIp() const
{
    for (const QHostAddress& a : QNetworkInterface::allAddresses()) {
        if (a.protocol() == QAbstractSocket::IPv4Protocol && !a.isLoopback())
            return a.toString();
    }
    return QStringLiteral("127.0.0.1");
}

QString RadioModulePlugin::writeMediaMtxConfig() const
{
    // Per-stream runtime dir under temp (module is sandboxed; temp is writable).
    QFile cfg(m_runtimeDir + "/mediamtx.yml");
    if (!QDir().mkpath(m_runtimeDir) || !cfg.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return QString();

    // `paths: all_others` is REQUIRED — an empty config rejects arbitrary paths (#2 spike).
    // #18 auth: HLS read is public; publishing requires the secret key; the local API is
    // localhost-only (verified 2026-06-10). This stops anyone on the topic hijacking the stream.
    QTextStream s(&cfg);
    s << "rtmpAddress: :"   << port("RADIO_RTMP_PORT", 1935) << "\n"
      << "hlsAddress: :"    << port("RADIO_HLS_PORT",  8888) << "\n"
      << "webrtcAddress: :" << port("RADIO_WHIP_PORT", 8889) << "\n"
      << "srtAddress: :"    << port("RADIO_SRT_PORT",  8890) << "\n"
      << "apiAddress: :"    << port("RADIO_API_PORT",  9997) << "\n"
      << "api: yes\n"
      << "hls: yes\n"
      << "hlsVariant: lowLatency\n"
      << "webrtc: yes\n"   // WHIP ingest endpoint (OBS 30+)
      << "srt: yes\n"
      << "rtsp: no\n"
      << "authInternalUsers:\n"
      << "- user: any\n"
      << "  permissions:\n"
      << "  - action: read\n"          // public HLS playback for listeners
      << "- user: any\n"
      << "  ips: ['127.0.0.1', '::1']\n"
      << "  permissions:\n"
      << "  - action: api\n"           // local status polling only
      << "- user: publisher\n"
      << "  pass: " << m_streamKey << "\n"
      << "  permissions:\n"
      << "  - action: publish\n"       // OBS must present the secret key
      << "paths:\n"
      << "  all_others:\n";
    return cfg.fileName();
}

QString RadioModulePlugin::spawnMediaMtx(const QString& configPath)
{
    killMediaMtx();
    const QString bin = qEnvironmentVariable("RADIO_MEDIAMTX_BIN", QStringLiteral("mediamtx"));
    m_mediamtx = new QProcess(this);
    m_mediamtx->setProcessChannelMode(QProcess::MergedChannels);
    dieWithParent(m_mediamtx);   // #15/ops: don't orphan + leak ports on kill -9
    m_mediamtx->start(bin, QStringList() << configPath);
    if (!m_mediamtx->waitForStarted(5000)) {
        const bool notFound = m_mediamtx->error() == QProcess::FailedToStart;
        qWarning() << "RadioModulePlugin: mediamtx failed to start:" << m_mediamtx->errorString();
        killMediaMtx();
        return notFound ? QStringLiteral("mediamtx_not_found") : QStringLiteral("mediamtx_spawn_failed");
    }
    // Immediate exit ⇒ bad config or a port already in use (#15 surfaces this to the UI).
    if (m_mediamtx->waitForFinished(400)) {
        qWarning() << "RadioModulePlugin: mediamtx exited immediately:" << m_mediamtx->readAll();
        killMediaMtx();
        return QStringLiteral("mediamtx_port_or_config");
    }
    return QString();
}

void RadioModulePlugin::killMediaMtx()
{
    if (!m_mediamtx) return;
    m_mediamtx->terminate();
    if (!m_mediamtx->waitForFinished(3000))
        m_mediamtx->kill();
    m_mediamtx->deleteLater();
    m_mediamtx = nullptr;
}

QString RadioModulePlugin::startStream(const QString& configJson)
{
    if (m_mediamtx) return err("already_streaming");

    const QJsonObject cfg = QJsonDocument::fromJson(configJson.toUtf8()).object();
    m_streamName  = cfg.value("name").toString();
    if (m_streamName.isEmpty()) return err("name_required");
    m_visibility  = cfg.value("visibility").toString(QStringLiteral("public"));
    m_description = cfg.value("description").toString();
    // Privacy mode (epic: hide streamer IP). "onion" → announce a .onion URL instead of lanIp().
    m_privacy     = cfg.value("privacy").toString(QStringLiteral("public"));

    m_path       = randomHex(8);   // 64-bit public stream id
    m_streamKey  = randomHex(16);  // 128-bit secret publish credential (#18)
    m_runtimeDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                   + "/radio_module/" + m_path;
    m_startedAt   = QDateTime::currentMSecsSinceEpoch();
    m_announceSeq = 0;
    m_hostLabel   = QSysInfo::machineHostName();
    // Public → directory topic; private → unguessable per-stream topic (shared out-of-band).
    m_announceTopic = (m_visibility == "private")
                      ? QStringLiteral("/radio-basecamp/1/%1/json").arg(m_path)
                      : directoryTopic();

    const QString configPath = writeMediaMtxConfig();
    if (configPath.isEmpty()) return err("config_write_failed");
    const QString spawnErr = spawnMediaMtx(configPath);
    if (!spawnErr.isEmpty()) return err(spawnErr);

    // Onion mode: bring up a tor hidden service for the HLS port. The .onion + readiness arrive
    // asynchronously (descriptor publish ~30-60s); announceOnce gates on it so no IP is ever sent.
    if (m_privacy == "onion") {
        m_onion.clear(); m_onionReady = false;
        if (!ensureTor(true)) { killMediaMtx(); return err("tor_failed"); }
    }

    const QString ip = lanIp();
    const int hls = port("RADIO_HLS_PORT", 8888), whip = port("RADIO_WHIP_PORT", 8889),
              rtmp = port("RADIO_RTMP_PORT", 1935), srt = port("RADIO_SRT_PORT", 8890);
    const QString auth = QStringLiteral("user=publisher&pass=%1").arg(m_streamKey);

    QJsonObject card{
        {"ok", true},
        {"path", m_path},
        {"streamKey", QStringLiteral("%1?%2").arg(m_path, auth)},  // OBS RTMP "Stream Key" (path + auth)
        {"whipUrl", QStringLiteral("http://%1:%2/%3/whip?%4").arg(ip).arg(whip).arg(m_path).arg(auth)},
        {"rtmpUrl", QStringLiteral("rtmp://%1:%2").arg(ip).arg(rtmp)},  // OBS RTMP "Server"
        {"srtUrl",  QStringLiteral("srt://%1:%2?streamid=publish:%3:publisher:%4").arg(ip).arg(srt).arg(m_path).arg(m_streamKey)},
        {"hlsUrl",  QStringLiteral("http://%1:%2/%3/index.m3u8").arg(ip).arg(hls).arg(m_path)},  // public (read-only)
    };
    m_heartbeat.start(port("RADIO_HEARTBEAT_MS", 15000));  // #10 re-announce while live
    qDebug() << "RadioModulePlugin: stream started, path" << m_path;
    emit eventResponse("streamStarted", QVariantList() << m_path);
    return QString::fromUtf8(QJsonDocument(card).toJson(QJsonDocument::Compact));
}

QString RadioModulePlugin::stopStream()
{
    if (!m_mediamtx) return err("not_streaming");
    m_heartbeat.stop();
    killMediaMtx();
    // Tear down the hidden service (a listener-side tor for playback, if any, is separate).
    if (m_privacy == "onion") killTor();
    if (!m_runtimeDir.isEmpty()) QDir(m_runtimeDir).removeRecursively();
    qDebug() << "RadioModulePlugin: stream stopped";
    emit eventResponse("streamStopped", QVariantList() << m_path);
    m_path.clear(); m_streamKey.clear(); m_streamName.clear(); m_lastStreamState.clear();
    m_announceTopic.clear(); m_startedAt = 0; m_announceSeq = 0;
    m_privacy = QStringLiteral("public"); m_onion.clear(); m_onionReady = false;
    return ok();
}

// ---------------------------------------------------------------------------
// #4 — poll MediaMTX for live status.
// ---------------------------------------------------------------------------

int RadioModulePlugin::httpGet(int apiPort, const QString& path, QString& bodyOut) const
{
    QTcpSocket sock;
    sock.connectToHost(QHostAddress::LocalHost, static_cast<quint16>(apiPort));
    if (!sock.waitForConnected(800)) return -1;
    sock.write(QStringLiteral("GET %1 HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                   .arg(path).toUtf8());
    if (!sock.waitForBytesWritten(800)) return -1;
    QByteArray raw;
    while (sock.state() == QAbstractSocket::ConnectedState && sock.waitForReadyRead(800))
        raw += sock.readAll();
    raw += sock.readAll();
    const int sep = raw.indexOf("\r\n\r\n");
    bodyOut = sep >= 0 ? QString::fromUtf8(raw.mid(sep + 4)) : QString();
    // status line: "HTTP/1.0 200 OK"
    const QByteArray status = raw.left(raw.indexOf("\r\n"));
    const auto parts = status.split(' ');
    return parts.size() >= 2 ? parts[1].toInt() : -1;
}

QString RadioModulePlugin::streamState()
{
    if (!m_mediamtx) return QStringLiteral("idle");
    QString body;
    const int code = httpGet(port("RADIO_API_PORT", 9997),
                             QStringLiteral("/v3/paths/get/%1").arg(m_path), body);
    if (code != 200) return QStringLiteral("waiting");  // path not created → OBS not connected
    const QJsonObject p = QJsonDocument::fromJson(body.toUtf8()).object();
    const bool ready = p.value("ready").toBool();
    const bool hasSource = !p.value("source").isNull() && p.value("source").isObject();
    const bool hasTracks = !p.value("tracks").toArray().isEmpty();
    return (ready && hasTracks) ? QStringLiteral("live")
         : hasSource           ? QStringLiteral("receiving")
                               : QStringLiteral("waiting");
}

QString RadioModulePlugin::getStreamStatus()
{
    const QString state = streamState();
    QJsonObject r{{"ok", true}, {"state", state}};
    if (m_mediamtx) {
        r["privacy"] = m_privacy;
        if (m_privacy == "onion") {
            // Never surface lanIp() in onion mode — advertise the .onion (once known) or nothing.
            r["onion"] = m_onion;              // "" until the hostname appears
            r["onionReady"] = m_onionReady;    // false until the descriptor is published
            if (!m_onion.isEmpty())
                r["hlsUrl"] = QStringLiteral("http://%1/%2/index.m3u8").arg(m_onion, m_path);
        } else {
            r["hlsUrl"] = QStringLiteral("http://%1:%2/%3/index.m3u8")
                              .arg(lanIp()).arg(port("RADIO_HLS_PORT", 8888)).arg(m_path);
        }
    }
    if (state != m_lastStreamState) {
        m_lastStreamState = state;
        emit eventResponse("streamStatusChanged", QVariantList() << state);
    }
    return QString::fromUtf8(QJsonDocument(r).toJson(QJsonDocument::Compact));
}

// ---------------------------------------------------------------------------
// #5 — discovery: init delivery_module, subscribe, receive + decode announces.
// Wiring mirrors the proven scorched-earth pattern (game_plugin.cpp). delivery_module
// base64-encodes once on send, so messageReceived data[2] needs a single decode.
// ---------------------------------------------------------------------------

QString RadioModulePlugin::directoryTopic() const
{
    // delivery_module content-topic convention: /<module>/1/<channel>/<format>
    return qEnvironmentVariable("RADIO_DIRECTORY_TOPIC",
                                QStringLiteral("/radio-basecamp/1/directory/json"));
}

bool RadioModulePlugin::subscribeTopic(const QString& topic)
{
    if (topic.isEmpty() || !m_delivery) return false;
    if (m_subscribedTopics.contains(topic)) return true;
    m_delivery->invokeRemoteMethod("delivery_module", "subscribe", topic);
    m_subscribedTopics.insert(topic);
    return true;
}

bool RadioModulePlugin::ensureDeliveryNode()
{
    if (m_deliveryNodeUp) return true;
    if (!logosAPI) return false;
    m_delivery = logosAPI->getClient("delivery_module");
    if (!m_delivery) return false;
    m_delivery->invokeRemoteMethod("delivery_module", "createNode",
        QStringLiteral("{\"logLevel\":\"INFO\",\"mode\":\"Core\",\"preset\":\"logos.dev\",\"relay\":true}"));
    m_delivery->invokeRemoteMethod("delivery_module", "start");
    m_deliveryNodeUp = true;
    // Cache our peer id once for the status pill (avoids per-poll IPC).
    const QVariant pid = m_delivery->invokeRemoteMethod("delivery_module", "getNodeInfo", QStringLiteral("MyPeerId"));
    const QJsonObject po = QJsonDocument::fromJson(pid.toString().toUtf8()).object();
    if (po.value("success").toBool()) m_deliveryPeerId = po.value("value").toString();
    return true;
}

void RadioModulePlugin::checkDeliveryHealth()
{
    auto* c = logosAPI ? logosAPI->getClient("delivery_module") : nullptr;
    if (!c) { m_deliveryReachable = false; return; }
    // The delivery_module node comes up on its own at load; ask for our peer id to confirm it answers.
    const QVariant r = c->invokeRemoteMethod("delivery_module", "getNodeInfo", QStringLiteral("MyPeerId"));
    const QJsonObject o = QJsonDocument::fromJson(r.toString().toUtf8()).object();
    const QString pid = o.value("value").toString();
    m_deliveryReachable = o.value("success").toBool() && !pid.isEmpty();
    if (m_deliveryReachable) m_deliveryPeerId = pid;
}

QString RadioModulePlugin::getDeliveryStatus()
{
    const bool loaded = logosAPI && logosAPI->getClient("delivery_module") != nullptr;
    // Green once delivery_module's node actually answers (reachable) or our own node is up.
    const QString state = !loaded ? QStringLiteral("offline")
                        : (m_deliveryReachable || m_deliveryNodeUp) ? QStringLiteral("connected")
                                                                    : QStringLiteral("ready");
    return QString::fromUtf8(QJsonDocument(QJsonObject{
        {"ok", true}, {"state", state}, {"peerId", m_deliveryPeerId}
    }).toJson(QJsonDocument::Compact));
}

QString RadioModulePlugin::startDiscovery()
{
    if (m_discovering) return ok();  // idempotent; reentrancy guard
    if (!ensureDeliveryNode()) return err("no_delivery_client");

    // Register the receive handler BEFORE subscribing so no announce is missed.
    m_deliveryObj = m_delivery->requestObject("delivery_module");
    if (m_deliveryObj) {
        m_delivery->onEvent(m_deliveryObj, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                if (data.size() < 3) return;
                ingestAnnounce(data[2].toString());  // data[2] = base64(payload)
            });
    }
    subscribeTopic(directoryTopic());
    m_discovering = true;
    qDebug() << "RadioModulePlugin: discovery started on" << directoryTopic();
    return ok();
}

QString RadioModulePlugin::addTopic(const QString& topic)
{
    // #18: validate the user-supplied content topic first (before state/IPC).
    static const QRegularExpression re(QStringLiteral("^/[A-Za-z0-9._/-]{1,128}$"));
    if (!re.match(topic).hasMatch()) return err("invalid_topic");
    if (!m_discovering) return err("discovery_not_started");
    return subscribeTopic(topic) ? ok() : err("subscribe_failed");
}

void RadioModulePlugin::ingestAnnounce(const QString& base64Payload)
{
    const QByteArray json = QByteArray::fromBase64(base64Payload.toUtf8());  // single decode
    const QJsonObject o = QJsonDocument::fromJson(json).object();
    const QString path = o.value("path").toString();
    if (path.isEmpty() || o.value("name").toString().isEmpty()) return;  // malformed
    if (!m_path.isEmpty() && path == m_path) return;                     // self-echo filter

    QJsonObject station = o;
    station["_lastSeen"] = QDateTime::currentMSecsSinceEpoch();  // TTL pruning → #11
    const bool isNew = !m_stations.contains(path);
    m_stations[path] = station;
    if (isNew) qDebug() << "RadioModulePlugin: discovered station" << path;
    emit eventResponse("stationsChanged", QVariantList() << path);
}

QString RadioModulePlugin::getStations()
{
    // #11 TTL: drop stations not re-heard within the window (default 45s = 3 missed 15s beats).
    const qint64 ttl = port("RADIO_TTL_MS", 45000);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    bool pruned = false;
    for (auto it = m_stations.begin(); it != m_stations.end(); ) {
        if (now - static_cast<qint64>(it.value().value("_lastSeen").toDouble()) > ttl) {
            it = m_stations.erase(it); pruned = true;
        } else { ++it; }
    }
    if (pruned) emit eventResponse("stationsChanged", QVariantList() << "expired");

    QJsonArray arr;
    for (const QJsonObject& s : m_stations) arr.append(s);
    return QString::fromUtf8(QJsonDocument(QJsonObject{{"ok", true}, {"stations", arr}})
                                 .toJson(QJsonDocument::Compact));
}

// ---------------------------------------------------------------------------
// #6 — host announce: build the schema payload, gate on live status, publish.
// ---------------------------------------------------------------------------

QString RadioModulePlugin::buildAnnouncePayload(int seq) const
{
    // Onion mode advertises the .onion (no IP, hidden service maps :80); else the direct LAN URL.
    const QString hls = (m_privacy == "onion" && !m_onion.isEmpty())
        ? QStringLiteral("http://%1/%2/index.m3u8").arg(m_onion, m_path)
        : QStringLiteral("http://%1:%2/%3/index.m3u8").arg(lanIp()).arg(port("RADIO_HLS_PORT", 8888)).arg(m_path);
    const QJsonObject a{
        {"v", 1}, {"name", m_streamName}, {"host", m_hostLabel}, {"path", m_path},
        {"streamUrl", hls}, {"visibility", m_visibility}, {"description", m_description},
        {"startedAt", m_startedAt}, {"seq", seq}
    };
    return QString::fromUtf8(QJsonDocument(a).toJson(QJsonDocument::Compact));
}

QString RadioModulePlugin::announceOnce()
{
    ++m_announceAttempts;  // #10 heartbeat observability (counts every call incl. timer fires)
    auto result = [](bool announced, const QString& reason, const QString& payload, int seq) {
        QJsonObject r{{"ok", true}, {"announced", announced}};
        if (!reason.isEmpty())  r["reason"]  = reason;
        if (!payload.isEmpty()) r["payload"] = QJsonDocument::fromJson(payload.toUtf8()).object();
        if (announced)          r["seq"]     = seq;
        return QString::fromUtf8(QJsonDocument(r).toJson(QJsonDocument::Compact));
    };
    // Gate: only announce once the origin is actually receiving the stream (#4).
    const QString state = streamState();
    if (state != "live" && state != "receiving")
        return result(false, "not_live", QString(), 0);
    // Onion mode: never announce until the hidden-service descriptor is published — otherwise we'd
    // either send a dead URL or (if onion is empty) fall back to the LAN IP, defeating the point.
    if (m_privacy == "onion" && !m_onionReady)
        return result(false, "onion_not_ready", QString(), 0);

    const QString payload = buildAnnouncePayload(m_announceSeq);
    if (!ensureDeliveryNode())
        return result(false, "no_delivery", payload, 0);  // gate passed; delivery just unavailable

    m_delivery->invokeRemoteMethod("delivery_module", "send", m_announceTopic, payload);
    const int seq = m_announceSeq++;
    qDebug() << "RadioModulePlugin: announced seq" << seq << "on" << m_announceTopic;
    return result(true, QString(), payload, seq);
}

// ---------------------------------------------------------------------------
// #9 — listener playback via ffplay subprocess (Qt Multimedia not in AppImage).
// ---------------------------------------------------------------------------

void RadioModulePlugin::killPlayer()
{
    if (!m_player) return;
    m_player->terminate();
    if (!m_player->waitForFinished(2000)) m_player->kill();
    m_player->deleteLater();
    m_player = nullptr;
}

QString RadioModulePlugin::startFfplay()
{
    killPlayer();
    // A .onion stream needs a local tor SOCKS proxy (no hidden service for listening).
    if (QUrl(m_playingUrl).host().endsWith(QLatin1String(".onion")) && !ensureTor(false))
        return QStringLiteral("tor_failed");
    const QPair<QString, QStringList> cmd = buildPlayerCommand(m_playingUrl);
    m_player = new QProcess(this);
    dieWithParent(m_player);
    m_player->start(cmd.first, cmd.second);
    if (!m_player->waitForStarted(5000)) {
        const bool notFound = m_player->error() == QProcess::FailedToStart;
        qWarning() << "RadioModulePlugin: player failed:" << m_player->errorString();
        killPlayer();
        return notFound ? QStringLiteral("ffplay_not_found") : QStringLiteral("ffplay_failed");
    }
    return QString();
}

// ---------------------------------------------------------------------------
// Tor onion mode — hide the streamer's IP (epic: docs/plans/tor-onion.md).
// One tor process serves SocksPort (listening over Tor) and, in onion host mode,
// a HiddenService mapping :80 → the local MediaMTX HLS port.
// ---------------------------------------------------------------------------

QPair<QString, QStringList> RadioModulePlugin::buildPlayerCommand(const QString& url) const
{
    const QString ffplay = qEnvironmentVariable("RADIO_FFPLAY_BIN", QStringLiteral("ffplay"));
    QStringList ffargs;
    ffargs << "-nodisp" << "-autoexit" << "-loglevel" << "error"
           << "-volume" << QString::number(m_volume) << url;
    // ffmpeg has no native SOCKS; route .onion playback through torsocks (LD_PRELOAD → tor SOCKS).
    if (QUrl(url).host().endsWith(QLatin1String(".onion"))) {
        const QString torsocks = qEnvironmentVariable("RADIO_TORSOCKS_BIN", QStringLiteral("torsocks"));
        return { torsocks, QStringList() << ffplay << ffargs };
    }
    return { ffplay, ffargs };
}

bool RadioModulePlugin::ensureTor(bool withHiddenService)
{
    if (m_tor && m_tor->state() == QProcess::Running) {
        if (!withHiddenService || !m_onion.isEmpty()) return true;
        killTor();  // running without a HS but we now need one → restart with it
    }
    const QString bin = qEnvironmentVariable("RADIO_TOR_BIN", QStringLiteral("tor"));
    m_torDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
               + "/radio_module/tor-" + (m_path.isEmpty() ? randomHex(4) : m_path);
    const QString dataDir = m_torDir + "/data", hsDir = m_torDir + "/hs",
                  logFile = m_torDir + "/tor.log", torrc = m_torDir + "/torrc";
    if (!QDir().mkpath(dataDir)) return false;

    QString cfg;
    QTextStream s(&cfg);
    s << "SocksPort " << torSocksPort() << "\n"
      << "DataDirectory " << dataDir << "\n"
      << "Log notice file " << logFile << "\n";
    if (withHiddenService) {
        QDir().mkpath(hsDir);
        QFile::setPermissions(hsDir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
        s << "HiddenServiceDir " << hsDir << "\n"
          << "HiddenServicePort 80 127.0.0.1:" << port("RADIO_HLS_PORT", 8888) << "\n";
    }
    QFile f(torrc);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    f.write(cfg.toUtf8()); f.close();

    m_tor = new QProcess(this);
    m_tor->setProcessChannelMode(QProcess::MergedChannels);
    dieWithParent(m_tor);   // don't orphan tor on kill -9
    m_tor->start(bin, QStringList() << "-f" << torrc);
    if (!m_tor->waitForStarted(5000)) {
        qWarning() << "RadioModulePlugin: tor failed to start:" << m_tor->errorString();
        killTor();
        return false;
    }
    if (withHiddenService) {
        // hostname + descriptor publish are async — pollOnionStatus() reads them off disk/log.
        m_onion.clear(); m_onionReady = false;
        m_onionPublishPoll.start(2000);
    }
    return true;
}

void RadioModulePlugin::pollOnionStatus()
{
    if (m_torDir.isEmpty()) return;
    if (m_onion.isEmpty()) {
        QFile hf(m_torDir + "/hs/hostname");
        if (hf.open(QIODevice::ReadOnly)) { m_onion = QString::fromUtf8(hf.readAll()).trimmed(); hf.close(); }
    }
    if (!m_onion.isEmpty() && !m_onionReady) {
        QFile lf(m_torDir + "/tor.log");
        if (lf.open(QIODevice::ReadOnly)) {
            const QString log = QString::fromUtf8(lf.readAll()); lf.close();
            // tor logs e.g. "Uploaded rendezvous descriptor" / "Successfully uploaded …" on publish.
            if (log.contains(QLatin1String("uploaded"), Qt::CaseInsensitive)
                && log.contains(QLatin1String("descriptor"), Qt::CaseInsensitive)) {
                m_onionReady = true;
                m_onionPublishPoll.stop();
                qDebug() << "RadioModulePlugin: onion descriptor published — reachable";
                emit eventResponse("onionReady", QVariantList() << m_path);  // host id, not the .onion
            }
        }
    }
}

void RadioModulePlugin::killTor()
{
    m_onionPublishPoll.stop();
    if (m_tor) {
        m_tor->terminate();
        if (!m_tor->waitForFinished(3000)) m_tor->kill();
        m_tor->deleteLater();
        m_tor = nullptr;
    }
    if (!m_torDir.isEmpty()) { QDir(m_torDir).removeRecursively(); m_torDir.clear(); }
    m_onion.clear(); m_onionReady = false;
}

// --- Test seams (not IPC API) ---
void RadioModulePlugin::configureOnionForTest(const QString& onion)
{
    m_privacy = QStringLiteral("onion");
    m_onion = onion;
    m_onionReady = !onion.isEmpty();
}

QStringList RadioModulePlugin::playerCommandForTest(const QString& url) const
{
    const QPair<QString, QStringList> c = buildPlayerCommand(url);
    return QStringList() << c.first << c.second;
}

QString RadioModulePlugin::play(const QString& hlsUrl, const QString& stationName)
{
    if (hlsUrl.isEmpty()) return err("no_url");
    // #18: a station's streamUrl is attacker-controlled (anyone can announce). Only let ffplay
    // open http/https — never file:, pipe:, concat:, a device, or other ffmpeg protocols.
    const QString scheme = QUrl(hlsUrl).scheme().toLower();
    if (scheme != "http" && scheme != "https") return err("unsafe_url");
    m_playingUrl = hlsUrl;
    m_playingStation = stationName;
    const QString e = startFfplay();
    if (!e.isEmpty()) { m_playingUrl.clear(); m_playingStation.clear(); return err(e); }
    emit eventResponse("playerStatusChanged", QVariantList() << "playing" << stationName);
    return ok();
}

QString RadioModulePlugin::setVolume(int percent)  // #13 — ffplay has no runtime volume; restart
{
    m_volume = qBound(0, percent, 100);
    if (m_player) startFfplay();  // brief gap; live HLS reconnects at the edge
    return QString::fromUtf8(QJsonDocument(QJsonObject{{"ok", true}, {"volume", m_volume}})
                                 .toJson(QJsonDocument::Compact));
}

QString RadioModulePlugin::stop()
{
    if (!m_player) return err("not_playing");
    killPlayer();
    m_playingStation.clear();
    m_playingUrl.clear();
    emit eventResponse("playerStatusChanged", QVariantList() << "stopped");
    return ok();
}

QString RadioModulePlugin::getPlayerStatus()
{
    const bool running = m_player && m_player->state() != QProcess::NotRunning;
    return QString::fromUtf8(QJsonDocument(QJsonObject{
        {"ok", true}, {"state", running ? "playing" : "stopped"},
        {"station", m_playingStation}, {"volume", m_volume}
    }).toJson(QJsonDocument::Compact));
}
