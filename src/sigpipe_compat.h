#pragma once

/*
 * Ignore SIGPIPE so that writing to a child whose stdin has gone away
 * yields EPIPE instead of killing the process. Kept in C because Vala's
 * Posix.signal()/sigaction bindings emit a `sighandler_t` temporary, a
 * glibc-only typedef (macOS/BSD spell it `sig_t`).
 */
#ifndef _WIN32
#include <signal.h>
#include <string.h>

static inline void
parla_ignore_sigpipe (void)
{
	struct sigaction sa;
	memset (&sa, 0, sizeof (sa));
	sa.sa_handler = SIG_IGN;
	sigemptyset (&sa.sa_mask);
	sigaction (SIGPIPE, &sa, NULL);
}
#else
static inline void
parla_ignore_sigpipe (void)
{
}
#endif
