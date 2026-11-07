/* host shim: build convspec / widl natively on Linux */
#ifndef WINEVDM_HOST_IO_H
#define WINEVDM_HOST_IO_H
#include <unistd.h>
#include <strings.h>
#include <spawn.h>
#include <sys/wait.h>
#define _strnicmp strncasecmp
#define _stricmp strcasecmp
#define _P_WAIT 0
extern char **environ;
static inline int _spawnvp(int mode, const char *file, const char *const *argv)
{
    pid_t pid; int st;
    (void)mode;
    if (posix_spawnp(&pid, file, NULL, NULL, (char *const *)argv, environ)) return -1;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
#endif
