#include "playlist_source.h"
#include "child_guard.h"

#include <QCollator>
#include <QDebug>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QUrl>

#include <algorithm>

namespace {
// How far ahead of wall time the encoder is fed. Absorbs tick jitter without adding real latency.
constexpr qint64 kLeadBytes = PlaylistSource::kBytesPerSec / 4;          // 250 ms
// No decoder data for this long ⇒ a real gap (track start, slow disk), not pipe chunking ⇒ silence.
constexpr qint64 kStarveMs = 300;
// Encoder stdin backlog that means the output is stuck (e.g. RTMP stalled) ⇒ restart the encoder.
constexpr qint64 kMaxBacklog = 4LL * PlaylistSource::kBytesPerSec;
constexpr int kTickMs = 20;
// Start the next track's decoder this long before the current one ends (its audio waits in the pipe buffer).
constexpr double kPrefetchSec = 3.0;
constexpr int kAllFailedRetryMs = 30000;

const QStringList kAudioPatterns = {
    "*.mp3", "*.flac", "*.m4a", "*.aac", "*.ogg", "*.oga", "*.opus", "*.wav",
    "*.aif", "*.aiff", "*.wma", "*.mka", "*.webm", "*.mp4", "*.alac", "*.ape", "*.wv"
};

bool isAudioFile(const QString& path)
{
    const QString lower = QFileInfo(path).fileName().toLower();
    for (const QString& p : kAudioPatterns)
        if (lower.endsWith(p.mid(1))) return true;
    return false;
}

QString cleanText(QString s)
{
    s.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1F\\x7F]")));
    return s.trimmed().left(120);
}

QString tagValue(const QJsonObject& tags, const QString& key)
{
    for (auto it = tags.begin(); it != tags.end(); ++it)
        if (it.key().compare(key, Qt::CaseInsensitive) == 0) return it.value().toString();
    return QString();
}

QHash<QString, QJsonObject> g_probeCache;   // file → {title, duration}; files don't change mid-broadcast
} // namespace

PlaylistSource::PlaylistSource(QObject* parent) : QObject(parent)
{
    m_tick.setTimerType(Qt::PreciseTimer);
    connect(&m_tick, &QTimer::timeout, this, &PlaylistSource::tick);
}

PlaylistSource::~PlaylistSource() { stop(); }

// ---------------------------------------------------------------- playlist ---

QStringList PlaylistSource::expand(const QStringList& entries) const
{
    QStringList out;
    QCollator coll;
    coll.setNumericMode(true);
    coll.setCaseSensitivity(Qt::CaseInsensitive);
    for (QString e : entries) {
        e = e.trimmed();
        if (e.startsWith(QLatin1String("file://"))) e = QUrl(e).toLocalFile();
        if (e.startsWith(QLatin1String("~/"))) e = QDir::homePath() + e.mid(1);
        const QFileInfo fi(e);
        if (fi.isDir()) {
            QStringList found;
            QDirIterator it(fi.absoluteFilePath(), kAudioPatterns, QDir::Files | QDir::Readable,
                            QDirIterator::Subdirectories | QDirIterator::FollowSymlinks);
            while (it.hasNext()) found << it.next();
            std::sort(found.begin(), found.end(),
                      [&](const QString& a, const QString& b) { return coll.compare(a, b) < 0; });
            out << found;
        } else if (fi.isFile() && fi.isReadable() && isAudioFile(e)) {
            out << fi.absoluteFilePath();
        }
    }
    return out;
}

