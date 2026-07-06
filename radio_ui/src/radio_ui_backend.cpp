#include "radio_ui_backend.h"
#include "logos_sdk.h"        // generated: modules().radio_module (Qt-typed)
#include "logos_types.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QStringList>
#include <QJsonArray>
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

// #53 Resolve a broadcast helper: env override → bare name on PATH (mirrors radio_module's resolveBin +
// its RADIO_*_BIN override names, so detection matches what radio_module actually spawns).
QString resolveBin(const QString& name, const char* envVar) {
    const QString env = qEnvironmentVariable(envVar);
    return env.isEmpty() ? name : env;
}
}

RadioUiBackend::RadioUiBackend(QObject* parent)
    : RadioUiSimpleSource(parent)
{
    // #8 restore the last-selected identity tier (no IPC — safe in the constructor).
    QSettings s{QStringLiteral("logos"), QStringLiteral("radio_ui")};
    setIdentityTier(qBound(0, s.value(QStringLiteral("identityTier"), 1).toInt(), 2));
    publishDeps();   // #53 preflight the broadcast helpers so the welcome card is correct on first paint
}

QString RadioUiBackend::checkDeps()
{
    publishDeps();
    return QStringLiteral("{\"ok\":true}");   // Re-check just refreshes the depsJson PROP the card binds to
}

