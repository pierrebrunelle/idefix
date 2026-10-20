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

/* libcurl write callback enforcing a byte cap. CURLOPT_MAXFILESIZE_LARGE
   relies on libcurl's own bytecount tracking (older libcurls only applied
   it with a known Content-Length); this callback bounds the body no matter
   how the response is framed. Returning 0 aborts with CURLE_WRITE_ERROR. */
static size_t g_http_cap = 0; /* 0 = uncapped */
static size_t g_http_seen = 0;
static int g_http_capped = 0;

void shim_http_cap(size_t cap) {
    g_http_cap = cap;
    g_http_seen = 0;
    g_http_capped = 0;
}

int shim_http_capped(void) { return g_http_capped; }

static size_t shim_write_cb(char *ptr, size_t size, size_t nmemb,
                            void *userdata) {
    size_t n = size * nmemb;
    if (g_http_cap && (g_http_seen >= g_http_cap || n > g_http_cap - g_http_seen)) {
        g_http_capped = 1;
        return 0;
    }
    g_http_seen += n;
    return fwrite(ptr, size, nmemb, (FILE *)userdata);
}

void *shim_write_cb_ptr(void) { return (void *)shim_write_cb; }

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
