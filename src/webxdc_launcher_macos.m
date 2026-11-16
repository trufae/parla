/* A tiny XPC launch broker. It never parses app content and accepts only a
 * connected descriptor and offline/online mode. The caller cannot name an
 * executable. WKWebView requires network.client even for local content, so
 * offline mode is enforced by the view's request policy on macOS.
 * Each connection owns a distinct child inheriting this service's sandbox. */
#import <Foundation/Foundation.h>
#include "webxdc_sandbox_macos.h"
#include <xpc/xpc.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>

typedef struct { pid_t child; } Launch;

static void dispose (void *data)
{
    Launch *launch = data;
    if (launch->child > 0) {
        // We retain the unreaped PID until disconnect, so it cannot be reused.
        kill (launch->child, SIGKILL);
        while (waitpid (launch->child, NULL, 0) < 0 && errno == EINTR) {}
    }
    free (launch);
}

static void connection (xpc_connection_t peer)
{
    Launch *launch = calloc (1, sizeof (*launch));
    xpc_retain (peer);
    xpc_connection_set_context (peer, launch);
    xpc_connection_set_finalizer_f (peer, dispose);
    xpc_connection_set_event_handler (peer, ^(xpc_object_t event) {
        if (xpc_get_type (event) == XPC_TYPE_ERROR) { xpc_release (peer); return; }
        if (launch->child != 0 || xpc_get_type (event) != XPC_TYPE_DICTIONARY) {
            xpc_connection_cancel (peer); return;
        }
        int fd = xpc_dictionary_dup_fd (event, "channel");
        int type = 0; socklen_t size = sizeof (type);
        if (fd < 0 || getsockopt (fd, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM) {
            if (fd >= 0) close (fd);
            xpc_connection_cancel (peer); return;
        }
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *helper = [[bundle executablePath] stringByDeletingLastPathComponent];
        helper = [helper stringByAppendingPathComponent:@"parla-webxdc"];
        BOOL internet = xpc_dictionary_get_bool (event, "internet");
        char *argv[] = { (char *)[helper fileSystemRepresentation], internet ? "online" : "offline", NULL };
        // No inherited application, loader, browser-flag, or account settings.
        NSString *home = [@"HOME=" stringByAppendingString:NSHomeDirectory ()];
        NSString *fixed_home = [@"CFFIXED_USER_HOME=" stringByAppendingString:NSHomeDirectory ()];
        NSString *temporary = [@"TMPDIR=" stringByAppendingString:NSTemporaryDirectory ()];
        char *env[] = { "PATH=/usr/bin:/bin", "LANG=en_US.UTF-8",
            (char *)[home UTF8String], (char *)[fixed_home UTF8String],
            (char *)[temporary UTF8String], NULL };
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init (&actions);
        posix_spawn_file_actions_adddup2 (&actions, fd, STDIN_FILENO);
        posix_spawn_file_actions_adddup2 (&actions, fd, STDOUT_FILENO);
        posix_spawn_file_actions_addopen (&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawnattr_t attr;
        posix_spawnattr_init (&attr);
        posix_spawnattr_setflags (&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
        int result = posix_spawn (&launch->child, argv[0], &actions, &attr, argv, env);
        posix_spawnattr_destroy (&attr);
        posix_spawn_file_actions_destroy (&actions);
        close (fd);
        if (result != 0) { launch->child = 0; xpc_connection_cancel (peer); }
    });
    xpc_connection_resume (peer);
}

int main (void)
{
    // Check the running broker as well as the caller's on-disk preflight.
    // Development bundles with missing entitlements must never host apps.
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopySelf (kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecCodeCheckValidity (code, kSecCSDefaultFlags, NULL);
    if (status == errSecSuccess) status = parla_webxdc_require_sandbox (code);
    if (code) CFRelease (code);
    if (status != errSecSuccess) return 1;
    xpc_main (connection);
}
