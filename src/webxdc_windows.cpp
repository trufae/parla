#include "webxdc_windows.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>

#include <WebView2.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <cwchar>
#include <functional>
#include <string>
#include <unordered_set>
#include <utility>

/*
 * Windows-only Webxdc view. WebView2Loader.dll locates the installed
 * Evergreen Edge runtime; Parla intercepts an otherwise nonexistent secure
 * HTTPS origin and supplies every response from deltachat-core.
 */

static constexpr wchar_t kWindowClass[] = L"ParlaWebxdcWindow";
static constexpr wchar_t kOrigin[] = L"https://webxdc.invalid";
static constexpr wchar_t kStartUri[] = L"https://webxdc.invalid/index.html";
static constexpr wchar_t kNoWasmCsp[] =
    L"script-src 'self' 'unsafe-inline' data: blob: http: https:";

struct WebxdcWindow;
struct RequestTask;

static void window_ref (WebxdcWindow *window);
static void window_unref (WebxdcWindow *window);
static LRESULT CALLBACK window_proc (HWND hwnd, UINT message,
                                     WPARAM wparam, LPARAM lparam);

static HRESULT
copy_wide (const std::wstring &source, LPWSTR *value)
{
    if (value == nullptr)
        return E_POINTER;
    if (source.empty ()) {
        *value = nullptr;
        return S_OK;
    }
    size_t bytes = (source.size () + 1) * sizeof (wchar_t);
    *value = static_cast<LPWSTR> (CoTaskMemAlloc (bytes));
    if (*value == nullptr)
        return E_OUTOFMEMORY;
    std::memcpy (*value, source.c_str (), bytes);
    return S_OK;
}

/* Only the base options interface is needed: it gives safe-mode views a
 * dead proxy and disables WebGL/GPU without depending on Chromium content
 * interception as the sole network boundary. */
