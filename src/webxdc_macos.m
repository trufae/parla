#include "webxdc_macos.h"

#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

/*
 * Webxdc window on macOS: NSWindow + WKWebView (system WebKit.framework).
 * Compiled without ARC like the other .m shims, so retains/releases are
 * explicit. Everything WebKit tells us is re-queued with g_idle_add and
 * handled by webxdc.vala in a normal GTK main-loop iteration.
 *
 * Network policy is enforced by the engine itself. The safe default uses a
 * WKContentRuleList which blocks every load and then exempts the webxdc:
 * scheme, covering subresources (fetch/img/script) a navigation delegate
 * would never see. If that rule list fails to compile the web view is never
 * created — fail closed. An explicit unsafe setting omits the list. The
 * navigation delegate always refuses top-level navigation outside webxdc:,
 * and window.open is denied by returning nil from
 * createWebViewWithConfiguration.
 */

static NSString *const kParlaWebxdcBlockRules =
    @"[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}},"
     "{\"trigger\":{\"url-filter\":\"^webxdc://.*\"},"
     "\"action\":{\"type\":\"ignore-previous-rules\"}}]";

@interface ParlaWebxdcController : NSObject <WKURLSchemeHandler,
    WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate,
    NSWindowDelegate>
{
@public
	NSWindow *window;
	WKWebView *webview;
	/* live: waiting for Vala's answer; stopped: cancelled by WebKit but
	 * still retained so the task pointer Vala holds stays valid until
	 * its answer arrives. */
	NSMutableSet *live_tasks;
	NSMutableSet *stopped_tasks;
	NSString *pending_uri;
	BOOL closed;
	BOOL allow_internet;
	BOOL allow_wasm;
	BOOL allow_webgl;
	BOOL developer_tools;
	ParlaWebxdcBlobFn blob_cb;
	ParlaWebxdcMsgFn message_cb;
	ParlaWebxdcClosedFn closed_cb;
	gpointer user_data;
}
@end

typedef struct {
	ParlaWebxdcBlobFn cb;
	gpointer user_data;
	char *path;
	gpointer task;
} BlobIdleData;

static gboolean
idle_blob (gpointer data)
{
	BlobIdleData *d = data;
	d->cb (d->path, d->task, d->user_data);
	g_free (d->path);
	g_free (d);
	return G_SOURCE_REMOVE;
}

typedef struct {
	ParlaWebxdcMsgFn cb;
	gpointer user_data;
	char *json;
} MsgIdleData;

static gboolean
idle_message (gpointer data)
{
	MsgIdleData *d = data;
	d->cb (d->json, d->user_data);
	g_free (d->json);
	g_free (d);
	return G_SOURCE_REMOVE;
}

typedef struct {
	ParlaWebxdcClosedFn cb;
	gpointer user_data;
} ClosedIdleData;

static gboolean
idle_closed (gpointer data)
{
	ClosedIdleData *d = data;
	d->cb (d->user_data);
	g_free (d);
	return G_SOURCE_REMOVE;
}

typedef struct {
	ParlaWebxdcController *controller;   /* retained */
	WKContentRuleList *rules;            /* retained */
} RulesIdleData;

static void setup_webview (ParlaWebxdcController *c,
                           WKContentRuleList *rules);

/* The rule-list store invokes its completion on the GCD main queue; hop
 * over to the GLib loop so the web view is built in the same context as
 * every other callback, whatever pumps the process. */
static gboolean
idle_rules_ready (gpointer data)
{
	RulesIdleData *d = data;
	if (!d->controller->closed)
		setup_webview (d->controller, d->rules);
	[d->rules release];
	[d->controller release];
	g_free (d);
	return G_SOURCE_REMOVE;
}

