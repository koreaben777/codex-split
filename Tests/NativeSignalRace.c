/* Deterministically deliver SIGINT immediately before the native blocking wait. */
#include <unistd.h>
#include <sys/select.h>
#include <signal.h>
#include <stdio.h>
static ssize_t test_read(int fd, void *buffer, size_t size);
static int test_pselect(int n, fd_set *r, fd_set *w, fd_set *e, const struct timespec *t, const sigset_t *mask);
#define read test_read
#define pselect test_pselect
#include "../Sources/Native.c"
#undef read
#undef pselect
static int injected = 0;
static void inject(void) { if (!injected) { injected = 1; raise(SIGINT); } }
static ssize_t test_read(int fd, void *buffer, size_t size) {
    inject(); return read(fd, buffer, size);
}
static int test_pselect(int n, fd_set *r, fd_set *w, fd_set *e, const struct timespec *t, const sigset_t *mask) {
    inject(); return pselect(n, r, w, e, t, mask);
}
int main(void) {
    char buffer[80];
    int result = cs_answer(buffer, sizeof(buffer));
    printf("BOUNDARY:%d\n", result);
    return result == -SIGINT ? 0 : 1;
}