int PlaylistSource::setPlaylist(const QJsonObject& cfg)
{
    QStringList entries;
    for (const QJsonValue& v : cfg.value("items").toArray()) entries << v.toString();
    m_cfg = QJsonObject{{"items", QJsonArray::fromStringList(entries)},
                        {"shuffle", cfg.value("shuffle").toBool(false)},
                        {"loop", cfg.value("loop").toBool(true)}};
    m_shuffle = m_cfg.value("shuffle").toBool();
    m_loop    = m_cfg.value("loop").toBool();
    m_files   = expand(entries);
    buildOrder(false);

    // The new list takes over at its first track.
    killDecoder(m_cur);
    killDecoder(m_next);
    m_curPos = -1;
    m_pendingPos = -1; m_pendingAt = 0;
    m_ended = false;
    m_consecutiveFailures = 0;
    m_retryAfterMs = 0;
    m_curTitle.clear();
    m_error = m_files.isEmpty() ? QStringLiteral("playlist_empty") : QString();
    return m_files.size();
}

QJsonObject PlaylistSource::config() const { return m_cfg; }

void PlaylistSource::buildOrder(bool avoidRepeat)
{
    const int last = (!m_order.isEmpty() && m_curPos >= 0 && m_curPos < m_order.size()) ? m_order[m_curPos] : -1;
    m_order.resize(m_files.size());
    for (int i = 0; i < m_order.size(); ++i) m_order[i] = i;
    if (m_shuffle && m_order.size() > 1) {
        auto* rng = QRandomGenerator::global();
        for (int i = m_order.size() - 1; i > 0; --i) std::swap(m_order[i], m_order[rng->bounded(i + 1)]);
        if (avoidRepeat && m_order.first() == last)
            std::swap(m_order[0], m_order[1 + rng->bounded(m_order.size() - 1)]);
    }
}

int PlaylistSource::nextOrderPos(int pos)
{
    if (m_order.isEmpty()) return -1;
    const int p = pos + 1;
    if (p < m_order.size()) return p;
    if (!m_loop) return -1;
    buildOrder(true);   // a new pass: reshuffle (when shuffling), never the same track twice in a row
    return 0;
}

PlaylistSource::Probe PlaylistSource::probe(const QString& file) const
{
    auto cached = g_probeCache.constFind(file);
    if (cached != g_probeCache.constEnd())
        return Probe{cached->value("title").toString(), cached->value("duration").toDouble()};

    Probe r;
    QProcess p;
    if (m_hasEnv) p.setProcessEnvironment(m_env);
    p.start(m_ffprobe, {"-v", "quiet", "-print_format", "json", "-show_entries",
                        "format=duration:format_tags=title,artist:stream_tags=title,artist", file});
    if (p.waitForFinished(4000)) {
        const QJsonObject j = QJsonDocument::fromJson(p.readAllStandardOutput()).object();
        const QJsonObject fmt = j.value("format").toObject();
        r.duration = fmt.value("duration").toString().toDouble();
        QJsonObject tags = fmt.value("tags").toObject();
        if (tagValue(tags, "title").isEmpty())   // Ogg/Opus keep tags on the stream
            for (const QJsonValue& s : j.value("streams").toArray())
                if (!tagValue(s.toObject().value("tags").toObject(), "title").isEmpty()) {
                    tags = s.toObject().value("tags").toObject();
                    break;
                }
        const QString title = cleanText(tagValue(tags, "title"));
        const QString artist = cleanText(tagValue(tags, "artist"));
        if (!title.isEmpty()) r.title = artist.isEmpty() ? title : artist + QStringLiteral(" — ") + title;
    } else {
        p.kill();
        p.waitForFinished(500);
    }
    if (r.title.isEmpty()) r.title = cleanText(QFileInfo(file).completeBaseName());
    r.title = r.title.left(120);
    g_probeCache.insert(file, QJsonObject{{"title", r.title}, {"duration", r.duration}});
    return r;
}

// --------------------------------------------------------------- lifecycle ---

QStringList PlaylistSource::rtmpOutput(const QString& url, int kbps)
{
    return {"-c:a", "aac", "-b:a", QStringLiteral("%1k").arg(kbps), "-ar", QString::number(kRate),
            "-flvflags", "no_duration_filesize", "-f", "flv", url};
}

