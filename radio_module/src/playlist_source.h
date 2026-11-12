#ifndef RADIO_PLAYLIST_SOURCE_H
#define RADIO_PLAYLIST_SOURCE_H

#include <QElapsedTimer>
#include <QJsonObject>
#include <QObject>
#include <QProcessEnvironment>
#include <QStringList>
#include <QTimer>
#include <QVector>

class QProcess;

/**
 * Built-in playlist source (#86): streams a list of audio files into the station with no OBS and
 * no Liquidsoap. Modelled on Booth-Android's HlsBroadcaster.
 *
 *   file ─▶ ffmpeg decode (one per track, flow-controlled) ─▶ raw PCM ─▶ [this class: the clock] ─▶ ffmpeg encode
 *                                                                 │ silence when idle     (one per broadcast)
 *                                                                 ▼                     ─▶ output (RTMP into MediaMTX)
 *
 * The encoder runs for the whole broadcast, so track changes never drop the stream. This class is the
 * pacing clock: every tick it writes exactly as much PCM as wall time allows (plus a small lead), taken
 * from the current decoder, or silence when there is none (gaps, pause, end of list). The next track's
 * decoder is spawned as soon as the current one finishes decoding, so the hand-over is near gapless.
 *
 * Pause stops the decoder and remembers the position; resume restarts it with -ss.
 * Pure Qt + ffmpeg/ffprobe: no Logos SDK, so tests/playlist_test.cpp runs it standalone.
 */
class PlaylistSource : public QObject
{
    Q_OBJECT
public:
    static constexpr int kRate = 48000, kChannels = 2, kBytesPerFrame = 4;
    static constexpr int kBytesPerSec = kRate * kBytesPerFrame;   // s16le stereo

    explicit PlaylistSource(QObject* parent = nullptr);
    ~PlaylistSource() override;

    void setBinaries(const QString& ffmpeg, const QString& ffprobe) { m_ffmpeg = ffmpeg; m_ffprobe = ffprobe; }
    void setEnvironment(const QProcessEnvironment& env) { m_env = env; m_hasEnv = true; }
    void setBitrate(int kbps) { if (kbps > 0) m_kbps = kbps; }
    int  bitrate() const { return m_kbps; }

    /** {items:[file|folder,…], shuffle:bool, loop:bool, kbps?:int}. Folders expand recursively (natural sort).
     *  kbps (if given) sets the encoder bitrate used by the NEXT start(); see RadioModulePlugin::setPlaylist.
     *  While running, the new list takes over at its first track. @return number of playable files. */
    int setPlaylist(const QJsonObject& cfg);
    QJsonObject config() const;          // the {items, shuffle, loop} given, for persistence
    int fileCount() const { return m_files.size(); }

    /** Encoder output, e.g. rtmpOutput("rtmp://127.0.0.1:1935/path?user=publisher&pass=…"). */
    static QStringList rtmpOutput(const QString& url, int kbps = 96);
    /** Start (or restart with a new output) the encoder and begin playing. */
    void start(const QStringList& outputArgs);
    void stop();
    bool isRunning() const { return m_running; }

    void next();
    void setPaused(bool paused);
    bool isPaused() const { return m_paused; }

    /** "Artist — Title" (tags) or the file name; "" when nothing is playing. */
    QString nowPlaying() const { return m_curTitle; }
    /** {active, paused, state, index, count, current:{file,title,duration,elapsed}, next:{title}, shuffle, loop, encoderRestarts, error} */
    QJsonObject state() const;

    // test seams
    int encoderStarts() const { return m_encoderStarts; }
    qint64 silenceBytes() const { return m_silenceBytes; }
    qint64 audioBytes() const { return m_audioBytes; }

signals:
    void trackChanged(const QString& title);
    void ended();                          // reached the end of a non-looping list

private:
    struct Probe { QString title; double duration = 0; };
    struct Decoder { QProcess* proc = nullptr; int pos = -1; QString file, title; double duration = 0;
                     double startAt = 0; qint64 bytes = 0; bool finished = false; bool failed = false;
                     bool stopped = false; };   // SIGSTOPped because enough PCM is buffered (flow control)

    void tick();
    void spawnEncoder();
    void killEncoder();
    Decoder spawnDecoder(int orderPos, double startAt);
    void killDecoder(Decoder& d);
    void throttle(Decoder& d);             // SIGSTOP above the high-water mark, SIGCONT below the low one
    void advance();                        // current exhausted → promote/prefetch the next track
    int  nextOrderPos(int pos);            // -1 at the end of a non-looping list
    void buildOrder(bool keepFirst);
    Probe probe(const QString& file) const;
    void writePcm(const QByteArray& pcm, bool silence);
    QStringList expand(const QStringList& entries) const;

    QString m_ffmpeg = QStringLiteral("ffmpeg"), m_ffprobe = QStringLiteral("ffprobe");
    QProcessEnvironment m_env; bool m_hasEnv = false;
    int m_kbps = 96;   // Tor onion circuits measured 0.86x real time at 160k (Sneg plays 1.1x at 128k)

    QJsonObject m_cfg;
    QStringList m_files;
    QVector<int> m_order;                  // play order (indices into m_files)
    bool m_shuffle = false, m_loop = true;

    QStringList m_outputArgs;
    QProcess* m_encoder = nullptr;
    int  m_encoderStarts = 0;
    int  m_encoderBackoffMs = 1000;
    bool m_running = false, m_paused = false, m_ended = false;

    Decoder m_cur, m_next;
    int  m_curPos = -1;                    // position in m_order of m_cur
    int  m_consecutiveFailures = 0;
    qint64 m_retryAfterMs = 0;             // all files failing → back off before trying again
    int    m_pendingPos = -1;              // track to start on the next tick (resume / next / after restart)
    double m_pendingAt = 0;                // …and where in it (seconds)
    QString m_curTitle, m_error;

    QTimer m_tick;
    QElapsedTimer m_clock;
    qint64 m_written = 0;                  // PCM bytes sent to the encoder since it started
    qint64 m_silenceBytes = 0, m_audioBytes = 0;
    qint64 m_lastAudioMs = 0;
};

#endif
