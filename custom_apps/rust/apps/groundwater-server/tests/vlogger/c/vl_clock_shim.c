/* LD_PRELOAD shim for the server and PostgreSQL: CLOCK_REALTIME (and
 * gettimeofday/time) = real time + the world-clock offset in
 * $VL_CLOCK_OFFSET_FILE ("+<seconds>", written by the virtual logger and the
 * runner). Monotonic clocks are untouched, so timers, tokio intervals and
 * PostgreSQL's own timing keep running in real time. Built once per C
 * library (the server may link the system glibc, PostgreSQL the nix one).
 * The same idea as libfaketime's FAKETIME_TIMESTAMP_FILE, kept here because
 * a preload library must match the C library of the process. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

typedef int (*cg_t)(clockid_t, struct timespec *);
static cg_t real_cg;
static long long offset_s;
static long long last_check_ms = -1000000;

static void refresh(void) {
    struct timespec m;
    real_cg(CLOCK_MONOTONIC, &m);
    long long now = (long long)m.tv_sec * 1000 + m.tv_nsec / 1000000;
    if (now - __atomic_load_n(&last_check_ms, __ATOMIC_RELAXED) < 50) return;
    __atomic_store_n(&last_check_ms, now, __ATOMIC_RELAXED);
    const char *path = getenv("VL_CLOCK_OFFSET_FILE");
    if (!path) return;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char buf[32];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';
    __atomic_store_n(&offset_s, strtoll(buf, NULL, 10), __ATOMIC_RELAXED);
}

int clock_gettime(clockid_t id, struct timespec *ts) {
    if (!real_cg) real_cg = (cg_t)dlsym(RTLD_NEXT, "clock_gettime");
    int r = real_cg(id, ts);
    if (r == 0 && (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE)) {
        refresh();
        ts->tv_sec += __atomic_load_n(&offset_s, __ATOMIC_RELAXED);
    }
    return r;
}

int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return -1;
    if (tv) {
        tv->tv_sec = ts.tv_sec;
        tv->tv_usec = ts.tv_nsec / 1000;
    }
    return 0;
}

time_t time(time_t *t) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    if (t) *t = ts.tv_sec;
    return ts.tv_sec;
}
