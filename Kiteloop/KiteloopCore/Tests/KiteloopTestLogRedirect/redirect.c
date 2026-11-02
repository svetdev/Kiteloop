// KiteloopTestLogRedirect — the one place a test process's Kiteloop logs are
// pointed away from the human's Kiteloop home, run once, before any test.
//
// KiteloopFileLogger.shared is a singleton every service logs through
// (`kiteloopLog`), and until a project is opened it writes under ~/.kiteloop.
// A test process opens no project, so every line a fixture provoked — a store
// reporting a write it was made to fail, a tokens file moved aside, the ring
// buffer's cap probe — was appended to the day's real log, the one a human
// reads to debug the running app: over a hundred thousand lines a day, from a
// verify that runs `swift test` on every autopilot run.
//
// The fix has to be in place before the first line is logged, which is before
// any test code runs — and Swift has no load-time hook, so this target is C for
// its one `__attribute__((constructor))`. KiteloopTestSupport depends on it, so
// linking the test helpers is what installs the redirect: `swift test` on its
// own is covered, not only scripts/run-core-tests.sh.
//
// The destination is a fixed directory under the process's temp root rather
// than a fresh one per run, so nothing accumulates: KiteloopFileLogger prunes
// its own logs after seven days, and a human debugging a test run can find the
// file without knowing which run wrote it.

#include "include/KiteloopTestLogRedirect.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syslimits.h>

static const char *const kBaseDirectoryKey = "KITELOOP_LOG_BASE_DIRECTORY";

/// The temp root to log under, without its trailing slash — TMPDIR names one on
/// macOS, and "…/T//kiteloop-test-logs" is a path nobody wants to read in an
/// error message.
static size_t kiteloop_temp_root(char *buffer, size_t capacity) {
    const char *root = getenv("TMPDIR");
    if (root == NULL || root[0] == '\0') {
        root = "/tmp";
    }
    size_t length = strlen(root);
    while (length > 1 && root[length - 1] == '/') {
        length -= 1;
    }
    if (length >= capacity) {
        return 0;
    }
    memcpy(buffer, root, length);
    buffer[length] = '\0';
    return length;
}

void kiteloop_test_log_redirect_install(void) {
    // Already pointed somewhere: scripts/run-core-tests.sh exports a scratch
    // directory it deletes on exit, and a caller driving the package by hand
    // may name one too. Neither is overruled here.
    const char *existing = getenv(kBaseDirectoryKey);
    if (existing != NULL && existing[0] != '\0') {
        return;
    }

    char root[PATH_MAX];
    if (kiteloop_temp_root(root, sizeof root) == 0) {
        return;
    }

    char destination[PATH_MAX];
    int written = snprintf(destination, sizeof destination, "%s/kiteloop-test-logs", root);
    if (written < 0 || (size_t)written >= sizeof destination) {
        return;
    }
    setenv(kBaseDirectoryKey, destination, 1);
}

__attribute__((constructor))
static void kiteloop_test_log_redirect_on_load(void) {
    kiteloop_test_log_redirect_install();
}
