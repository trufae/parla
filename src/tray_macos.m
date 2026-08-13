#include "tray_macos.h"

#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include "tray_macos_icon.h"

/*
 * NSStatusItem-based tray for macOS. The item carries a template image
 * (black + alpha, embedded below as PNG bytes) so AppKit recolors it for
 * the light/dark menu bar and the highlighted state, and a plain NSMenu
 * mirroring the SNI dbusmenu on GNOME: Show/Hide, Notifications, Quit.
 *
 * AppKit delivers menu actions on the main thread but inside the
 * menu-tracking run loop; every callback is re-queued with g_idle_add so
 * the Vala handlers run in a normal GTK main-loop iteration instead.
 */

@interface ParlaTrayController : NSObject
- (void)toggleWindow:(id)sender;
- (void)toggleNotifications:(id)sender;
- (void)quit:(id)sender;
@end

static struct {
	ParlaMacosTrayAction window_toggle;
	ParlaMacosTrayAction window_show;
	ParlaMacosTrayAction quit;
	ParlaMacosTrayToggle notifications_toggle;
	gpointer user_data;

	ParlaTrayController *controller;
	NSStatusItem *item;
	NSMenuItem *toggle_menu_item;
	NSMenuItem *notifications_menu_item;
	BOOL window_visible;
	BOOL notifications_on;
} tray;

static gboolean
idle_window_toggle (gpointer data)
{
	if (tray.window_toggle != NULL) {
		tray.window_toggle (tray.user_data);
	}
	return G_SOURCE_REMOVE;
}

static gboolean
idle_window_show (gpointer data)
{
	if (tray.window_show != NULL) {
		tray.window_show (tray.user_data);
	}
	return G_SOURCE_REMOVE;
}

static gboolean
idle_quit (gpointer data)
{
	if (tray.quit != NULL) {
		tray.quit (tray.user_data);
	}
	return G_SOURCE_REMOVE;
}

static gboolean
idle_notifications_toggle (gpointer data)
{
	if (tray.notifications_toggle != NULL) {
		tray.notifications_toggle (GPOINTER_TO_INT (data), tray.user_data);
	}
	return G_SOURCE_REMOVE;
}

@implementation ParlaTrayController

- (void)toggleWindow:(id)sender
{
	g_idle_add (idle_window_toggle, NULL);
}

- (void)toggleNotifications:(id)sender
{
	g_idle_add (idle_notifications_toggle,
	            GINT_TO_POINTER (tray.notifications_on ? 0 : 1));
}

- (void)quit:(id)sender
{
	g_idle_add (idle_quit, NULL);
}

@end

/*
 * Re-launching the bundle (Dock, Launchpad, Spotlight) while the process
 * is alive sends a reopen event to the running instance instead of
 * starting a new one. With the window hidden in the tray that event is
 * the only OS-level way back, so a dynamic subclass of GTK's application
 * delegate — the same pattern platform_macos.m uses for file drops —
 * turns it into a window_show callback. With the window visible the
 * event falls through to the original delegate.
 */

static char parla_tray_reopen_subclass_key;

static BOOL
parla_tray_call_super_reopen (id self, SEL selector, NSApplication *app,
                              BOOL has_visible)
{
	Class superclass = class_getSuperclass (object_getClass (self));
	if (superclass == Nil ||
	    class_getInstanceMethod (superclass, selector) == NULL) {
		return YES;
	}

	struct objc_super super_info = {
		.receiver = self,
		.super_class = superclass,
	};
	typedef BOOL (*MsgSendSuper)(struct objc_super *, SEL, NSApplication *, BOOL);
	return ((MsgSendSuper) objc_msgSendSuper) (&super_info, selector, app,
	                                           has_visible);
}

static BOOL
parla_tray_should_handle_reopen (id self, SEL selector, NSApplication *app,
                                 BOOL has_visible)
{
	if (!tray.window_visible) {
		g_idle_add (idle_window_show, NULL);
		return NO;
	}
	return parla_tray_call_super_reopen (self, selector, app, has_visible);
}

