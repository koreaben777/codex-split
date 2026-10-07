#include "../Sources/Native.h"
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

static int checks;
static void check(int value, const char *label) {
    checks++;
    if (!value) { fprintf(stderr, "FAIL: %s\n", label); exit(1); }
}
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--lifetime-parent")) {
        CSObservedProcess own;
        if (cs_observer_process(getpid(), &own)) return 2;
        char *child_args[] = {own.executable, "--detached", argv[2], NULL};
        char *child_env[] = {NULL};
        int pid = cs_observer_spawn(own.executable, child_args, child_env, "/tmp");
        if (pid <= 0) return 2;
        printf("owned synthetic lifetime worker PID %d; parent exits now\n", pid);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--detached")) {
        char byte;
        int eof = read(STDIN_FILENO, &byte, 1) == 0;
        sleep(2); /* The intermediate parent has exited before this durable marker. */
        int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) return 2;
        int valid = getsid(0) == getpid() && getpgrp() == getpid() && !isatty(0) && !isatty(1) && eof;
        dprintf(fd, "%d\n", valid); fsync(fd); close(fd);
        return valid ? 0 : 2;
    }
    CSObservedProcess self;
    check(cs_observer_process(getpid(), &self) == 0 && self.pid == getpid() && self.uid == (int)getuid(), "exact owned process metadata");
    check(cs_observer_bind(getpid(), self.start_seconds, self.start_microseconds + 1) < 0, "birth mismatch refuses watcher");
    check(cs_observer_process(-1, &self) < 0, "invalid PID is not absence proof");
    check(cs_observer_poll(-1, getpid()) < 0, "invalid watch descriptor fails closed");
    pid_t target = fork();
    if (!target) { sleep(2); _exit(0); }
    check(target > 0, "owned synthetic target created");
    CSObservedProcess observed;
    check(cs_observer_process(target, &observed) == 0, "synthetic target generation captured");
    int watcher = cs_observer_bind(target, observed.start_seconds, observed.start_microseconds);
    check(watcher >= 0 && cs_observer_poll(watcher, target) == 0, "passive watcher is armed before exit");
    int status = 0;
    check(waitpid(target, &status, 0) == target && WIFEXITED(status) && WEXITSTATUS(status) == 0, "owned target exits naturally, no signals");
    check(cs_observer_poll(watcher, target) == 1, "kernel exit survives target reaping");
    close(watcher);
    check(cs_observer_process(target, &observed) < 0, "already exited target cannot be rebound");
    if (argc != 2) return 64;
    const char *marker = argv[1];
    pid_t parent = fork();
    if (!parent) {
        CSObservedProcess own;
        if (cs_observer_process(getpid(), &own)) _exit(2);
        char *child_args[] = {own.executable, "--detached", (char *)marker, NULL};
        char *child_env[] = {NULL};
        int pid = cs_observer_spawn(own.executable, child_args, child_env, "/tmp");
        _exit(pid > 0 ? 0 : 2);
    }
    check(parent > 0 && waitpid(parent, &status, 0) == parent && WIFEXITED(status) && WEXITSTATUS(status) == 0,
          "detached observer parent exits normally");
    int fd = -1;
    for (int i = 0; i < 100 && fd < 0; i++) { usleep(100000); fd = open(marker, O_RDONLY | O_NOFOLLOW); }
    char value[8] = {0};
    check(fd >= 0 && read(fd, value, sizeof(value)-1) > 0 && value[0] == '1', "detached observer survives parent exit with null stdin EOF and independent session");
    close(fd);
    unlink(marker); /* Only the exclusively-created synthetic marker from this run. */
    printf("%d native observer checks passed (owned synthetic processes, no app control or signals)\n", checks);
    return 0;
}
