#include <ctype.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* envp for model-issued commands: drops every variable whose NAME holds a
   credential marker so an `env` dump cannot put secrets into the transcript.
   Files stay readable; this narrows the channel, it is not a sandbox. */
extern char **environ;

char **shim_scrubbed_env(void) {
    static const char *pats[] = {
        "key", "token", "secret", "password", "credential"};
    static char *empty[] = {NULL};
    int n = 0;
    while (environ[n]) n++;
    char **out = calloc(n + 1, sizeof(char *));
    if (!out) return empty;
    int j = 0;
    for (int i = 0; i < n; i++) {
        char *e = environ[i];
        char *eq = strchr(e, '=');
        size_t name_len = eq ? (size_t)(eq - e) : strlen(e);
        /* match on a lowercased copy of the name so api_key and API_KEY
           both drop; names longer than the buffer cannot contain a
           credential marker anyway */
        char lname[128];
        size_t nl = name_len < sizeof(lname) - 1 ? name_len : sizeof(lname) - 1;
        for (size_t k = 0; k < nl; k++)
            lname[k] = (char)tolower((unsigned char)e[k]);
        lname[nl] = 0;
        int drop = 0;
        for (size_t k = 0; k < sizeof(pats) / sizeof(pats[0]); k++) {
            if (strstr(lname, pats[k])) {
                drop = 1;
                break;
            }
        }
        if (!drop) out[j++] = e;
    }
    out[j] = NULL;
    return out;
}

/* Writes the running executable's path into buf (NUL-terminated).
   _NSGetExecutablePath is Darwin-only; /proc/self/exe is the Linux
   equivalent. Returns 0 on success. */
#if defined(__APPLE__)
#include <mach-o/dyld.h>
int max_self_exe(char *buf, size_t size) {
    uint32_t n = (uint32_t)size;
    return _NSGetExecutablePath(buf, &n);
}
#elif defined(__linux__)
int max_self_exe(char *buf, size_t size) {
    ssize_t n = readlink("/proc/self/exe", buf, size - 1);
    if (n <= 0) return -1;
    buf[n] = '\0';
    return 0;
}
#else
int max_self_exe(char *buf, size_t size) { (void)buf; (void)size; return -1; }
#endif