static void
parla_tray_install_reopen_handler (void)
{
	id delegate = [NSApp delegate];
	if (delegate == nil ||
	    objc_getAssociatedObject (delegate, &parla_tray_reopen_subclass_key) != nil) {
		return;
	}

	Class original = object_getClass (delegate);
	char name[256];
	snprintf (name, sizeof (name), "ParlaTrayReopen_%s",
	          class_getName (original));

	Class subclass = objc_getClass (name);
	if (subclass == Nil) {
		subclass = objc_allocateClassPair (original, name, 0);
		if (subclass == Nil) {
			return;
		}
		class_addMethod (subclass,
		                 @selector (applicationShouldHandleReopen:hasVisibleWindows:),
		                 (IMP) parla_tray_should_handle_reopen, "c@:@c");
		objc_registerClassPair (subclass);
	}

	object_setClass (delegate, subclass);
	objc_setAssociatedObject (delegate, &parla_tray_reopen_subclass_key, @YES,
	                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSImage *
parla_tray_make_icon (void)
{
	NSData *base = [NSData dataWithBytesNoCopy:(void *) parla_tray_png_1x
	                                    length:parla_tray_png_1x_len
	                              freeWhenDone:NO];
	NSImage *icon = [[NSImage alloc] initWithData:base];
	if (icon == nil) {
		return nil;
	}

	NSData *retina = [NSData dataWithBytesNoCopy:(void *) parla_tray_png_2x
	                                      length:parla_tray_png_2x_len
	                                freeWhenDone:NO];
	NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:retina];
	if (rep != nil) {
		[rep setSize:NSMakeSize (18, 18)];
		[icon addRepresentation:rep];
	}

	[icon setSize:NSMakeSize (18, 18)];
	/* Template rendering is what makes the icon black-and-white and
	   correct in both menu-bar appearances. */
	[icon setTemplate:YES];
	return icon;
}

void
parla_macos_tray_init (ParlaMacosTrayAction window_toggle,
                       ParlaMacosTrayAction window_show,
                       ParlaMacosTrayAction quit,
                       ParlaMacosTrayToggle notifications_toggle,
                       gpointer             user_data)
{
	tray.window_toggle = window_toggle;
	tray.window_show = window_show;
	tray.quit = quit;
	tray.notifications_toggle = notifications_toggle;
	tray.user_data = user_data;
	tray.window_visible = YES;
	tray.notifications_on = YES;

	if (tray.controller == nil) {
		tray.controller = [ParlaTrayController new];
	}
	parla_tray_install_reopen_handler ();
}

static NSString *
parla_tray_toggle_title (void)
{
	return tray.window_visible ? @"Hide Parla" : @"Show Parla";
}

gboolean
parla_macos_tray_show (void)
{
	if (tray.item != nil) {
		return TRUE;
	}
	if (tray.controller == nil) {
		return FALSE; /* init not called */
	}

	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Parla"];
	[menu setAutoenablesItems:NO];

	tray.toggle_menu_item =
		[menu addItemWithTitle:parla_tray_toggle_title ()
		                action:@selector (toggleWindow:)
		         keyEquivalent:@""];
	[tray.toggle_menu_item setTarget:tray.controller];

	tray.notifications_menu_item =
		[menu addItemWithTitle:@"Notifications"
		                action:@selector (toggleNotifications:)
		         keyEquivalent:@""];
	[tray.notifications_menu_item setTarget:tray.controller];
	[tray.notifications_menu_item
		setState:tray.notifications_on ? NSControlStateValueOn
		                               : NSControlStateValueOff];

	[menu addItem:[NSMenuItem separatorItem]];

	NSMenuItem *quit_item = [menu addItemWithTitle:@"Quit Parla"
	                                        action:@selector (quit:)
	                                 keyEquivalent:@""];
	[quit_item setTarget:tray.controller];

	tray.item = [[[NSStatusBar systemStatusBar]
		statusItemWithLength:NSSquareStatusItemLength] retain];

	NSImage *icon = parla_tray_make_icon ();
	if (icon != nil) {
		[[tray.item button] setImage:icon];
		[icon release];
	} else {
		/* Never end up with an invisible-but-clickable item. */
		[[tray.item button] setTitle:@"Parla"];
	}
	[[tray.item button] setToolTip:@"Parla"];
	[tray.item setMenu:menu];
	[menu release];

	return TRUE;
}

void
parla_macos_tray_hide (void)
{
	if (tray.item == nil) {
		return;
	}
	[[NSStatusBar systemStatusBar] removeStatusItem:tray.item];
	[tray.item release];
	tray.item = nil;
	tray.toggle_menu_item = nil;
	tray.notifications_menu_item = nil;
}

void
parla_macos_tray_set_window_visible (gboolean visible)
{
	tray.window_visible = visible ? YES : NO;
	[tray.toggle_menu_item setTitle:parla_tray_toggle_title ()];
}

void
parla_macos_tray_set_notifications_enabled (gboolean enabled)
{
	tray.notifications_on = enabled ? YES : NO;
	[tray.notifications_menu_item
		setState:tray.notifications_on ? NSControlStateValueOn
		                               : NSControlStateValueOff];
}

#endif