static void
setup_webview (ParlaWebxdcController *c, WKContentRuleList *rules)
{
	WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
	[cfg setURLSchemeHandler:c forURLScheme:@"webxdc"];
	[cfg setWebsiteDataStore:[WKWebsiteDataStore nonPersistentDataStore]];
	[[cfg userContentController] addScriptMessageHandler:c name:@"webxdc"];
	if (rules)
		[[cfg userContentController] addContentRuleList:rules];
	if (!c->allow_webgl) {
		/* WKWebView has no public WebGL-disable preference. Install this at
		 * document start in every frame as the strongest public best-effort
		 * restriction; worker-created contexts remain an Apple API gap. */
		NSString *source =
		    @"(()=>{const block=p=>{if(!p||!p.getContext)return;"
		     "const old=p.getContext;Object.defineProperty(p,'getContext',{"
		     "configurable:false,writable:false,value:function(t){"
		     "t=String(t).toLowerCase();return t==='webgl'||t==='webgl2'"
		     "||t==='experimental-webgl'?null:old.apply(this,arguments)}})};"
		     "block(window.HTMLCanvasElement&&HTMLCanvasElement.prototype);"
		     "block(window.OffscreenCanvas&&OffscreenCanvas.prototype)})();";
		WKUserScript *script = [[WKUserScript alloc]
		    initWithSource:source
		    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
		    forMainFrameOnly:NO];
		[[cfg userContentController] addUserScript:script];
		[script release];
	}
	if (!c->allow_internet) {
		/* Content rules cover URL-backed loads, but WebRTC can create direct
		 * transports. WKWebView has no public WebRTC setting, so remove those
		 * constructors at document start as defense in depth. */
		NSString *source =
		    @"(()=>{for(const n of ['RTCPeerConnection',"
		     "'webkitRTCPeerConnection','WebTransport']){try{"
		     "Object.defineProperty(window,n,{value:undefined,writable:false,"
		     "configurable:false})}catch(e){}}})();";
		WKUserScript *script = [[WKUserScript alloc]
		    initWithSource:source
		    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
		    forMainFrameOnly:NO];
		[[cfg userContentController] addUserScript:script];
		[script release];
	}

	c->webview = [[WKWebView alloc]
	    initWithFrame:[[c->window contentView] bounds]
	    configuration:cfg];
	[cfg release];
	if (@available(macOS 13.3, *))
		[c->webview setInspectable:c->developer_tools];
	[c->webview setNavigationDelegate:c];
	[c->webview setUIDelegate:c];
	[c->webview setAutoresizingMask:
	    NSViewWidthSizable | NSViewHeightSizable];
	[[c->window contentView] addSubview:c->webview];

	if (c->pending_uri) {
		NSURL *url = [NSURL URLWithString:c->pending_uri];
		if (url)
			[c->webview loadRequest:[NSURLRequest requestWithURL:url]];
		[c->pending_uri release];
		c->pending_uri = nil;
	}
}

@implementation ParlaWebxdcController

/* WKWebView's public inspectable property only publishes the page to
 * Safari. WebKit's own MiniBrowser uses this private inspector object to
 * host Web Inspector in a separate application window. Resolve both
 * selectors dynamically so a WebKit version which removes the SPI merely
 * loses the optional inspector instead of preventing Webxdc from starting. */
- (void)openDeveloperTools
{
	if (!developer_tools || !webview)
		return;
	SEL inspectorSelector = NSSelectorFromString (@"_inspector");
	SEL showSelector = NSSelectorFromString (@"show");
	if (![webview respondsToSelector:inspectorSelector]) {
		g_warning ("webxdc: this WebKit has no in-process inspector");
		return;
	}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
	id inspector = [webview performSelector:inspectorSelector];
	if ([inspector respondsToSelector:showSelector])
		[inspector performSelector:showSelector];
	else
		g_warning ("webxdc: this WebKit inspector cannot be shown");
#pragma clang diagnostic pop
}

- (void)webView:(WKWebView *)wv
    startURLSchemeTask:(id<WKURLSchemeTask>)task
{
	(void)wv;
	if (closed)
		return;
	[live_tasks addObject:task];
	NSString *path = [[[task request] URL] path];
	BlobIdleData *d = g_new0 (BlobIdleData, 1);
	d->cb = blob_cb;
	d->user_data = user_data;
	d->path = g_strdup (path ? [path UTF8String] : "/index.html");
	d->task = (gpointer)task;
	g_idle_add (idle_blob, d);
}

- (void)webView:(WKWebView *)wv
    stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
	(void)wv;
	if ([live_tasks containsObject:task]) {
		[stopped_tasks addObject:task];
		[live_tasks removeObject:task];
	}
}

