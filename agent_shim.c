#include <signal.h>
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
