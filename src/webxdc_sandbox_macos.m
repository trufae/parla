#include "webxdc_sandbox.h"
#include "webxdc_sandbox_macos.h"
#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <gio/gunixinputstream.h>
#include <gio/gunixoutputstream.h>

typedef struct { xpc_connection_t connection; int fd; } Sandbox;

static void dispose (void *data)
{
    Sandbox *sandbox = data;
    close (sandbox->fd);
    g_free (sandbox);
}

gpointer parla_webxdc_sandbox_launch (const char *helper, gboolean internet, gboolean acceleration, gboolean wasm,
    GInputStream **input, GOutputStream **output, GError **error)
{
    (void)helper; (void)acceleration; (void)wasm;
    *input = NULL; *output = NULL;
    NSString *service = @"io.github.trufae.Parla.Webxdc";
    NSString *bundle = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"Contents/XPCServices/%@.xpc", service]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:bundle]) {
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
            "Webxdc sandbox services are missing. Run the signed Parla.app bundle (make run).");
        return NULL;
    }
    // An unsigned/development bundle must not silently turn this into an
    // ordinary XPC service. Verify the service's sandbox entitlement and
    // nested signatures before handing it any app content.
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath ((CFURLRef)[NSURL fileURLWithPath:bundle],
        kSecCSDefaultFlags, &code);
    if (status == errSecSuccess)
        status = SecStaticCodeCheckValidity (code, kSecCSStrictValidate | kSecCSCheckNestedCode, NULL);
    if (status == errSecSuccess) status = parla_webxdc_require_sandbox ((SecCodeRef)code);
    if (code) CFRelease (code);
    if (status != errSecSuccess) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
            "Webxdc service signature or sandbox entitlement is invalid (OSStatus %d)", (int)status);
        return NULL;
    }
    int pair[2];
    if (socketpair (AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno), "Webxdc socketpair: %s", g_strerror (errno));
        return NULL;
    }
    fcntl (pair[0], F_SETFD, FD_CLOEXEC);
    fcntl (pair[1], F_SETFD, FD_CLOEXEC);
    int enabled = 1;
    setsockopt (pair[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof (enabled));
    Sandbox *sandbox = g_new0 (Sandbox, 1);
    sandbox->fd = pair[0];
    sandbox->connection = xpc_connection_create ([service UTF8String], dispatch_get_global_queue (QOS_CLASS_USER_INITIATED, 0));
    xpc_connection_set_context (sandbox->connection, sandbox);
    xpc_connection_set_finalizer_f (sandbox->connection, dispose);
    xpc_connection_set_event_handler (sandbox->connection, ^(xpc_object_t event) {
        if (xpc_get_type (event) == XPC_TYPE_ERROR) shutdown (sandbox->fd, SHUT_RDWR);
    });
    xpc_connection_resume (sandbox->connection);
    xpc_object_t request = xpc_dictionary_create (NULL, NULL, 0);
    xpc_dictionary_set_fd (request, "channel", pair[1]);
    xpc_dictionary_set_bool (request, "internet", internet);
    xpc_connection_send_message (sandbox->connection, request);
    xpc_release (request);
    close (pair[1]);
    int read_fd = fcntl (pair[0], F_DUPFD_CLOEXEC, 0);
    int write_fd = fcntl (pair[0], F_DUPFD_CLOEXEC, 0);
    if (read_fd < 0 || write_fd < 0) {
        if (read_fd >= 0) close (read_fd);
        if (write_fd >= 0) close (write_fd);
        parla_webxdc_sandbox_stop (sandbox);
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot open Webxdc channel");
        return NULL;
    }
    *input = g_unix_input_stream_new (read_fd, TRUE);
    *output = g_unix_output_stream_new (write_fd, TRUE);
    return sandbox;
}

void parla_webxdc_sandbox_stop (gpointer process)
{
    Sandbox *sandbox = process;
    shutdown (sandbox->fd, SHUT_RDWR);
    xpc_connection_cancel (sandbox->connection);
    xpc_release (sandbox->connection);
}