- (void)userContentController:(WKUserContentController *)ucc
    didReceiveScriptMessage:(WKScriptMessage *)message
{
	(void)ucc;
	if (closed || ![[message body] isKindOfClass:[NSString class]])
		return;
	MsgIdleData *d = g_new0 (MsgIdleData, 1);
	d->cb = message_cb;
	d->user_data = user_data;
	d->json = g_strdup ([(NSString *)[message body] UTF8String]);
	g_idle_add (idle_message, d);
}

- (void)webView:(WKWebView *)wv
    decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
	(void)wv;
	NSString *scheme = [[[[action request] URL] scheme] lowercaseString];
	decisionHandler ([scheme isEqualToString:@"webxdc"]
	    ? WKNavigationActionPolicyAllow
	    : WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)wv
    didFinishNavigation:(WKNavigation *)navigation
{
	(void)wv; (void)navigation;
	[self openDeveloperTools];
}

- (WKWebView *)webView:(WKWebView *)wv
    createWebViewWithConfiguration:(WKWebViewConfiguration *)cfg
    forNavigationAction:(WKNavigationAction *)action
    windowFeatures:(WKWindowFeatures *)features
{
	(void)wv; (void)cfg; (void)action; (void)features;
	return nil;
}

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	if (closed)
		return;
	closed = YES;
	if (webview) {
		[[[webview configuration] userContentController]
		    removeScriptMessageHandlerForName:@"webxdc"];
		[webview setNavigationDelegate:nil];
		[webview setUIDelegate:nil];
		[webview removeFromSuperview];
	}
	ClosedIdleData *d = g_new0 (ClosedIdleData, 1);
	d->cb = closed_cb;
	d->user_data = user_data;
	g_idle_add (idle_closed, d);
}

@end

gpointer
parla_webxdc_open (const char *title, ParlaWebxdcBlobFn blob,
                   ParlaWebxdcMsgFn message, ParlaWebxdcClosedFn closed,
                   gboolean allow_internet, gboolean allow_wasm,
                   gboolean allow_webgl,
                   gboolean developer_tools,
                   gpointer user_data)
{
	ParlaWebxdcController *c = [[ParlaWebxdcController alloc] init];
	c->blob_cb = blob;
	c->message_cb = message;
	c->closed_cb = closed;
	c->user_data = user_data;
	c->allow_internet = allow_internet;
	c->allow_wasm = allow_wasm;
	c->allow_webgl = allow_webgl;
	c->developer_tools = developer_tools;
	c->live_tasks = [[NSMutableSet alloc] init];
	c->stopped_tasks = [[NSMutableSet alloc] init];

	c->window = [[NSWindow alloc]
	    initWithContentRect:NSMakeRect (0, 0, 420, 640)
	    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
	        | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	    backing:NSBackingStoreBuffered
	    defer:NO];
	[c->window setReleasedWhenClosed:NO];
	[c->window setTitle:[NSString stringWithUTF8String:title]];
	[c->window setDelegate:c];
	[c->window center];

	if (allow_internet) {
		setup_webview (c, nil);
		return c;
	}

	[[WKContentRuleListStore defaultStore]
	    compileContentRuleListForIdentifier:@"parla-webxdc-block-net"
	    encodedContentRuleList:kParlaWebxdcBlockRules
	    completionHandler:^(WKContentRuleList *rules, NSError *error) {
		if (!rules || error) {
			g_warning ("webxdc: content rule list failed: %s",
			    error ? [[error localizedDescription] UTF8String]
			          : "no list");
			return;
		}
		RulesIdleData *d = g_new0 (RulesIdleData, 1);
		d->controller = [c retain];
		d->rules = [rules retain];
		g_idle_add (idle_rules_ready, d);
	}];
	return c;
}

void
parla_webxdc_load (gpointer handle, const char *uri)
{
	ParlaWebxdcController *c = handle;
	if (c->webview) {
		NSURL *url = [NSURL URLWithString:
		    [NSString stringWithUTF8String:uri]];
		if (url)
			[c->webview loadRequest:[NSURLRequest requestWithURL:url]];
	} else {
		[c->pending_uri release];
		c->pending_uri = [[NSString alloc] initWithUTF8String:uri];
	}
}

