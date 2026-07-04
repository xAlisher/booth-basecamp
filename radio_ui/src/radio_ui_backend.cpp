#include "radio_ui_backend.h"
#include "logos_sdk.h"        // generated: modules().radio_module (Qt-typed)
#include "logos_types.h"

#include <QDateTime>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>

namespace {
// ui-host child stderr is swallowed (basecamp#163) — trail to a file for headless diagnosis.
void diag(const QString& m) {
    QFile f(QStringLiteral("/tmp/radio-diag.log"));
    if (f.open(QIODevice::Append | QIODevice::WriteOnly)) {
        f.write((QDateTime::currentDateTime().toString("HH:mm:ss.zzz") + "  " + m + "\n").toUtf8());
        f.close();
    }
}
QJsonObject parseObj(const QString& json) { return QJsonDocument::fromJson(json.toUtf8()).object(); }
}

RadioUiBackend::RadioUiBackend(QObject* parent)
    : RadioUiSimpleSource(parent) {}

void RadioUiBackend::onContextReady()
{
    diag(QStringLiteral("onContextReady: modules() wired"));
    m_poll = new QTimer(this);
    m_poll->setInterval(1500);
    QObject::connect(m_poll, &QTimer::timeout, this, &RadioUiBackend::poll);
    m_poll->start();
    poll();
}

void RadioUiBackend::poll()
{
    if (!isContextReady()) return;
    // Async getters — radio_module is a running core with quick getters, so the reply should fire
    // (unlike receiver's reply-gated createNode). If it doesn't, switch to a side channel (fork-tree).
    modules().radio_module.getDeliveryStatusAsync(
        [this](LogosResult r){ if (r.success) applyDeliveryStatus(r.getString()); }, Timeout());
    modules().radio_module.getStreamStatusAsync(
        [this](LogosResult r){ if (r.success) applyStreamStatus(r.getString()); }, Timeout());
    modules().radio_module.getStreamCardAsync(
        [this](LogosResult r){ if (r.success) applyStreamCard(r.getString()); }, Timeout());
}

void RadioUiBackend::applyDeliveryStatus(const QString& json)
{
    const QJsonObject o = parseObj(json);
    if (!o.value(QStringLiteral("ok")).toBool(true)) return;
    if (o.contains(QStringLiteral("state"))) setDeliveryState(o.value(QStringLiteral("state")).toString());
}

void RadioUiBackend::applyStreamStatus(const QString& json)
{
    const QJsonObject o = parseObj(json);
    if (o.contains(QStringLiteral("state")))      setStreamState(o.value(QStringLiteral("state")).toString());
    if (o.contains(QStringLiteral("privacy")))    setStreamPrivacy(o.value(QStringLiteral("privacy")).toString());
    if (o.contains(QStringLiteral("onion")))      setOnionAddr(o.value(QStringLiteral("onion")).toString());
    if (o.contains(QStringLiteral("onionReady"))) setOnionReady(o.value(QStringLiteral("onionReady")).toBool());
    setOnionError(o.value(QStringLiteral("onionError")).toString());
}

void RadioUiBackend::applyStreamCard(const QString& json)
{
    const QJsonObject o = parseObj(json);
    // getStreamCard returns {ok:false} when there's no live card → clear; else the card JSON drives the UI.
    setStreamCardJson(o.value(QStringLiteral("ok")).toBool(false) ? json : QString());
}

// ── mutators: fire-and-forget (SLOT returns immediately; state lands via the poll PROPs) ──────────
QString RadioUiBackend::startStream(QString configJson)
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    diag(QStringLiteral("startStream: fire-and-forget (spawns MediaMTX)"));
    modules().radio_module.startStreamAsync(configJson,
        [this](LogosResult r){ diag(QStringLiteral("startStream cb ok=%1").arg(r.success));
                               if (r.success) emit activity(QStringLiteral("Stream started")); }, Timeout());
    emit activity(QStringLiteral("Starting stream…"));
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::stopStream()
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    modules().radio_module.stopStreamAsync([this](LogosResult){ }, Timeout());
    setStreamCardJson(QString());
    emit activity(QStringLiteral("Stream stopped"));
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::regenerateKey()
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    modules().radio_module.regenerateKeyAsync(
        [this](LogosResult){ emit activity(QStringLiteral("Stream key rotated — re-enter it in OBS")); }, Timeout());
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::regenerateOnion()
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    diag(QStringLiteral("regenerateOnion: fire-and-forget (spawns tor)"));
    modules().radio_module.regenerateOnionAsync(
        [this](LogosResult){ emit activity(QStringLiteral("Rotating Tor address — listeners will rediscover")); }, Timeout());
    setOnionReady(false); setOnionAddr(QString());
    return QStringLiteral("{\"ok\":true}");
}