void PlaylistSource::start(const QStringList& outputArgs)
{
    m_outputArgs = outputArgs;
    if (m_running) {          // new output (e.g. rotated stream key): restart only the encoder
        killEncoder();
        spawnEncoder();
        return;
    }
    m_running = true;
    m_paused = false;
    m_ended = false;
    m_encoderBackoffMs = 1000;
    spawnEncoder();
    m_tick.start(kTickMs);
}

void PlaylistSource::stop()
{
    const bool was = m_running;
    m_running = false;
    m_tick.stop();
    killDecoder(m_cur);
    killDecoder(m_next);
    killEncoder();
    m_curPos = -1;
    m_pendingPos = -1; m_pendingAt = 0;
    m_paused = false;
    if (was && !m_curTitle.isEmpty()) { m_curTitle.clear(); emit trackChanged(QString()); }
    m_curTitle.clear();
}

void PlaylistSource::spawnEncoder()
{
    if (!m_running || m_encoder) return;
    auto* enc = new QProcess(this);
    if (m_hasEnv) enc->setProcessEnvironment(m_env);
    ChildGuard::prepare(enc);
    QStringList args{"-hide_banner", "-loglevel", "error",   // warnings (e.g. "Guessed Channel Layout") are noise
                     "-f", "s16le", "-ar", QString::number(kRate), "-ac", QString::number(kChannels),
                     "-i", "pipe:0"};
    args << m_outputArgs;
    connect(enc, &QProcess::readyReadStandardError, enc, [this, enc] {
        const QByteArray e = enc->readAllStandardError().trimmed();
        if (!e.isEmpty()) {
            const QString last = QString::fromUtf8(e.split('\n').last());
            qWarning() << "PlaylistSource: encoder:" << last;
            m_error = QStringLiteral("encoder: ") + last.left(200);
        }
    });
    connect(enc, &QProcess::readyReadStandardOutput, enc, [enc] { enc->readAllStandardOutput(); });
    enc->start(m_ffmpeg, args);
    if (!enc->waitForStarted(5000)) {
        m_error = enc->error() == QProcess::FailedToStart ? QStringLiteral("ffmpeg_not_found")
                                                          : QStringLiteral("encoder_spawn_failed");
        qWarning() << "PlaylistSource: encoder failed to start:" << enc->errorString();
        enc->deleteLater();
        QTimer::singleShot(m_encoderBackoffMs, this, [this] { spawnEncoder(); });
        m_encoderBackoffMs = std::min(m_encoderBackoffMs * 2, 10000);
        return;
    }
    ChildGuard::track(enc, QFileInfo(m_ffmpeg).fileName());
    m_encoder = enc;
    ++m_encoderStarts;
    m_clock.restart();
    m_written = 0;
    m_lastAudioMs = 0;

    connect(enc, &QProcess::finished, this, [this, enc](int code) {
        if (enc != m_encoder) return;
        const bool ranLong = m_clock.elapsed() > 30000;
        qWarning() << "PlaylistSource: encoder exited" << code << "after" << m_clock.elapsed() << "ms";
        m_encoder = nullptr;
        enc->deleteLater();
        if (!m_running) return;
        if (ranLong) m_encoderBackoffMs = 1000;
        // Resume the current track where the listener left it, not where the decoder had raced to.
        if (m_cur.proc && !m_paused) {
            m_pendingPos = m_cur.pos;
            m_pendingAt = m_cur.startAt + double(m_cur.bytes) / kBytesPerSec;
            killDecoder(m_cur);
            killDecoder(m_next);
        }
        QTimer::singleShot(m_encoderBackoffMs, this, [this] { spawnEncoder(); });
        m_encoderBackoffMs = std::min(m_encoderBackoffMs * 2, 10000);
    });
}

