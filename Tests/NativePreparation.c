#include <fcntl.h>
#include "../Sources/Native.h"
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static int checks;
static void check(int ok, const char *label) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label); exit(1); }
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--gate-child")) {
        if (getsid(0) != getpid() || getpgrp() != getpid() || isatty(0) || isatty(1)) return 2;
        char value;
        if (read(0, &value, 1) != 0) return 2;
        for (int i = 0; i < 200; i++) {
            int result = cs_preparation_receive(3);
            if (result == 1) return 0;
            if (result < 0) return 2;
            usleep(25000);
        }
        return 2;
    }
    int pair[2];
    check(cs_preparation_channel(pair) == 0, "owned anonymous channel created");
    check(cs_preparation_receive(pair[1]) == 0, "no parent byte is not confirmation");
    check(cs_preparation_send(pair[0]) == 0, "parent confirmation byte sent");
    check(cs_preparation_receive(pair[1]) == 1, "exact byte received");
    close(pair[0]);
    check(cs_preparation_receive(pair[1]) < 0, "EOF is cancellation"); close(pair[1]);
    int regular = open("/dev/null", O_RDONLY);  /* not fd 0: stdin may itself be a socket */
    check(regular >= 0 && cs_preparation_receive(regular) < 0, "non socket input rejected"); close(regular);
    check(cs_preparation_channel(pair) == 0, "second owned channel created");
    char bad = 'X';
    check(send(pair[0], &bad, 1, 0) == 1 && cs_preparation_receive(pair[1]) < 0, "unknown byte rejected");
    close(pair[1]);
    check(cs_preparation_send(pair[0]) < 0, "closed worker rejects send without SIGPIPE"); close(pair[0]);
    CSObservedProcess own;
    check(cs_observer_process(getpid(), &own) == 0 && cs_preparation_channel(pair) == 0, "exact owned parent captured");
    char *args[] = { own.executable, "--gate-child", NULL };
    char *env[] = { NULL };
    int pid = cs_observer_spawn_gated(own.executable, args, env, "/tmp", pair[1]);
    close(pair[1]);
    check(pid > 0 && cs_preparation_send(pair[0]) == 0, "detached child receives only fd3 gate");
    close(pair[0]);
    int status;
    check(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
          "child retains null stdio and independent session, exits naturally");
    printf("%d native preparation gate checks passed (owned synthetic socket/child only)\n", checks);
    return 0;
}