// #53 Detect the external broadcast helpers on PATH and publish the JSON the first-launch card reads.
// radio_module spawns mediamtx (stream server), tor (onion host), ffplay + torsocks (listen-back preview).
// Honors the RADIO_*_BIN overrides (absolute path counts as present iff it exists+executable, else PATH).
// Key wrinkle: **mediamtx is not an apt package** → Linux install splits into an apt line + a mediamtx line
// (nix/release); macOS `brew` has all of them. We never auto-install.
void RadioUiBackend::publishDeps()
{
    struct Req { const char* bin; const char* env; const char* pkg; };
#ifdef __APPLE__
    const QString os = QStringLiteral("macos");
    const QList<Req> reqs = {   // no torsocks on mac (SIP); radio_module has no mac privoxy branch
        { "mediamtx", "RADIO_MEDIAMTX_BIN", "mediamtx" },
        { "tor",      "RADIO_TOR_BIN",      "tor"      },
        { "ffplay",   "RADIO_FFPLAY_BIN",   "ffmpeg"   },
    };
#else
    const QString os = QStringLiteral("linux");
    const QList<Req> reqs = {
        { "mediamtx", "RADIO_MEDIAMTX_BIN", "mediamtx" },   // NOT in apt
        { "tor",      "RADIO_TOR_BIN",      "tor"      },
        { "ffplay",   "RADIO_FFPLAY_BIN",   "ffmpeg"   },
        { "torsocks", "RADIO_TORSOCKS_BIN", "torsocks" },
    };
#endif

    // #57 probe known install dirs even OFF the (minimal) GUI PATH → distinguish installed-but-invisible
    // from truly-missing (same as receiver-basecamp#57).
#ifdef __APPLE__
    const QStringList probeDirs = {
        QStringLiteral("/opt/homebrew/bin"), QStringLiteral("/opt/homebrew/sbin"),
        QStringLiteral("/usr/local/bin"),    QStringLiteral("/usr/local/sbin"),
        QDir::homePath() + QStringLiteral("/.nix-profile/bin"),
    };
#else
    const QStringList probeDirs = {
        QStringLiteral("/usr/bin"), QStringLiteral("/usr/local/bin"), QStringLiteral("/usr/local/sbin"),
        QDir::homePath() + QStringLiteral("/.nix-profile/bin"),
        QStringLiteral("/run/current-system/sw/bin"), QStringLiteral("/snap/bin"),
    };
#endif
    auto findInDirs = [&](const QString& name) -> QString {
        for (const QString& d : probeDirs) {
            const QFileInfo fi(d + QLatin1Char('/') + name);
            if (fi.exists() && fi.isExecutable()) return fi.absoluteFilePath();
        }
        return QString();
    };

    QString pkgMgr;
#ifdef __APPLE__
    if (QFileInfo::exists(QStringLiteral("/opt/homebrew/bin/brew"))
        || QFileInfo::exists(QStringLiteral("/usr/local/bin/brew")))               pkgMgr = QStringLiteral("brew");
    else if (QFileInfo::exists(QDir::homePath() + QStringLiteral("/.nix-profile"))
        || !QStandardPaths::findExecutable(QStringLiteral("nix")).isEmpty())        pkgMgr = QStringLiteral("nix");
    else                                                                           pkgMgr = QStringLiteral("none");
#else
    if (!QStandardPaths::findExecutable(QStringLiteral("apt")).isEmpty()
        || !QStandardPaths::findExecutable(QStringLiteral("apt-get")).isEmpty())    pkgMgr = QStringLiteral("apt");
    else if (!QStandardPaths::findExecutable(QStringLiteral("dnf")).isEmpty())      pkgMgr = QStringLiteral("dnf");
    else if (!QStandardPaths::findExecutable(QStringLiteral("pacman")).isEmpty())   pkgMgr = QStringLiteral("pacman");
    else                                                                           pkgMgr = QStringLiteral("apt");
#endif

    QJsonArray items;
    QStringList missingPkgs;
    QStringList setenvLines;
    bool mediamtxMissing = false, ok = true, needsRelaunch = false;

    for (const Req& r : reqs) {
        const QString name = QString::fromLatin1(r.bin);
        const QString envOverride = qEnvironmentVariable(r.env);
        QString state, path;

        if (!envOverride.isEmpty() && QFileInfo(envOverride).isAbsolute()) {
            const QFileInfo fi(envOverride);
            if (fi.exists() && fi.isExecutable()) { state = QStringLiteral("present"); path = fi.absoluteFilePath(); }
            else                                    state = QStringLiteral("missing");
        }
        if (state.isEmpty()) {
            const QString onPath = QStandardPaths::findExecutable(name);
            if (!onPath.isEmpty()) { state = QStringLiteral("present"); path = onPath; }
            else {
                const QString off = findInDirs(name);
                if (!off.isEmpty()) { state = QStringLiteral("found_offpath"); path = off; }
                else                  state = QStringLiteral("missing");
            }
        }

        QJsonObject o;
        o.insert(QStringLiteral("name"),  name);
        o.insert(QStringLiteral("state"), state);
        if (!path.isEmpty()) o.insert(QStringLiteral("path"), path);

        if (state == QLatin1String("found_offpath")) {
#ifdef __APPLE__
            const QString cmd = QStringLiteral("launchctl setenv %1 %2").arg(QString::fromLatin1(r.env), path);
#else
            const QString cmd = QStringLiteral("export %1=%2").arg(QString::fromLatin1(r.env), path);
#endif
            o.insert(QStringLiteral("setenvCmd"), cmd);
            setenvLines << cmd;
            needsRelaunch = true; ok = false;
        } else if (state == QLatin1String("missing")) {
            const QString pkg = QString::fromLatin1(r.pkg);
            o.insert(QStringLiteral("pkg"), pkg);
            if (QLatin1String(r.bin) == QLatin1String("mediamtx")) mediamtxMissing = true;
            if (!missingPkgs.contains(pkg)) missingPkgs.append(pkg);
            ok = false;
        }
        items.append(o);
    }

    // install command for the truly-missing helpers (mediamtx is NOT in apt → split on Linux)
    QString installCmd;
    if (!missingPkgs.isEmpty()) {
#ifdef __APPLE__
        const QString pkgs = missingPkgs.join(QLatin1Char(' '));
        if (pkgMgr == QLatin1String("brew"))      installCmd = QStringLiteral("brew install ") + pkgs;   // brew has mediamtx
        else if (pkgMgr == QLatin1String("nix")) {
            QStringList nixed; for (const QString& p : missingPkgs) nixed << (QStringLiteral("nixpkgs#") + p);
            installCmd = QStringLiteral("nix profile install ") + nixed.join(QLatin1Char(' '));
        }
        else installCmd = QStringLiteral("# install Homebrew from https://brew.sh, then:\nbrew install ") + pkgs;
#else
        QStringList aptPkgs = missingPkgs; aptPkgs.removeAll(QStringLiteral("mediamtx"));   // not in apt
        QStringList lines;
        if (!aptPkgs.isEmpty()) {
            const QString pkgs = aptPkgs.join(QLatin1Char(' '));
            if (pkgMgr == QLatin1String("dnf"))         lines << (QStringLiteral("sudo dnf install -y ") + pkgs);
            else if (pkgMgr == QLatin1String("pacman")) lines << (QStringLiteral("sudo pacman -S --noconfirm ") + pkgs);
            else                                        lines << (QStringLiteral("sudo apt install -y ") + pkgs);
        }
        if (mediamtxMissing)
            lines << QStringLiteral("nix profile install nixpkgs#mediamtx   # not in apt — or grab the release binary");
        installCmd = lines.join(QLatin1Char('\n'));
#endif
    }

    QJsonObject rootObj;
    rootObj.insert(QStringLiteral("ok"),            ok);
    rootObj.insert(QStringLiteral("os"),            os);
    rootObj.insert(QStringLiteral("pkgMgr"),        pkgMgr);
    rootObj.insert(QStringLiteral("items"),         items);
    rootObj.insert(QStringLiteral("installCmd"),    installCmd);
    rootObj.insert(QStringLiteral("setenvBlock"),   setenvLines.join(QLatin1Char('\n')));
    rootObj.insert(QStringLiteral("needsRelaunch"), needsRelaunch);
    const QString json = QString::fromUtf8(QJsonDocument(rootObj).toJson(QJsonDocument::Compact));
    diag(QStringLiteral("publishDeps -> %1").arg(json));
    setDepsJson(json);
}

