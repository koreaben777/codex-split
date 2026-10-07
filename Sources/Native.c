#include "Native.h"
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <termios.h>
#include <sys/select.h>
#include <libproc.h>
#include <sys/event.h>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>

static int preparation_socket(int fd) {
    int type; socklen_t length = sizeof(type);
    struct sockaddr_un address; socklen_t address_length = sizeof(address);
    uid_t uid; gid_t gid;
    if (fd < 0 || getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) || type != SOCK_STREAM
        || getsockname(fd, (struct sockaddr *)&address, &address_length) || address.sun_family != AF_UNIX
        || getpeereid(fd, &uid, &gid) || uid != getuid()) { errno = EINVAL; return -1; }
    return 0;
}
int cs_preparation_channel(int descriptors[2]) {
    if (!descriptors) { errno = EINVAL; return -1; }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors)) return -1;
    int enabled = 1;
    for (int i = 0; i < 2; i++) {
        if (fcntl(descriptors[i], F_SETFD, FD_CLOEXEC)
            || setsockopt(descriptors[i], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled))) {
            int saved = errno; close(descriptors[0]); close(descriptors[1]); errno = saved; return -1;
        }
    }
    return 0;
}
int cs_preparation_send(int descriptor) {
    if (preparation_socket(descriptor)) return -1;
    const char byte = 'R'; ssize_t sent;
    do { sent = send(descriptor, &byte, 1, MSG_DONTWAIT); } while (sent < 0 && errno == EINTR);
    return sent == 1 ? 0 : -1;
}
int cs_preparation_receive(int descriptor) {
    if (preparation_socket(descriptor)) return -1;
    char byte; ssize_t count = recv(descriptor, &byte, 1, MSG_DONTWAIT);
    if (count == 1) return byte == 'R' ? 1 : -1;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    return -1; // EOF or any other error never confirms readiness.
}

int cs_rename_exclusive(int directory, const char *source, const char *destination) {
    return renameatx_np(directory, source, directory, destination, RENAME_EXCL);
}

int cs_boot_session(char *buffer, int capacity) {
    if (!buffer || capacity < 64 || capacity > 4096) { errno = EINVAL; return -1; }
    size_t length = (size_t)capacity;
    memset(buffer, 0, length);
    if (sysctlbyname("kern.bootsessionuuid", buffer, &length, NULL, 0) || length >= (size_t)capacity) return -1;
    buffer[capacity - 1] = '\0';
    return 0;
}

int cs_observer_process(int pid, CSObservedProcess *report) {
    if (!report || pid <= 0) { errno = EINVAL; return -1; }
    memset(report, 0, sizeof(*report));
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_pid != (unsigned)pid) return -1;
    if (proc_pidpath(pid, report->executable, sizeof(report->executable)) <= 0) return -1;
    report->pid = pid; report->uid = (int)info.pbi_uid;
    report->start_seconds = info.pbi_start_tvsec;
    report->start_microseconds = info.pbi_start_tvusec;
    return 0;
}
int cs_observer_bind(int pid, unsigned long long seconds, unsigned long long microseconds) {
    CSObservedProcess before, after;
    if (cs_observer_process(pid, &before) || before.start_seconds != seconds || before.start_microseconds != microseconds) return -1;
    int descriptor = kqueue();
    if (descriptor < 0) return -1;
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0) { close(descriptor); return -1; }
    struct kevent change;
    EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(descriptor, &change, 1, NULL, 0, NULL) < 0 || cs_observer_process(pid, &after)
        || after.start_seconds != seconds || after.start_microseconds != microseconds
        || after.uid != before.uid || strcmp(after.executable, before.executable)) { close(descriptor); return -1; }
    return descriptor;
}
int cs_observer_poll(int descriptor, int pid) {
    if (descriptor < 0 || pid <= 0) { errno = EINVAL; return -1; }
    struct kevent event;
    const struct timespec timeout = {0, 0};
    int count = kevent(descriptor, NULL, 0, &event, 1, &timeout);
    if (count <= 0) return count;
    if (event.ident != (uintptr_t)pid || event.filter != EVFILT_PROC || (event.flags & EV_ERROR) || !(event.fflags & NOTE_EXIT)) return -1;
    return 1;
}
static int observer_spawn(const char *executable, char *const argv[], char *const envp[], const char *cwd, int gate) {
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int result = posix_spawnattr_init(&attr);
    if (result) { errno = result; return -1; }
    result = posix_spawn_file_actions_init(&actions);
    if (result) { posix_spawnattr_destroy(&attr); errno = result; return -1; }
    sigset_t mask, defaults;
    sigemptyset(&mask); sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGHUP);
    result = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    if (!result) result = posix_spawnattr_setsigmask(&attr, &mask);
    if (!result) result = posix_spawnattr_setsigdefault(&attr, &defaults);
    for (int descriptor = 0; descriptor < 3 && !result; descriptor++) result = posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0);
    if (!result && gate >= 0) result = posix_spawn_file_actions_adddup2(&actions, gate, 3);
    if (!result) result = posix_spawn_file_actions_addchdir(&actions, cwd);
    pid_t pid = -1;
    if (!result) result = posix_spawn(&pid, executable, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
    if (result) { errno = result; return -1; }
    return (int)pid;
}
int cs_observer_spawn(const char *executable, char *const argv[], char *const envp[], const char *cwd) {
    return observer_spawn(executable, argv, envp, cwd, -1);
}
int cs_observer_spawn_gated(const char *executable, char *const argv[], char *const envp[], const char *cwd, int gate) {
    if (preparation_socket(gate)) return -1;
    return observer_spawn(executable, argv, envp, cwd, gate);
}

