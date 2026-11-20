#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <userenv.h>
#include <sddl.h>
#include <shlobj.h>
#include <stdio.h>
#include <wchar.h>
#include "webxdc_sandbox.h"
#include <gio/gwin32inputstream.h>
#include <gio/gwin32outputstream.h>

typedef struct { HANDLE job, process; wchar_t *profile; } Sandbox;

static wchar_t *wide (const char *text) { return (wchar_t *)g_utf8_to_utf16 (text, -1, NULL, NULL, NULL); }
static wchar_t *join (const wchar_t *dir, const wchar_t *name)
{
    size_t n = wcslen (dir) + wcslen (name) + 2;
    wchar_t *path = g_new (wchar_t, n);
    swprintf (path, n, L"%ls\\%ls", dir, name);
    return path;
}

/* Copy bytes into a newly created file, inheriting the container directory's
 * ACL and integrity label. CopyFile can preserve the installation's ACL. */
static gboolean copy_runtime (const wchar_t *source, const wchar_t *dest)
{
    HANDLE input = CreateFileW (source, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (input == INVALID_HANDLE_VALUE) return FALSE;
    HANDLE output = CreateFileW (dest, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    gboolean ok = output != INVALID_HANDLE_VALUE;
    BYTE buffer[65536];
    DWORD count, written;
    while (ok) {
        ok = ReadFile (input, buffer, sizeof (buffer), &count, NULL);
        if (!ok || !count) break;
        ok = WriteFile (output, buffer, count, &written, NULL) && written == count;
    }
    DWORD error = GetLastError ();
    if (output != INVALID_HANDLE_VALUE) CloseHandle (output);
    CloseHandle (input);
    SetLastError (error);
    return ok;
}

/* Stage only the helper's import closure in its private container. Never
 * modify ACLs on the installation or expose the account directory. Import
 * names come from our trusted installed PE files, not from web content. */
static gboolean stage (const wchar_t *source, const wchar_t *directory,
    GHashTable *copied, GError **error)
{
    const wchar_t *name = wcsrchr (source, L'\\');
    name = name ? name + 1 : source;
    g_autofree char *utf8 = g_utf16_to_utf8 ((const gunichar2 *)name, -1, NULL, NULL, NULL);
    g_autofree char *key = g_ascii_strdown (utf8, -1);
    if (g_hash_table_contains (copied, key)) return TRUE;
    g_hash_table_add (copied, g_strdup (key));
    g_autofree wchar_t *dest = join (directory, name);
    if (!copy_runtime (source, dest)) goto failure;
    HANDLE file = CreateFileW (source, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) goto failure;
    HANDLE mapping = CreateFileMappingW (file, NULL, PAGE_READONLY | SEC_IMAGE, 0, 0, NULL);
    CloseHandle (file);
    if (!mapping) goto failure;
    BYTE *image = MapViewOfFile (mapping, FILE_MAP_READ, 0, 0, 0);
    CloseHandle (mapping);
    if (!image) goto failure;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)image;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(image + dos->e_lfanew);
    DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    gboolean ok = TRUE;
    if (rva) {
        IMAGE_IMPORT_DESCRIPTOR *imports = (IMAGE_IMPORT_DESCRIPTOR *)(image + rva);
        for (; imports->Name && ok; imports++) {
            const char *dll = (const char *)(image + imports->Name);
            if (strchr (dll, '/') || strchr (dll, '\\') || strchr (dll, ':')) { ok = FALSE; break; }
            g_autofree wchar_t *wdll = wide (dll);
            wchar_t system[MAX_PATH];
            GetSystemDirectoryW (system, MAX_PATH);
            g_autofree wchar_t *system_dll = join (system, wdll);
            if (GetFileAttributesW (system_dll) != INVALID_FILE_ATTRIBUTES
                || g_str_has_prefix (dll, "api-ms-") || g_str_has_prefix (dll, "ext-ms-")) continue;
            wchar_t loaded[32768];
            HMODULE module = GetModuleHandleW (wdll);
            if (module && GetModuleFileNameW (module, loaded, G_N_ELEMENTS (loaded))) {
                ok = stage (loaded, directory, copied, error);
            } else {
                g_autofree wchar_t *parent = g_memdup2 (source, (wcslen (source) + 1) * sizeof (wchar_t));
                wchar_t *slash = wcsrchr (parent, L'\\');
                if (!slash) { ok = FALSE; break; }
                *slash = 0;
                g_autofree wchar_t *dependency = join (parent, wdll);
                /* Build-tree helpers resolve their DLLs through PATH rather
                 * than living next to every dependency. Search there before
                 * giving up, but never copy a directory or an absolute path
                 * supplied by the PE we are parsing. */
                if (GetFileAttributesW (dependency) == INVALID_FILE_ATTRIBUTES) {
                    wchar_t found[32768];
                    DWORD length = SearchPathW (NULL, wdll, NULL,
                        G_N_ELEMENTS (found), found, NULL);
                    if (length > 0 && length < G_N_ELEMENTS (found)) {
                        g_free (dependency);
                        dependency = g_memdup2 (found,
                            (wcslen (found) + 1) * sizeof (wchar_t));
                    }
                }
                ok = stage (dependency, directory, copied, error);
            }
        }
    }
    UnmapViewOfFile (image);
    if (ok) return TRUE;
failure:
    if (!error || !*error) g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
        "Cannot stage Webxdc sandbox runtime (Windows error %lu)", GetLastError ());
    return FALSE;
}