class EnvironmentOptions final : public ICoreWebView2EnvironmentOptions {
public:
    explicit EnvironmentOptions (std::wstring arguments)
        : arguments_ (std::move (arguments)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface (REFIID iid, void **object) override
    {
        if (object == nullptr)
            return E_POINTER;
        *object = nullptr;
        if (!InlineIsEqualGUID (iid, IID_IUnknown)
            && !InlineIsEqualGUID (iid, IID_ICoreWebView2EnvironmentOptions))
            return E_NOINTERFACE;
        *object = static_cast<ICoreWebView2EnvironmentOptions *> (this);
        AddRef ();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef () override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release () override
    {
        ULONG refs = --refs_;
        if (refs == 0)
            delete this;
        return refs;
    }
    HRESULT STDMETHODCALLTYPE get_AdditionalBrowserArguments (LPWSTR *value) override
    { return copy_wide (arguments_, value); }
    HRESULT STDMETHODCALLTYPE put_AdditionalBrowserArguments (LPCWSTR value) override
    { arguments_ = value != nullptr ? value : L""; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_Language (LPWSTR *value) override
    { return copy_wide ({}, value); }
    HRESULT STDMETHODCALLTYPE put_Language (LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_TargetCompatibleBrowserVersion (LPWSTR *value) override
    { return copy_wide ({}, value); }
    HRESULT STDMETHODCALLTYPE put_TargetCompatibleBrowserVersion (LPCWSTR) override
    { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_AllowSingleSignOnUsingOSPrimaryAccount (
        BOOL *value) override
    {
        if (value == nullptr)
            return E_POINTER;
        *value = FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_AllowSingleSignOnUsingOSPrimaryAccount (
        BOOL) override
    { return S_OK; }

private:
    ~EnvironmentOptions () = default;
    std::atomic<ULONG> refs_ { 1 };
    std::wstring arguments_;
};

/* All WebView2 callbacks are one-method COM interfaces. This generic wrapper
 * keeps the plumbing small while retaining the owning native window until an
 * asynchronous callback or registered event is released. */
template<typename Interface, typename... Args>
class Callback final : public Interface {
public:
    Callback (WebxdcWindow *owner, const IID &iid,
              std::function<HRESULT (Args...)> function)
        : owner_ (owner), iid_ (iid), function_ (std::move (function))
    { window_ref (owner_); }

    HRESULT STDMETHODCALLTYPE QueryInterface (REFIID iid, void **object) override
    {
        if (object == nullptr)
            return E_POINTER;
        *object = nullptr;
        if (!InlineIsEqualGUID (iid, IID_IUnknown)
            && !InlineIsEqualGUID (iid, iid_))
            return E_NOINTERFACE;
        *object = static_cast<Interface *> (this);
        AddRef ();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef () override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release () override
    {
        ULONG refs = --refs_;
        if (refs == 0)
            delete this;
        return refs;
    }
    HRESULT STDMETHODCALLTYPE Invoke (Args... args) override
    { return function_ (args...); }

private:
    ~Callback () { window_unref (owner_); }
    WebxdcWindow *owner_;
    const IID &iid_;
    std::function<HRESULT (Args...)> function_;
    std::atomic<ULONG> refs_ { 1 };
};

struct WebxdcWindow {
    std::atomic<ULONG> refs { 1 };
    HWND hwnd = nullptr;
    HMODULE loader = nullptr;
    bool co_initialized = false;
    bool closed = false;
    bool cleaned = false;
    bool closed_notified = false;
    bool script_ready = false;
    bool load_requested = false;
    bool allow_internet = false;
    bool allow_wasm = false;
    bool allow_webgl = false;
    bool developer_tools = false;
    ParlaWebxdcWinBlobFn blob_cb = nullptr;
    ParlaWebxdcWinMsgFn message_cb = nullptr;
    ParlaWebxdcWinClosedFn closed_cb = nullptr;
    gpointer user_data = nullptr;
    std::wstring user_data_folder;
    ICoreWebView2Environment *environment = nullptr;
    ICoreWebView2Controller *controller = nullptr;
    ICoreWebView2 *view = nullptr;
    ICoreWebView2_4 *view4 = nullptr;
    EventRegistrationToken resource_token {};
    EventRegistrationToken message_token {};
    EventRegistrationToken navigation_token {};
    EventRegistrationToken new_window_token {};
    EventRegistrationToken permission_token {};
    EventRegistrationToken download_token {};
    bool resource_registered = false;
    bool message_registered = false;
    bool navigation_registered = false;
    bool new_window_registered = false;
    bool permission_registered = false;
    bool download_registered = false;
    std::unordered_set<RequestTask *> tasks;

    ~WebxdcWindow ();
    void fail (const char *stage, HRESULT error);
    void cleanup ();
    void notify_closed ();
    void navigate ();
    void resize ();
    HRESULT environment_created (HRESULT result,
                                 ICoreWebView2Environment *created);
    HRESULT controller_created (HRESULT result,
                                ICoreWebView2Controller *created);
    HRESULT resource_requested (ICoreWebView2WebResourceRequestedEventArgs *args);
};

struct RequestTask {
    WebxdcWindow *owner;
    ICoreWebView2WebResourceRequestedEventArgs *args;
    ICoreWebView2Deferral *deferral;

    RequestTask (WebxdcWindow *owner,
                 ICoreWebView2WebResourceRequestedEventArgs *args,
                 ICoreWebView2Deferral *deferral)
        : owner (owner), args (args), deferral (deferral)
    { args->AddRef (); }
    ~RequestTask ()
    {
        args->Release ();
        deferral->Release ();
    }
};

static void window_ref (WebxdcWindow *window) { ++window->refs; }
static void window_unref (WebxdcWindow *window)
{
    if (--window->refs == 0)
        delete window;
}

static std::wstring
utf8_to_wide (const char *text)
{
    if (text == nullptr)
        return {};
    glong length = 0;
    gunichar2 *value = g_utf8_to_utf16 (text, -1, nullptr, &length, nullptr);
    if (value == nullptr)
        return {};
    std::wstring result (reinterpret_cast<wchar_t *> (value),
                         static_cast<size_t> (length));
    g_free (value);
    return result;
}

static std::string
wide_to_utf8 (LPCWSTR text)
{
    if (text == nullptr)
        return {};
    glong length = 0;
    gchar *value = g_utf16_to_utf8 (
        reinterpret_cast<const gunichar2 *> (text), -1,
        nullptr, &length, nullptr);
    if (value == nullptr)
        return {};
    std::string result (value, static_cast<size_t> (length));
    g_free (value);
    return result;
}

static bool
is_app_uri (LPCWSTR uri)
{
    if (uri == nullptr)
        return false;
    size_t length = std::wcslen (kOrigin);
    if (_wcsnicmp (uri, kOrigin, length) != 0)
        return false;
    return uri[length] == L'\0' || uri[length] == L'/';
}

static int
hex_value (char value)
{
    if (value >= '0' && value <= '9')
        return value - '0';
    value = static_cast<char> (std::tolower (static_cast<unsigned char> (value)));
    return value >= 'a' && value <= 'f' ? value - 'a' + 10 : -1;
}

static std::string
request_path (LPCWSTR uri)
{
    std::string value = wide_to_utf8 (uri);
    size_t origin_length = std::strlen ("https://webxdc.invalid");
    std::string path = value.size () >= origin_length
        ? value.substr (origin_length) : "/index.html";
    size_t suffix = path.find_first_of ("?#");
    if (suffix != std::string::npos)
        path.resize (suffix);
    if (path.empty ())
        path = "/index.html";
    std::string decoded;
    decoded.reserve (path.size ());
    for (size_t i = 0; i < path.size (); i++) {
        if (path[i] == '%' && i + 2 < path.size ()) {
            int high = hex_value (path[i + 1]);
            int low = hex_value (path[i + 2]);
            if (high >= 0 && low >= 0) {
                decoded.push_back (static_cast<char> ((high << 4) | low));
                i += 2;
                continue;
            }
        }
        decoded.push_back (path[i]);
    }
    return decoded;
}

static std::wstring
safe_mime (const char *mime)
{
    std::string value = mime != nullptr ? mime : "application/octet-stream";
    for (char byte : value) {
        if (!(std::isalnum (static_cast<unsigned char> (byte))
              || std::strchr ("/+-.;= ", byte) != nullptr))
            return L"application/octet-stream";
    }
    return utf8_to_wide (value.c_str ());
}

static HRESULT
make_response (WebxdcWindow *window, const guint8 *data, gint length,
               const char *mime, int status,
               ICoreWebView2WebResourceResponse **response)
{
    *response = nullptr;
    HGLOBAL memory = nullptr;
    if (length > 0) {
        memory = GlobalAlloc (GMEM_MOVEABLE, static_cast<SIZE_T> (length));
        if (memory == nullptr)
            return E_OUTOFMEMORY;
        void *target = GlobalLock (memory);
        if (target == nullptr) {
            GlobalFree (memory);
            return HRESULT_FROM_WIN32 (GetLastError ());
        }
        std::memcpy (target, data, static_cast<size_t> (length));
        GlobalUnlock (memory);
    }
    IStream *stream = nullptr;
    HRESULT result = CreateStreamOnHGlobal (memory, TRUE, &stream);
    if (FAILED (result)) {
        if (memory != nullptr)
            GlobalFree (memory);
        return result;
    }
    std::wstring headers = L"Content-Type: " + safe_mime (mime)
        + L"\r\nX-Content-Type-Options: nosniff";
    if (!window->allow_wasm)
        headers += std::wstring (L"\r\nContent-Security-Policy: ") + kNoWasmCsp;
    LPCWSTR reason = status == 200 ? L"OK" :
                     status == 403 ? L"Forbidden" : L"Not Found";
    result = window->environment->CreateWebResourceResponse (
        stream, status, reason, headers.c_str (), response);
    stream->Release ();
    return result;
}

static void
finish_request (RequestTask *task, const guint8 *data, gint length,
                const char *mime, int status)
{
    ICoreWebView2WebResourceResponse *response = nullptr;
    if (task->owner->environment != nullptr
        && SUCCEEDED (make_response (task->owner, data, length, mime,
                                     status, &response))) {
        task->args->put_Response (response);
        response->Release ();
    }
    task->deferral->Complete ();
    delete task;
}

HRESULT
WebxdcWindow::resource_requested (ICoreWebView2WebResourceRequestedEventArgs *args)
{
    if (closed)
        return S_OK;
    ICoreWebView2WebResourceRequest *request = nullptr;
    LPWSTR uri = nullptr;
    HRESULT result = args->get_Request (&request);
    if (SUCCEEDED (result)) {
        result = request->get_Uri (&uri);
        request->Release ();
    }
    if (SUCCEEDED (result) && is_app_uri (uri)) {
        ICoreWebView2Deferral *deferral = nullptr;
        result = args->GetDeferral (&deferral);
        if (SUCCEEDED (result)) {
            auto *task = new RequestTask (this, args, deferral);
            tasks.insert (task);
            std::string path = request_path (uri);
            CoTaskMemFree (uri);
            blob_cb (path.c_str (), task, user_data);
            return S_OK;
        }
    }
    CoTaskMemFree (uri);
    if (!allow_internet && environment != nullptr) {
        ICoreWebView2WebResourceResponse *response = nullptr;
        if (SUCCEEDED (make_response (this, nullptr, 0, "text/plain", 403,
                                      &response))) {
            args->put_Response (response);
            response->Release ();
        }
    }
    return S_OK;
}

static std::wstring
document_start_script (const WebxdcWindow *window)
{
    std::wstring script =
        LR"JS((()=>{'use strict';const h=Object.freeze({postMessage(v){window.chrome.webview.postMessage(String(v));}});try{Object.defineProperty(window,'webkit',{value:Object.freeze({messageHandlers:Object.freeze({webxdc:h})}),writable:false,configurable:false});}catch(e){}})();)JS";
    if (!window->allow_internet) {
        script +=
            LR"JS((()=>{for(const n of ['WebSocket','EventSource','RTCPeerConnection','webkitRTCPeerConnection','WebTransport']){try{Object.defineProperty(window,n,{value:undefined,writable:false,configurable:false});}catch(e){}}try{Object.defineProperty(navigator,'serviceWorker',{value:undefined,writable:false,configurable:false});}catch(e){}})();)JS";
    }
    if (!window->allow_webgl) {
        script +=
            LR"JS((()=>{const b=p=>{if(!p||!p.getContext)return;const o=p.getContext;Object.defineProperty(p,'getContext',{writable:false,configurable:false,value:function(t){t=String(t).toLowerCase();return t==='webgl'||t==='webgl2'||t==='experimental-webgl'?null:o.apply(this,arguments);}});};b(window.HTMLCanvasElement&&HTMLCanvasElement.prototype);b(window.OffscreenCanvas&&OffscreenCanvas.prototype);})();)JS";
    }
    return script;
}

template<typename Interface, typename... Args, typename Function>
static Callback<Interface, Args...> *
callback (WebxdcWindow *window, const IID &iid, Function function)
{
    return new Callback<Interface, Args...> (
        window, iid, std::function<HRESULT (Args...)> (function));
}

HRESULT
WebxdcWindow::controller_created (HRESULT result,
                                  ICoreWebView2Controller *created)
{
    if (closed) {
        if (created != nullptr)
            created->Close ();
        return S_OK;
    }
    if (FAILED (result) || created == nullptr) {
        fail ("create controller", result);
        return S_OK;
    }
    created->AddRef ();
    controller = created;
    result = controller->get_CoreWebView2 (&view);
    if (FAILED (result) || view == nullptr) {
        fail ("get WebView2", result);
        return S_OK;
    }
    resize ();

    ICoreWebView2Settings *settings = nullptr;
    if (SUCCEEDED (view->get_Settings (&settings))) {
        settings->put_IsWebMessageEnabled (TRUE);
        settings->put_AreDefaultScriptDialogsEnabled (FALSE);
        settings->put_IsStatusBarEnabled (FALSE);
        settings->put_AreDevToolsEnabled (developer_tools ? TRUE : FALSE);
        settings->put_AreDefaultContextMenusEnabled (
            developer_tools ? TRUE : FALSE);
        settings->put_AreHostObjectsAllowed (FALSE);
        settings->put_IsBuiltInErrorPageEnabled (FALSE);
        settings->Release ();
    }

    LPCWSTR filter = allow_internet ? L"https://webxdc.invalid/*" : L"*";
    result = view->AddWebResourceRequestedFilter (
        filter, COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    if (SUCCEEDED (result)) {
        auto *handler = callback<
            ICoreWebView2WebResourceRequestedEventHandler,
            ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *> (
                this, IID_ICoreWebView2WebResourceRequestedEventHandler,
                [this] (ICoreWebView2 *, auto *args) {
                    return resource_requested (args);
                });
        result = view->add_WebResourceRequested (handler, &resource_token);
        resource_registered = SUCCEEDED (result);
        handler->Release ();
    }
    if (SUCCEEDED (result)) {
        auto *handler = callback<
            ICoreWebView2WebMessageReceivedEventHandler,
            ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *> (
                this, IID_ICoreWebView2WebMessageReceivedEventHandler,
                [this] (ICoreWebView2 *, auto *args) {
                    LPWSTR message = nullptr;
                    if (!closed && SUCCEEDED (
                            args->TryGetWebMessageAsString (&message))) {
                        std::string text = wide_to_utf8 (message);
                        CoTaskMemFree (message);
                        if (!text.empty ())
                            message_cb (text.c_str (), user_data);
                    }
                    return S_OK;
                });
        result = view->add_WebMessageReceived (handler, &message_token);
        message_registered = SUCCEEDED (result);
        handler->Release ();
    }
    if (SUCCEEDED (result)) {
        auto *handler = callback<
            ICoreWebView2NavigationStartingEventHandler,
            ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *> (
                this, IID_ICoreWebView2NavigationStartingEventHandler,
                [] (ICoreWebView2 *, auto *args) {
                    LPWSTR uri = nullptr;
                    bool allowed = SUCCEEDED (args->get_Uri (&uri))
                        && is_app_uri (uri);
                    CoTaskMemFree (uri);
                    if (!allowed)
                        args->put_Cancel (TRUE);
                    return S_OK;
                });
        result = view->add_NavigationStarting (handler, &navigation_token);
        navigation_registered = SUCCEEDED (result);
        handler->Release ();
    }
    if (SUCCEEDED (result)) {
        auto *handler = callback<
            ICoreWebView2NewWindowRequestedEventHandler,
            ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *> (
                this, IID_ICoreWebView2NewWindowRequestedEventHandler,
                [] (ICoreWebView2 *, auto *args) {
                    return args->put_Handled (TRUE);
                });
        result = view->add_NewWindowRequested (handler, &new_window_token);
        new_window_registered = SUCCEEDED (result);
        handler->Release ();
    }
    if (SUCCEEDED (result)) {
        auto *handler = callback<
            ICoreWebView2PermissionRequestedEventHandler,
            ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *> (
                this, IID_ICoreWebView2PermissionRequestedEventHandler,
                [] (ICoreWebView2 *, auto *args) {
                    return args->put_State (
                        COREWEBVIEW2_PERMISSION_STATE_DENY);
                });
        result = view->add_PermissionRequested (handler, &permission_token);
        permission_registered = SUCCEEDED (result);
        handler->Release ();
    }
    if (SUCCEEDED (result)) {
        result = view->QueryInterface (IID_ICoreWebView2_4,
                                      reinterpret_cast<void **> (&view4));
    }
    if (SUCCEEDED (result)) {
        auto *handler = callback<
            ICoreWebView2DownloadStartingEventHandler,
            ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *> (
                this, IID_ICoreWebView2DownloadStartingEventHandler,
                [] (ICoreWebView2 *, auto *args) {
                    return args->put_Cancel (TRUE);
                });
        result = view4->add_DownloadStarting (handler, &download_token);
        download_registered = SUCCEEDED (result);
        handler->Release ();
    }
    if (FAILED (result)) {
        fail ("install security handlers", result);
        return S_OK;
    }

    auto *script_handler = callback<
        ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler,
        HRESULT, LPCWSTR> (
            this,
            IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler,
            [this] (HRESULT error, LPCWSTR) {
                if (FAILED (error))
                    fail ("install document-start policy", error);
                else if (!closed) {
                    script_ready = true;
                    if (load_requested)
                        navigate ();
                }
                return S_OK;
            });
    result = view->AddScriptToExecuteOnDocumentCreated (
        document_start_script (this).c_str (), script_handler);
    script_handler->Release ();
    if (FAILED (result))
        fail ("install document-start policy", result);
    return S_OK;
}

void
WebxdcWindow::navigate ()
{
    if (view == nullptr)
        return;
    HRESULT result = view->Navigate (kStartUri);
    if (FAILED (result)) {
        g_warning ("webxdc: could not navigate to app (HRESULT 0x%08lx)",
                   static_cast<unsigned long> (result));
        return;
    }
    if (developer_tools) {
        result = view->OpenDevToolsWindow ();
        if (FAILED (result))
            g_warning ("webxdc: could not open developer tools "
                       "(HRESULT 0x%08lx)",
                       static_cast<unsigned long> (result));
    }
}

static std::atomic<unsigned long> profile_serial { 0 };

HRESULT
WebxdcWindow::environment_created (HRESULT result,
                                   ICoreWebView2Environment *created)
{
    if (closed)
        return S_OK;
    if (FAILED (result) || created == nullptr) {
        fail ("find installed Edge WebView2 Runtime", result);
        return S_OK;
    }
    created->AddRef ();
    environment = created;
    ICoreWebView2Environment10 *environment10 = nullptr;
    result = created->QueryInterface (IID_ICoreWebView2Environment10,
                                     reinterpret_cast<void **> (&environment10));
    ICoreWebView2ControllerOptions *options = nullptr;
    if (SUCCEEDED (result))
        result = environment10->CreateCoreWebView2ControllerOptions (&options);
    if (SUCCEEDED (result)) {
        std::wstring profile = L"ParlaWebxdc" +
            std::to_wstring (++profile_serial);
        result = options->put_ProfileName (profile.c_str ());
        if (SUCCEEDED (result))
            result = options->put_IsInPrivateModeEnabled (TRUE);
    }
    auto *handler = callback<
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
        HRESULT, ICoreWebView2Controller *> (
            this,
            IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
            [this] (HRESULT error, ICoreWebView2Controller *value) {
                return controller_created (error, value);
            });
    if (SUCCEEDED (result)) {
        result = environment10->CreateCoreWebView2ControllerWithOptions (
            hwnd, options, handler);
    }
    handler->Release ();
    if (options != nullptr)
        options->Release ();
    if (environment10 != nullptr)
        environment10->Release ();
    if (FAILED (result))
        fail ("create InPrivate WebView2 controller", result);
    return S_OK;
}

void
WebxdcWindow::resize ()
{
    RECT bounds {};
    if (controller != nullptr && hwnd != nullptr && GetClientRect (hwnd, &bounds))
        controller->put_Bounds (bounds);
}

void
WebxdcWindow::fail (const char *stage, HRESULT error)
{
    g_warning ("webxdc: WebView2 %s failed (HRESULT 0x%08lx)",
               stage, static_cast<unsigned long> (error));
    if (hwnd != nullptr)
        PostMessageW (hwnd, WM_CLOSE, 0, 0);
}

void
WebxdcWindow::cleanup ()
{
    if (cleaned)
        return;
    cleaned = true;
    closed = true;
    auto pending = std::move (tasks);
    tasks.clear ();
    for (auto *task : pending)
        finish_request (task, nullptr, 0, "text/plain", 404);
    if (view != nullptr) {
        if (resource_registered) view->remove_WebResourceRequested (resource_token);
        if (message_registered) view->remove_WebMessageReceived (message_token);
        if (navigation_registered) view->remove_NavigationStarting (navigation_token);
        if (new_window_registered) view->remove_NewWindowRequested (new_window_token);
        if (permission_registered) view->remove_PermissionRequested (permission_token);
        if (download_registered && view4 != nullptr)
            view4->remove_DownloadStarting (download_token);
    }
    if (controller != nullptr)
        controller->Close ();
    if (view4 != nullptr) { view4->Release (); view4 = nullptr; }
    if (view != nullptr) { view->Release (); view = nullptr; }
    if (controller != nullptr) { controller->Release (); controller = nullptr; }
    if (environment != nullptr) { environment->Release (); environment = nullptr; }
}

static gboolean
closed_idle (gpointer data)
{
    auto *window = static_cast<WebxdcWindow *> (data);
    if (window->closed_cb != nullptr)
        window->closed_cb (window->user_data);
    window_unref (window);
    return G_SOURCE_REMOVE;
}

void
WebxdcWindow::notify_closed ()
{
    if (closed_notified)
        return;
    closed_notified = true;
    window_ref (this);
    if (g_idle_add (closed_idle, this) == 0)
        window_unref (this);
}

WebxdcWindow::~WebxdcWindow ()
{
    cleanup ();
    if (loader != nullptr)
        FreeLibrary (loader);
    if (co_initialized)
        CoUninitialize ();
}

static INIT_ONCE window_class_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK
register_window_class (PINIT_ONCE, PVOID, PVOID *)
{
    WNDCLASSEXW klass {};
    klass.cbSize = sizeof (klass);
    klass.lpfnWndProc = window_proc;
    klass.hInstance = GetModuleHandleW (nullptr);
    klass.hIcon = static_cast<HICON> (LoadImageW (
        klass.hInstance, MAKEINTRESOURCEW (1), IMAGE_ICON, 0, 0,
        LR_DEFAULTSIZE | LR_SHARED));
    klass.hCursor = LoadCursorW (nullptr, MAKEINTRESOURCEW (32512));
    klass.hbrBackground = reinterpret_cast<HBRUSH> (COLOR_WINDOW + 1);
    klass.lpszClassName = kWindowClass;
    return RegisterClassExW (&klass) != 0;
}

static LRESULT CALLBACK
window_proc (HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    auto *window = reinterpret_cast<WebxdcWindow *> (
        GetWindowLongPtrW (hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        auto *create = reinterpret_cast<CREATESTRUCTW *> (lparam);
        window = static_cast<WebxdcWindow *> (create->lpCreateParams);
        window->hwnd = hwnd;
        SetWindowLongPtrW (hwnd, GWLP_USERDATA,
                           reinterpret_cast<LONG_PTR> (window));
    }
    switch (message) {
    case WM_SIZE:
        if (window != nullptr) window->resize ();
        return 0;
    case WM_CLOSE:
        DestroyWindow (hwnd);
        return 0;
    case WM_NCDESTROY:
        if (window != nullptr) {
            SetWindowLongPtrW (hwnd, GWLP_USERDATA, 0);
            window->hwnd = nullptr;
            window->cleanup ();
            window->notify_closed ();
        }
        break;
    default:
        break;
    }
    return DefWindowProcW (hwnd, message, wparam, lparam);
}

using CreateEnvironmentFn = HRESULT (STDAPICALLTYPE *) (
    PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

extern "C" gpointer
parla_webxdc_win_open (const char *title, ParlaWebxdcWinBlobFn blob,
                       ParlaWebxdcWinMsgFn message,
                       ParlaWebxdcWinClosedFn closed,
                       gboolean allow_internet, gboolean allow_wasm,
                       gboolean allow_webgl, gboolean developer_tools,
                       gpointer user_data)
{
    auto *window = new WebxdcWindow ();
    window->blob_cb = blob;
    window->message_cb = message;
    window->closed_cb = closed;
    window->user_data = user_data;
    window->allow_internet = allow_internet;
    window->allow_wasm = allow_wasm;
    window->allow_webgl = allow_webgl;
    window->developer_tools = developer_tools;

    HRESULT result = CoInitializeEx (nullptr, COINIT_APARTMENTTHREADED);
    window->co_initialized = SUCCEEDED (result);
    if (FAILED (result)) {
        window->fail ("initialize the UI COM apartment", result);
        window->notify_closed ();
        return window;
    }
    InitOnceExecuteOnce (&window_class_once, register_window_class,
                         nullptr, nullptr);
    window->hwnd = CreateWindowExW (
        0, kWindowClass, utf8_to_wide (title).c_str (),
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 440, 680,
        nullptr, nullptr, GetModuleHandleW (nullptr), window);
    if (window->hwnd == nullptr) {
        window->fail ("create native window",
            HRESULT_FROM_WIN32 (GetLastError ()));
        window->notify_closed ();
        return window;
    }
    window->loader = LoadLibraryExW (
        L"WebView2Loader.dll", nullptr,
        LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    FARPROC symbol = window->loader != nullptr ? GetProcAddress (
        window->loader, "CreateCoreWebView2EnvironmentWithOptions") : nullptr;
    CreateEnvironmentFn create_environment = nullptr;
    static_assert (sizeof (create_environment) == sizeof (symbol));
    std::memcpy (&create_environment, &symbol, sizeof (create_environment));
    if (create_environment == nullptr) {
        window->fail ("load WebView2Loader.dll",
            HRESULT_FROM_WIN32 (GetLastError ()));
        return window;
    }

    unsigned policy = (allow_internet ? 1U : 0U) | (allow_webgl ? 2U : 0U);
    gchar *name = g_strdup_printf ("webview2-%u", policy);
    gchar *folder = g_build_filename (g_get_user_cache_dir (), "parla",
                                      name, nullptr);
    g_free (name);
    g_mkdir_with_parents (folder, 0700);
    window->user_data_folder = utf8_to_wide (folder);
    g_free (folder);

    std::wstring arguments;
    if (!allow_internet)
        arguments = L"--proxy-server=socks5://127.0.0.1:1 --disable-background-networking ";
    if (!allow_webgl)
        arguments += L"--disable-webgl --disable-gpu";
    auto *options = new EnvironmentOptions (std::move (arguments));
    auto *handler = callback<
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
        HRESULT, ICoreWebView2Environment *> (
            window,
            IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
            [window] (HRESULT error, ICoreWebView2Environment *value) {
                return window->environment_created (error, value);
            });
    result = create_environment (
        nullptr, window->user_data_folder.c_str (), options, handler);
    handler->Release ();
    options->Release ();
    if (FAILED (result))
        window->fail ("start installed Edge WebView2 Runtime", result);
    return window;
}

extern "C" void
parla_webxdc_win_load (gpointer handle, const char *)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window == nullptr || window->closed)
        return;
    window->load_requested = true;
    if (window->script_ready && window->view != nullptr)
        window->navigate ();
}

extern "C" void
parla_webxdc_win_finish_task (gpointer handle, gpointer task_ptr,
                              const guint8 *data, gint data_length,
                              const char *mime)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    auto *task = static_cast<RequestTask *> (task_ptr);
    if (window == nullptr || task == nullptr)
        return;
    auto found = window->tasks.find (task);
    if (found == window->tasks.end ())
        return;
    window->tasks.erase (found);
    finish_request (task, data, std::max (data_length, 0), mime, 200);
}

extern "C" void
parla_webxdc_win_fail_task (gpointer handle, gpointer task_ptr)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    auto *task = static_cast<RequestTask *> (task_ptr);
    if (window == nullptr || task == nullptr)
        return;
    auto found = window->tasks.find (task);
    if (found == window->tasks.end ())
        return;
    window->tasks.erase (found);
    finish_request (task, nullptr, 0, "text/plain", 404);
}

extern "C" void
parla_webxdc_win_eval_js (gpointer handle, const char *javascript)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window != nullptr && !window->closed && window->view != nullptr)
        window->view->ExecuteScript (
            utf8_to_wide (javascript).c_str (), nullptr);
}

extern "C" void
parla_webxdc_win_set_title (gpointer handle, const char *title)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window != nullptr && window->hwnd != nullptr)
        SetWindowTextW (window->hwnd, utf8_to_wide (title).c_str ());
}

extern "C" void
parla_webxdc_win_present (gpointer handle)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window == nullptr || window->hwnd == nullptr)
        return;
    ShowWindow (window->hwnd, IsIconic (window->hwnd) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow (window->hwnd);
}

extern "C" void
parla_webxdc_win_minimize (gpointer handle)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window != nullptr && window->hwnd != nullptr)
        ShowWindow (window->hwnd,
            IsIconic (window->hwnd) ? SW_RESTORE : SW_MINIMIZE);
}

extern "C" void
parla_webxdc_win_set_visible (gpointer handle, gboolean visible)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window != nullptr && window->hwnd != nullptr)
        ShowWindow (window->hwnd, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
}

extern "C" void
parla_webxdc_win_close (gpointer handle)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window != nullptr && window->hwnd != nullptr)
        PostMessageW (window->hwnd, WM_CLOSE, 0, 0);
}

extern "C" void
parla_webxdc_win_free (gpointer handle)
{
    auto *window = static_cast<WebxdcWindow *> (handle);
    if (window != nullptr) {
        window->cleanup ();
        window_unref (window);
    }
}

#endif /* _WIN32 */
