/*
 * gitwrap: logs every git the app starts, then becomes that git.
 *
 * Environment:
 *   GITWRAP_REAL  the git to run (required)
 *   GITWRAP_LOG   the file to append one line per spawn to (optional)
 *
 * Each line is: <unix time in ns> <pid> <ppid> <working directory> <arguments...>
 * The wrapper execs git in place, so it costs one extra exec and no extra process.
 */
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *real = getenv("GITWRAP_REAL");
    if (!real) {
        fprintf(stderr, "gitwrap: GITWRAP_REAL is not set\n");
        return 127;
    }
    const char *log = getenv("GITWRAP_LOG");
    if (log) {
        char line[8192], cwd[PATH_MAX];
        if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "?");
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        int n = snprintf(line, sizeof line, "%lld %d %d %s", (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec, getpid(), getppid(), cwd);
        for (int i = 1; i < argc && n < (int)sizeof line - 2; i++) {
            n += snprintf(line + n, sizeof line - n, " %s", argv[i]);
        }
        if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
        line[n++] = '\n';
        int fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            write(fd, line, n);
            close(fd);
        }
    }
    argv[0] = (char *)real;
    execv(real, argv);
    perror("gitwrap: exec");
    return 127;
}
