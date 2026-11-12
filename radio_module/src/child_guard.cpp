#include "child_guard.h"

#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QProcess>
#include <QStandardPaths>
#include <QStringList>

#include <csignal>
#include <cerrno>
#include <unistd.h>
#ifdef Q_OS_LINUX
#include <sys/prctl.h>
#endif
#ifdef Q_OS_MACOS
#include <libproc.h>
#endif

namespace {
QMutex  g_lock;
QString g_registry;

bool pidAlive(qint64 pid)
{
    if (pid <= 1) return false;
    return ::kill(static_cast<pid_t>(pid), 0) == 0 || errno == EPERM;
}

QStringList readLines(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};
    QStringList out;
    for (const QByteArray& l : f.readAll().split('\n'))
        if (!l.trimmed().isEmpty()) out << QString::fromUtf8(l.trimmed());
    return out;
}

void writeLines(const QString& path, const QStringList& lines)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return;
    for (const QString& l : lines) f.write(l.toUtf8() + '\n');
}

// Linux truncates comm to 15 chars; compare on that.
bool sameName(const QString& a, const QString& b) { return !a.isEmpty() && a.left(15) == b.left(15); }
} // namespace

namespace ChildGuard {

void setRegistryPath(const QString& path) { QMutexLocker l(&g_lock); g_registry = path; }

QString registryPath()
{
    QMutexLocker l(&g_lock);
    if (g_registry.isEmpty())
        g_registry = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
                     + "/radio_module/children.pids";
    return g_registry;
}

void prepare(QProcess* p)
{
#ifdef Q_OS_LINUX
    p->setChildProcessModifier([] { ::prctl(PR_SET_PDEATHSIG, SIGKILL); });
#else
    Q_UNUSED(p);
#endif
}

void track(QProcess* p, const QString& name)
{
    const qint64 pid = p->processId();
    if (pid <= 0) return;
    const QString path = registryPath();
    const QString line = QStringLiteral("%1 %2 %3").arg(pid).arg(QCoreApplication::applicationPid()).arg(name);
    {
        QMutexLocker l(&g_lock);
        QStringList lines = readLines(path);
        lines << line;
        writeLines(path, lines);
    }
    QObject::connect(p, &QProcess::finished, p, [path, line] {
        QMutexLocker l(&g_lock);
        QStringList lines = readLines(path);
        lines.removeAll(line);
        writeLines(path, lines);
    });
}

int reapStale()
{
    const QString path = registryPath();
    QMutexLocker l(&g_lock);
    const QStringList lines = readLines(path);
    QStringList keep;
    int killed = 0;
    for (const QString& line : lines) {
        const QStringList f = line.split(QLatin1Char(' '));
        if (f.size() < 3) continue;
        const qint64 child = f[0].toLongLong(), parent = f[1].toLongLong();
        const QString name = f.mid(2).join(QLatin1Char(' '));
        if (pidAlive(parent)) { keep << line; continue; }   // owner still running: not ours to touch
        if (!pidAlive(child)) continue;                       // already gone: drop the line
        if (!sameName(processName(child), name)) continue;    // pid reused by something else: leave it
        qWarning() << "radio_module: reaping orphaned" << name << "pid" << child << "(parent" << parent << "gone)";
        ::kill(static_cast<pid_t>(child), SIGTERM);
        ++killed;
    }
    writeLines(path, keep);
    return killed;
}

QString processName(qint64 pid)
{
#if defined(Q_OS_LINUX)
    QFile f(QStringLiteral("/proc/%1/comm").arg(pid));
    if (!f.open(QIODevice::ReadOnly)) return QString();
    return QString::fromUtf8(f.readAll()).trimmed();
#elif defined(Q_OS_MACOS)
    char buf[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_name(static_cast<int>(pid), buf, sizeof(buf)) <= 0) return QString();
    return QString::fromUtf8(buf);
#else
    Q_UNUSED(pid);
    return QString();
#endif
}

} // namespace ChildGuard
