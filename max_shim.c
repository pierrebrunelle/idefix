#include <signal.h>
#include <stdio.h>
#include <unistd.h>

/* Forwards SIGINT/SIGTERM to the tracked child process group, then
   restores the default action and re-raises so the agent exits with
   the signal's status (e.g. 130 for SIGINT). */
static volatile sig_atomic_t g_pgid = 0;

static void forward_signal(int sig) {
    if (g_pgid) {
        kill(-g_pgid, sig);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void shim_install_signal_handlers(void) {
    signal(SIGINT, forward_signal);
    signal(SIGTERM, forward_signal);
}

void shim_track_pgid(int pgid) { g_pgid = pgid; }

/* REPL input: returns one NUL-terminated line (newline stripped) from stdin,
   NULL at EOF. Static buffer — valid until the next call, never freed. */
char *shim_read_line(void) {
    static char *line = NULL;
    static size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n <= 0) return NULL;
    if (line[n - 1] == '\n') line[n - 1] = 0;
    return line;
}

/* Nonzero when the last shim_read_line() NULL came from an error, not EOF. */
int shim_stdin_error(void) { return ferror(stdin); }