/* Single foreground runner per process; never signal an existing application. */
static volatile sig_atomic_t child_group = 0;
static volatile sig_atomic_t interrupted = 0;
static const int signals[] = { SIGINT, SIGTERM, SIGHUP };
static void forward(int sig) {
    int saved = errno;
    interrupted = sig;
    if (child_group > 0) kill(-(pid_t)child_group, sig);
    errno = saved;
}
static void setup(struct sigaction old[3], sigset_t *mask) {
    sigset_t set;
    sigemptyset(&set);
    for (int i = 0; i < 3; i++) sigaddset(&set, signals[i]);
    sigprocmask(SIG_BLOCK, &set, mask);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = forward;
    sigemptyset(&action.sa_mask);
    for (int i = 0; i < 3; i++) sigaction(signals[i], &action, &old[i]);
    interrupted = 0;
}
static void restore(struct sigaction old[3], const sigset_t *mask) {
    for (int i = 0; i < 3; i++) sigaction(signals[i], &old[i], NULL);
    sigprocmask(SIG_SETMASK, mask, NULL);
}
static int foreground(pid_t group) {
    struct sigaction ignore, old;
    memset(&ignore, 0, sizeof(ignore)); ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    sigaction(SIGTTOU, &ignore, &old);
    int result = tcsetpgrp(STDIN_FILENO, group);
    sigaction(SIGTTOU, &old, NULL);
    return result;
}
int cs_run(const char *executable, char *const argv[], char *const envp[], const char *cwd) {
    struct sigaction old[3]; sigset_t mask, defaults, empty;
    setup(old, &mask);
    struct termios terminal;
    int have_terminal = tcgetattr(STDIN_FILENO, &terminal) == 0;
    posix_spawnattr_t attr; posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attr); posix_spawn_file_actions_init(&actions);
    sigemptyset(&empty); sigemptyset(&defaults);
    for (int i = 0; i < 3; i++) sigaddset(&defaults, signals[i]);
    sigaddset(&defaults, SIGTSTP); sigaddset(&defaults, SIGTTIN); sigaddset(&defaults, SIGTTOU);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &empty);
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    int error = posix_spawn_file_actions_addchdir(&actions, cwd);
    pid_t pid = 0, previous = isatty(STDIN_FILENO) ? tcgetpgrp(STDIN_FILENO) : -1;
    if (!error) error = posix_spawn(&pid, executable, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
    if (error) { restore(old, &mask); return -1; }
    child_group = pid;
    // The child may briefly stop on SIGTTIN before this handoff; resume only our group.
    if (previous == getpgrp() && foreground(pid) == 0) kill(-pid, SIGCONT);
    sigprocmask(SIG_SETMASK, &mask, NULL);
    // Keep the leader unreaped until forwarding is disabled: its PID cannot be reused.
    siginfo_t info; int observed;
    do { observed = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT); } while (observed < 0 && errno == EINTR);
    sigset_t block; sigemptyset(&block);
    for (int i = 0; i < 3; i++) sigaddset(&block, signals[i]);
    sigprocmask(SIG_BLOCK, &block, NULL);
    child_group = 0;
    int status = 0; pid_t waited;
    do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
    if (previous == getpgrp()) {
        foreground(previous);
        if (have_terminal) tcsetattr(STDIN_FILENO, TCSANOW, &terminal);
    }
    restore(old, &mask);
    if (observed < 0 || waited < 0) return -1;
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}
int cs_answer(char *buffer, int capacity) {
    if (!isatty(STDIN_FILENO) || tcgetpgrp(STDIN_FILENO) != getpgrp()) return 0;
    struct sigaction old[3]; sigset_t mask;
    setup(old, &mask);
    // Keep managed signals blocked except during pselect's atomic wait.
    sigset_t waiting = mask;
    for (int i = 0; i < 3; i++) sigdelset(&waiting, signals[i]);
    int length = 0, result = 0;
    while (length < capacity - 1 && !interrupted) {
        fd_set input; FD_ZERO(&input); FD_SET(STDIN_FILENO, &input);
        int ready = pselect(STDIN_FILENO + 1, &input, NULL, NULL, NULL, &waiting);
        if (interrupted || ready <= 0) break;
        char c; ssize_t n = read(STDIN_FILENO, &c, 1);
        if (n <= 0 || c == '\0') break;
        if (c == '\n') { result = 1; break; }
        buffer[length++] = c;
    }
    buffer[length] = 0;
    // Handle any managed signal that arrived after readiness while still blocked.
    sigset_t pending;
    if (sigpending(&pending) == 0) {
        for (int i = 0; i < 3; i++) {
            if (sigismember(&pending, signals[i])) {
                sigset_t one; sigemptyset(&one); sigaddset(&one, signals[i]);
                int caught;
                if (sigwait(&one, &caught) == 0) interrupted = caught;
            }
        }
    }
    if (interrupted) result = -interrupted;
    restore(old, &mask);
    return result;
}