QString RadioUiBackend::saveIdentityTier(int idx)
{
    idx = qBound(0, idx, 2);
    QSettings{QStringLiteral("logos"), QStringLiteral("radio_ui")}.setValue(QStringLiteral("identityTier"), idx);
    setIdentityTier(idx);   // the generated PROP setter — updates the PROP the QML binds to
    return QStringLiteral("{\"ok\":true}");
}

void RadioUiBackend::onContextReady()
{
    diag(QStringLiteral("onContextReady: modules() wired"));
    publishDeps();   // #53 re-publish now the QML replica is connected (ctor-time set can precede remoting — receiver#55)
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
        [this](QString s){ static int n=0; if (n++ < 3) diag(QStringLiteral("getDeliveryStatus reply #%1: %2").arg(n).arg(s.left(60))); applyDeliveryStatus(s); }, Timeout());
    modules().radio_module.getStreamStatusAsync(
        [this](QString s){ static int m=0; if (m++ < 3) diag(QStringLiteral("getStreamStatus reply #%1: %2").arg(m).arg(s.left(60))); applyStreamStatus(s); }, Timeout());
    modules().radio_module.getStreamCardAsync(
        [this](QString s){ applyStreamCard(s); }, Timeout());
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
QString RadioUiBackend::connectKeycard(QString privHex)
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    modules().radio_module.connectKeycardAsync(privHex, [this](QString r) {
        const QJsonObject o = QJsonDocument::fromJson(r.toUtf8()).object();
        if (o.value(QStringLiteral("ok")).toBool()) {
            setKeycardFingerprint(o.value(QStringLiteral("fingerprint")).toString());
            emit activity(QStringLiteral("Keycard linked · ") + keycardFingerprint());
        } else {
            setKeycardFingerprint(QString());
            emit activity(QStringLiteral("Keycard connect failed — unlock the card, then try again"));
        }
    }, Timeout());
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::startStream(QString configJson)
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    diag(QStringLiteral("startStream: fire-and-forget (spawns MediaMTX)"));
    modules().radio_module.startStreamAsync(configJson,
        [this](QString){ diag(QStringLiteral("startStream cb fired"));
                         emit activity(QStringLiteral("Stream started")); }, Timeout());
    emit activity(QStringLiteral("Starting stream…"));
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::stopStream()
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    modules().radio_module.stopStreamAsync([](QString){ }, Timeout());
    setStreamCardJson(QString());
    emit activity(QStringLiteral("Stream stopped"));
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::regenerateKey()
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    modules().radio_module.regenerateKeyAsync(
        [this](QString){ emit activity(QStringLiteral("Stream key rotated — re-enter it in OBS")); }, Timeout());
    return QStringLiteral("{\"ok\":true}");
}

QString RadioUiBackend::regenerateOnion()
{
    if (!isContextReady()) return QStringLiteral("{\"ok\":false,\"error\":\"context_not_ready\"}");
    diag(QStringLiteral("regenerateOnion: fire-and-forget (spawns tor)"));
    modules().radio_module.regenerateOnionAsync(
        [this](QString){ emit activity(QStringLiteral("Rotating Tor address — listeners will rediscover")); }, Timeout());
    setOnionReady(false); setOnionAddr(QString());
    return QStringLiteral("{\"ok\":true}");
}
