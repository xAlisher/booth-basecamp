#ifndef RADIO_CHILD_GUARD_H
#define RADIO_CHILD_GUARD_H

#include <QString>

class QProcess;

/**
 * Keeps radio_module's helper processes (mediamtx, tor, ffmpeg, ffplay) from outliving it (#88).
 *
 * Linux: prepare() sets PR_SET_PDEATHSIG, so the kernel SIGKILLs the child when logos_host dies.
 * macOS has no equivalent, so every platform also keeps a small registry file of
 * "<childPid> <parentPid> <name>" lines. reapStale() (called once at module start) kills a recorded
 * child only when ALL of these hold:
 *   - the recorded parent is gone (so a live Basecamp instance's children are never touched),
 *   - the child pid is still alive,
 *   - its process name still matches the recorded name (so a reused pid is never killed).
 */
namespace ChildGuard {

/** Registry location; defaults to <GenericDataLocation>/radio_module/children.pids (per profile). */
void setRegistryPath(const QString& path);
QString registryPath();

/** Call BEFORE start(): installs the Linux parent-death signal (no-op elsewhere). */
void prepare(QProcess* p);

/** Call AFTER a successful start(): records the pid; removed again when the process finishes. */
void track(QProcess* p, const QString& name);

/** Kill orphans left by a previous, crashed instance of this profile. Returns how many were killed. */
int reapStale();

/** Process name for a pid ("" if gone). Linux: /proc/<pid>/comm; macOS: proc_name(). */
QString processName(qint64 pid);

} // namespace ChildGuard

#endif