void PlaylistSource::killEncoder()
{
    if (!m_encoder) return;
    QProcess* enc = m_encoder;
    m_encoder = nullptr;               // the finished handler ignores a process that is no longer current
    enc->closeWriteChannel();          // EOF lets ffmpeg flush the last packets cleanly
    if (!enc->waitForFinished(1500)) {
        enc->kill();
        enc->waitForFinished(1000);
    }
    enc->deleteLater();
}

PlaylistSource::Decoder PlaylistSource::spawnDecoder(int orderPos, double startAt)
{
    Decoder d;
    d.pos = orderPos;
    d.startAt = startAt;
    const QString file = m_files.value(m_order.value(orderPos, -1));
    if (file.isEmpty()) return d;
    const Probe pr = probe(file);
    d.file = file;
    d.title = pr.title;
    d.duration = pr.duration;

    auto* proc = new QProcess(this);
    if (m_hasEnv) proc->setProcessEnvironment(m_env);
    ChildGuard::prepare(proc);
    proc->setReadChannel(QProcess::StandardOutput);
    QStringList args{"-hide_banner", "-loglevel", "error", "-nostdin", "-re"};
    if (startAt > 0.5) args << "-ss" << QString::number(startAt, 'f', 2);
    args << "-i" << file << "-vn" << "-sn" << "-dn" << "-map" << "0:a:0"
         << "-f" << "s16le" << "-ar" << QString::number(kRate) << "-ac" << QString::number(kChannels) << "pipe:1";
    connect(proc, &QProcess::readyReadStandardError, proc, [proc, file] {
        const QByteArray e = proc->readAllStandardError().trimmed();
        if (!e.isEmpty()) qWarning() << "PlaylistSource: decode" << QFileInfo(file).fileName() << ":" << e.left(300);
    });
    connect(proc, &QProcess::finished, this, [this, proc](int code, QProcess::ExitStatus st) {
        Decoder* d = (proc == m_cur.proc) ? &m_cur : (proc == m_next.proc) ? &m_next : nullptr;
        if (!d) return;
        d->finished = true;
        d->failed = (st != QProcess::NormalExit || code != 0);
        // The current track is fully decoded (its tail may still be buffered): prefetch the next one now
        // so it is already producing audio when the tail runs out.
        if (d == &m_cur && !m_next.proc && !m_paused) {
            const int np = nextOrderPos(m_cur.pos);
            if (np >= 0) m_next = spawnDecoder(np, 0);
        }
    });
    proc->start(m_ffmpeg, args);
    if (!proc->waitForStarted(5000)) {
        qWarning() << "PlaylistSource: decoder failed to start:" << proc->errorString();
        m_error = QStringLiteral("ffmpeg_not_found");
        proc->deleteLater();
        d.finished = d.failed = true;
        return d;
    }
    ChildGuard::track(proc, QFileInfo(m_ffmpeg).fileName());
    d.proc = proc;
    return d;
}

void PlaylistSource::killDecoder(Decoder& d)
{
    if (d.proc) {
        QProcess* p = d.proc;
        disconnect(p, nullptr, this, nullptr);
        p->kill();
        p->waitForFinished(500);
        p->deleteLater();
    }
    d = Decoder{};
}

// ------------------------------------------------------------------ controls ---

void PlaylistSource::next()
{
    if (m_files.isEmpty()) return;
    const int from = m_pendingPos >= 0 ? m_pendingPos : m_cur.proc ? m_cur.pos : m_curPos;
    killDecoder(m_cur);
    killDecoder(m_next);
    const int np = nextOrderPos(from);
    m_curPos = from;
    m_ended = false;
    m_consecutiveFailures = 0;
    m_retryAfterMs = 0;
    if (np < 0) {
        m_ended = true;
        m_pendingPos = -1;
        if (!m_curTitle.isEmpty()) { m_curTitle.clear(); emit trackChanged(QString()); }
        emit ended();
        return;
    }
    m_pendingPos = np;
    m_pendingAt = 0;
    if (m_paused) {           // stay paused, but show what will play on resume
        m_curPos = np;
        m_curTitle = probe(m_files.value(m_order.value(np))).title;
        emit trackChanged(m_curTitle);
    }
}