static gpointer cleanup (gpointer data)
{
    Sandbox *sandbox = data;
    if (sandbox->job) TerminateJobObject (sandbox->job, 0);
    if (sandbox->process) { WaitForSingleObject (sandbox->process, INFINITE); CloseHandle (sandbox->process); }
    if (sandbox->job) {
        // Wait for WebView2 descendants to release their files before deleting
        // the profile. This runs off the UI thread; closing the job also kills
        // any remaining members if termination has stalled.
        for (int i = 0; i < 500; i++) {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
            if (!QueryInformationJobObject (sandbox->job, JobObjectBasicAccountingInformation,
                &info, sizeof (info), NULL) || info.ActiveProcesses == 0) break;
            Sleep (10);
        }
        CloseHandle (sandbox->job);
    }
    if (sandbox->profile) DeleteAppContainerProfile (sandbox->profile);
    g_free (sandbox->profile);
    g_free (sandbox);
    return NULL;
}

gpointer parla_webxdc_sandbox_launch (const char *helper, gboolean internet, gboolean acceleration, gboolean wasm,
    GInputStream **input, GOutputStream **output, GError **error)
{
    (void)acceleration; (void)wasm;
    *input = NULL; *output = NULL;
    Sandbox *sandbox = g_new0 (Sandbox, 1);
    g_autofree char *uuid = g_uuid_string_random ();
    g_autofree char *name = g_strconcat ("Parla.Webxdc.", uuid, NULL);
    sandbox->profile = wide (name);
    PSID sid = NULL, network = NULL;
    PWSTR folder = NULL;
    HANDLE in_read = NULL, in_write = NULL, out_read = NULL, out_write = NULL, err = NULL;
    STARTUPINFOEXW si = {0};
    PROCESS_INFORMATION pi = {0};
    gboolean attributes_ready = FALSE, success = FALSE;
    g_autofree wchar_t *executable = wide (helper);
    g_autofree wchar_t *command = NULL;
    g_autofree wchar_t *env = NULL;
    /* GLib and Python also supply Windows paths with forward slashes. Keep
     * the staging code's basename and parent lookups in native form. */
    for (wchar_t *p = executable; *p; p++) {
        if (*p == L'/') *p = L'\\';
    }
    HRESULT result = CreateAppContainerProfile (sandbox->profile, L"Parla Webxdc", L"Isolated chat app", NULL, 0, &sid);
    if (FAILED (result)) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot create Webxdc AppContainer (HRESULT 0x%08lx)", result);
        goto failure;
    }
    LPWSTR sid_text = NULL;
    if (!ConvertSidToStringSidW (sid, &sid_text)) goto failure;
    result = GetAppContainerFolderPath (sid_text, &folder);
    LocalFree (sid_text);
    if (FAILED (result)) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot locate Webxdc AppContainer (HRESULT 0x%08lx)", result);
        goto failure;
    }
    {
        g_autoptr(GHashTable) copied = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
        if (!stage (executable, folder, copied, error)) goto failure;
        g_autofree wchar_t *parent = g_memdup2 (executable, (wcslen (executable) + 1) * sizeof (wchar_t));
        wchar_t *slash = wcsrchr (parent, L'\\');
        if (!slash) goto failure;
        *slash = 0;
        g_autofree wchar_t *loader = join (parent, L"WebView2Loader.dll");
        if (!stage (loader, folder, copied, error)) goto failure;
    }
    wchar_t *staged = join (folder, wcsrchr (executable, L'\\') + 1);
    g_free (executable);
    executable = staged;
    SECURITY_ATTRIBUTES sa = { sizeof (sa), NULL, TRUE };
    if (!CreatePipe (&in_read, &in_write, &sa, 0) || !CreatePipe (&out_read, &out_write, &sa, 0)
        || !SetHandleInformation (in_write, HANDLE_FLAG_INHERIT, 0)
        || !SetHandleInformation (out_read, HANDLE_FLAG_INHERIT, 0)) goto failure;
    // Preserve startup diagnostics while inheriting only a write handle.
    HANDLE parent_err = GetStdHandle (STD_ERROR_HANDLE);
    if (!parent_err || parent_err == INVALID_HANDLE_VALUE
        || !DuplicateHandle (GetCurrentProcess (), parent_err, GetCurrentProcess (),
            &err, GENERIC_WRITE, TRUE, 0))
        err = CreateFileW (L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE | FILE_SHARE_READ, &sa, OPEN_EXISTING, 0, NULL);
    if (err == INVALID_HANDLE_VALUE) { err = NULL; goto failure; }
    SECURITY_CAPABILITIES capabilities = {0};
    SID_AND_ATTRIBUTES network_capability = {0};
    capabilities.AppContainerSid = sid;
    if (internet) {
        DWORD bytes = SECURITY_MAX_SID_SIZE;
        network = g_malloc0 (bytes);
        if (!CreateWellKnownSid (WinCapabilityInternetClientSid, NULL, network, &bytes)) goto failure;
        network_capability.Sid = network;
        network_capability.Attributes = SE_GROUP_ENABLED;
        capabilities.Capabilities = &network_capability;
        capabilities.CapabilityCount = 1;
    }
    SIZE_T size = 0;
    InitializeProcThreadAttributeList (NULL, 2, 0, &size);
    si.lpAttributeList = g_malloc0 (size);
    if (!InitializeProcThreadAttributeList (si.lpAttributeList, 2, 0, &size)) goto failure;
    attributes_ready = TRUE;
    HANDLE handles[] = { in_read, out_write, err };
    if (!UpdateProcThreadAttribute (si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES,
            &capabilities, sizeof (capabilities), NULL, NULL)
        || !UpdateProcThreadAttribute (si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            handles, sizeof (handles), NULL, NULL)) goto failure;
    sandbox->job = CreateJobObjectW (NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        | JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_JOB_MEMORY;
    limits.BasicLimitInformation.ActiveProcessLimit = 64;
    limits.JobMemoryLimit = (SIZE_T)1024 * 1024 * 1024;
    if (!sandbox->job || !SetInformationJobObject (sandbox->job, JobObjectExtendedLimitInformation, &limits, sizeof (limits))) goto failure;
    si.StartupInfo.cb = sizeof (si);
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_read; si.StartupInfo.hStdOutput = out_write; si.StartupInfo.hStdError = err;
    size_t chars = wcslen (executable) + 32;
    command = g_new (wchar_t, chars);
    swprintf (command, chars, L"\"%ls\" %ls", executable, internet ? L"online" : L"offline");
    wchar_t windows[MAX_PATH];
    GetWindowsDirectoryW (windows, MAX_PATH);
    chars = wcslen (folder) * 4 + wcslen (windows) * 3 + 256;
    env = g_new0 (wchar_t, chars);
    wchar_t *p = env;
    p += swprintf (p, chars, L"LOCALAPPDATA=%ls", folder) + 1;
    p += swprintf (p, chars - (p - env), L"PATH=%ls\\System32", windows) + 1;
    p += swprintf (p, chars - (p - env), L"SystemRoot=%ls", windows) + 1;
    p += swprintf (p, chars - (p - env), L"TEMP=%ls", folder) + 1;
    p += swprintf (p, chars - (p - env), L"TMP=%ls", folder) + 1;
    p += swprintf (p, chars - (p - env), L"USERPROFILE=%ls", folder) + 1;
    swprintf (p, chars - (p - env), L"windir=%ls", windows);
    if (!CreateProcessW (executable, command, NULL, NULL, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW,
        env, folder, &si.StartupInfo, &pi)) goto failure;
    sandbox->process = pi.hProcess;
    if (!AssignProcessToJobObject (sandbox->job, pi.hProcess) || ResumeThread (pi.hThread) == (DWORD)-1) {
        TerminateProcess (pi.hProcess, 1); goto failure;
    }
    *input = g_win32_input_stream_new (out_read, TRUE); out_read = NULL;
    *output = g_win32_output_stream_new (in_write, TRUE); in_write = NULL;
    success = TRUE;
failure:
    if (!success && (!error || !*error)) g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
        "Cannot launch Webxdc AppContainer (Windows error %lu)", GetLastError ());
    if (pi.hThread) CloseHandle (pi.hThread);
    if (attributes_ready) DeleteProcThreadAttributeList (si.lpAttributeList);
    g_free (si.lpAttributeList);
    if (sid) FreeSid (sid);
    g_free (network);
    if (folder) CoTaskMemFree (folder);
    if (in_read) CloseHandle (in_read);
    if (in_write) CloseHandle (in_write);
    if (out_read) CloseHandle (out_read);
    if (out_write) CloseHandle (out_write);
    if (err) CloseHandle (err);
    if (!success) { cleanup (sandbox); return NULL; }
    return sandbox;
}

void parla_webxdc_sandbox_stop (gpointer process)
{
    GThread *thread = g_thread_new ("webxdc-cleanup", cleanup, process);
    g_thread_unref (thread);
}
