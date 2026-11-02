#ifndef KITELOOP_TEST_LOG_REDIRECT_H
#define KITELOOP_TEST_LOG_REDIRECT_H

/// Points a test process's Kiteloop logs at a temporary directory, by setting
/// KITELOOP_LOG_BASE_DIRECTORY when nothing else has.
///
/// Called for you: this target carries a load-time constructor that runs it
/// before any test in the bundle does, which is the whole reason the target is
/// C. Idempotent, and a no-op once the variable is set.
void kiteloop_test_log_redirect_install(void);

#endif