void PlaylistSource::setPaused(bool paused)
{
    if (paused == m_paused) return;
    m_paused = paused;
    if (paused && m_cur.proc) {
        m_pendingPos = m_cur.pos;
        m_pendingAt = m_cur.startAt + double(m_cur.bytes) / kBytesPerSec;
        m_curPos = m_cur.pos;
        const QString keep = m_curTitle;
        killDecoder(m_cur);
        killDecoder(m_next);
        m_curTitle = keep;     // still "on" this track, just paused
    }
}

// ---------------------------------------------------------------- the clock ---

void PlaylistSource::writePcm(const QByteArray& pcm, bool silence)
{
    if (!m_encoder || pcm.isEmpty()) return;
    m_encoder->write(pcm);
    m_written += pcm.size();
    (silence ? m_silenceBytes : m_audioBytes) += pcm.size();
}

void PlaylistSource::advance()
{
    const bool wasGood = m_cur.bytes > 0 && !m_cur.failed;
    if (m_cur.bytes == 0) qWarning() << "PlaylistSource: skipped unplayable track" << m_cur.title;
    const int finishedPos = m_cur.pos;
    killDecoder(m_cur);
    m_consecutiveFailures = wasGood ? 0 : m_consecutiveFailures + 1;
    m_curPos = finishedPos;

    if (m_consecutiveFailures >= std::max<int>(1, m_files.size())) {
        m_error = QStringLiteral("all_tracks_failed");
        killDecoder(m_next);
        m_retryAfterMs = m_clock.elapsed() + kAllFailedRetryMs;
        m_consecutiveFailures = 0;
        if (!m_curTitle.isEmpty()) { m_curTitle.clear(); emit trackChanged(QString()); }
        return;
    }
    if (m_next.proc || m_next.finished) {     // prefetched (possibly already done, e.g. a failed file)
        m_cur = m_next;
        m_next = Decoder{};
        m_curPos = m_cur.pos;
        if (m_cur.finished && !m_next.proc) {   // it finished before it was promoted: prefetch now
            const int np = nextOrderPos(m_cur.pos);
            if (np >= 0) m_next = spawnDecoder(np, 0);
        }
        return;
    }
    const int np = nextOrderPos(finishedPos);
    if (np < 0) {
        m_ended = true;
        if (!m_curTitle.isEmpty()) { m_curTitle.clear(); emit trackChanged(QString()); }
        emit ended();
        return;
    }
    m_pendingPos = np;
    m_pendingAt = 0;
}