void
parla_webxdc_finish_task (gpointer handle, gpointer task_ptr,
                          const guint8 *data, gint data_length,
                          const char *mime)
{
	ParlaWebxdcController *c = handle;
	id<WKURLSchemeTask> task = (id<WKURLSchemeTask>)task_ptr;
	if ([c->stopped_tasks containsObject:task]) {
		[c->stopped_tasks removeObject:task];
		return;
	}
	if (![c->live_tasks containsObject:task])
		return;
	NSURL *url = [[task request] URL];
	NSString *mime_string = [NSString stringWithUTF8String:mime];
	NSURLResponse *resp;
	if (!c->allow_wasm
	    && [mime_string caseInsensitiveCompare:@"text/html"]
	        == NSOrderedSame) {
		/* CSP is meaningful on the document response. Keep an HTTP-style
		 * response for its headers, but provide the required resource size. */
		NSMutableDictionary *headers =
		    [NSMutableDictionary dictionaryWithObjectsAndKeys:
		        mime_string, @"Content-Type",
		        [NSString stringWithFormat:@"%d", data_length],
		        @"Content-Length", nil];
		headers[@"Content-Security-Policy"] =
		    @"script-src 'self' 'unsafe-inline' data: blob: http: https:";
		resp = [[NSHTTPURLResponse alloc]
		    initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
		    headerFields:headers];
	} else {
		/* WKURLSchemeTask serves a non-HTTP URL. NSURLResponse supplies
		 * WebKit with both the MIME type and expected byte count. */
		resp = [[NSURLResponse alloc]
		    initWithURL:url MIMEType:mime_string
		    expectedContentLength:(NSInteger)data_length
		    textEncodingName:nil];
	}
	@try {
		[task didReceiveResponse:resp];
		[task didReceiveData:[NSData dataWithBytes:data
		                             length:(NSUInteger)data_length]];
		[task didFinish];
	} @catch (NSException *e) {
		/* Task raced its own cancellation inside WebKit; drop it. */
	}
	[resp release];
	[c->live_tasks removeObject:task];
}

void
parla_webxdc_fail_task (gpointer handle, gpointer task_ptr)
{
	ParlaWebxdcController *c = handle;
	id<WKURLSchemeTask> task = (id<WKURLSchemeTask>)task_ptr;
	if ([c->stopped_tasks containsObject:task]) {
		[c->stopped_tasks removeObject:task];
		return;
	}
	if (![c->live_tasks containsObject:task])
		return;
	@try {
		[task didFailWithError:
		    [NSError errorWithDomain:NSURLErrorDomain
		                        code:NSURLErrorFileDoesNotExist
		                    userInfo:nil]];
	} @catch (NSException *e) {
	}
	[c->live_tasks removeObject:task];
}

void
parla_webxdc_eval_js (gpointer handle, const char *js)
{
	ParlaWebxdcController *c = handle;
	if (c->webview)
		[c->webview evaluateJavaScript:
		    [NSString stringWithUTF8String:js] completionHandler:nil];
}

void
parla_webxdc_set_title (gpointer handle, const char *title)
{
	ParlaWebxdcController *c = handle;
	[c->window setTitle:[NSString stringWithUTF8String:title]];
}

void
parla_webxdc_present (gpointer handle)
{
	ParlaWebxdcController *c = handle;
	[c->window makeKeyAndOrderFront:nil];
}

void
parla_webxdc_minimize (gpointer handle)
{
	ParlaWebxdcController *c = handle;
	if ([c->window isMiniaturized])
		[c->window deminiaturize:nil];
	else
		[c->window miniaturize:nil];
}

void
parla_webxdc_set_visible (gpointer handle, gboolean visible)
{
	ParlaWebxdcController *c = handle;
	if (visible)
		[c->window orderFront:nil];   /* no focus steal */
	else
		[c->window orderOut:nil];
}

void
parla_webxdc_close (gpointer handle)
{
	ParlaWebxdcController *c = handle;
	[c->window close];   /* triggers windowWillClose -> closed callback */
}

void
parla_webxdc_free (gpointer handle)
{
	ParlaWebxdcController *c = handle;
	[c->window setDelegate:nil];
	[c->webview release];
	c->webview = nil;
	[c->window release];
	c->window = nil;
	[c->live_tasks release];
	[c->stopped_tasks release];
	[c->pending_uri release];
	[c release];
}

#endif /* __APPLE__ */