void PlaylistSource::tick()
{
    if (!m_running || !m_encoder) return;
    if (m_encoder->bytesToWrite() > kMaxBacklog) {
        qWarning() << "PlaylistSource: encoder not draining (output stalled?) — restarting it";
        m_encoder->kill();     // its finished handler restarts it and resumes the current track
        return;
    }
    const qint64 now = m_clock.elapsed();

    // Start (or resume) a track when nothing is decoding.
    if (!m_cur.proc && !m_cur.finished && !m_paused && !m_ended && !m_files.isEmpty() && now >= m_retryAfterMs) {
        const int pos = m_pendingPos >= 0 ? m_pendingPos : nextOrderPos(m_curPos);
        const double at = m_pendingPos >= 0 ? m_pendingAt : 0;
        m_pendingPos = -1; m_pendingAt = 0;
        if (pos < 0) {
            m_ended = true;
            emit ended();
        } else {
            m_cur = spawnDecoder(pos, at);
            m_curPos = pos;
            m_lastAudioMs = now;          // give the new decoder kStarveMs before filling silence
        }
    }

    const qint64 target = now * kBytesPerSec / 1000 + kLeadBytes;
    qint64 need = (target - m_written) & ~qint64(kBytesPerFrame - 1);
    if (need <= 0) return;

    for (int guard = 0; need > 0 && !m_paused && (m_cur.proc || m_cur.finished) && guard < 8; ++guard) {
        const qint64 avail = m_cur.proc ? (m_cur.proc->bytesAvailable() & ~qint64(kBytesPerFrame - 1)) : 0;
        if (avail > 0) {
            const QByteArray d = m_cur.proc->read(std::min(need, avail));
            // Now playing changes when the track is actually heard, so an unplayable file never shows up.
            if (m_cur.bytes == 0 && m_cur.title != m_curTitle) { m_curTitle = m_cur.title; emit trackChanged(m_curTitle); }
            writePcm(d, false);
            m_cur.bytes += d.size();
            need -= d.size();
            m_lastAudioMs = now;
            continue;
        }
        if (m_cur.finished) { advance(); continue; }   // tail drained → hand over to the next track
        break;                                          // decoder running, just no data yet
    }

    // Prefetch: start the next decoder a few seconds before this track ends, so its first audio is
    // already buffered at the hand-over (-re decoders only finish about when their audio is consumed).
    if (m_cur.proc && !m_cur.finished && !m_next.proc && !m_next.finished && !m_paused && m_cur.duration > 0) {
        const double remaining = m_cur.duration - (m_cur.startAt + double(m_cur.bytes) / kBytesPerSec);
        if (remaining < kPrefetchSec) {
            const int np = nextOrderPos(m_cur.pos);
            if (np >= 0) m_next = spawnDecoder(np, 0);
        }
    }

    // Silence keeps the encoder (and so the stream) running through gaps, pauses and the end of the list.
    const bool starving = m_paused || (!m_cur.proc && !m_cur.finished) || now - m_lastAudioMs > kStarveMs;
    if (need > 0 && starving) writePcm(QByteArray(int(need), '\0'), true);
}

// -------------------------------------------------------------------- state ---

QJsonObject PlaylistSource::state() const
{
    QString st;
    if (!m_running)            st = QStringLiteral("idle");
    else if (m_files.isEmpty()) st = QStringLiteral("empty");
    else if (m_ended)          st = QStringLiteral("ended");
    else if (m_paused)         st = QStringLiteral("paused");
    else if (m_cur.proc)       st = QStringLiteral("playing");
    else                       st = QStringLiteral("loading");

    QJsonObject r{{"ok", true}, {"active", m_running}, {"paused", m_paused}, {"state", st},
                  {"count", int(m_files.size())}, {"shuffle", m_shuffle}, {"loop", m_loop},
                  {"encoderRestarts", std::max(0, m_encoderStarts - 1)}};
    const int pos = m_cur.proc ? m_cur.pos : (m_pendingPos >= 0 ? m_pendingPos : m_curPos);
    r["index"] = pos;
    if (pos >= 0 && pos < m_order.size() && !m_ended) {  // NB: a loop reshuffle may already have re-ordered m_order
        const QString file = m_cur.proc ? m_cur.file : m_files.value(m_order[pos]);
        const auto c = g_probeCache.value(file);
        const double elapsed = m_cur.proc ? m_cur.startAt + double(m_cur.bytes) / kBytesPerSec : m_pendingAt;
        r["current"] = QJsonObject{{"file", QFileInfo(file).fileName()}, {"title", c.value("title").toString(m_curTitle)},
                                   {"duration", c.value("duration").toDouble()}, {"elapsed", elapsed}};
        const int np = pos + 1 < m_order.size() ? pos + 1 : (m_loop && !m_shuffle ? 0 : -1);
        if (np >= 0) {
            const QString nf = m_files.value(m_order[np]);
            const auto nc = g_probeCache.value(nf);
            r["next"] = QJsonObject{{"file", QFileInfo(nf).fileName()},
                                    {"title", nc.value("title").toString(QFileInfo(nf).completeBaseName())}};
        }
    }
    if (!m_error.isEmpty()) r["error"] = m_error;
    return r;
}
