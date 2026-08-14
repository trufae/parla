#include "platform.h"

#if defined(__APPLE__)

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <gtk/gtk.h>
#include <gdk/macos/gdkmacos.h>


static char parla_drop_handler_key;
static char parla_drop_subclass_key;

@interface ParlaMacosFileDropHandler : NSObject {
	ParlaMacosFileDropCallback callback;
	gpointer user_data;
}
- (id)initWithCallback:(ParlaMacosFileDropCallback)cb userData:(gpointer)data;
- (BOOL)canAcceptDraggingInfo:(id<NSDraggingInfo>)sender;
- (BOOL)performDraggingInfo:(id<NSDraggingInfo>)sender;
@end

static void
parla_add_unique_path (NSMutableArray<NSString *> *paths, NSString *path)
{
	if (path == nil || [path length] == 0) {
		return;
	}
	if (![paths containsObject:path]) {
		[paths addObject:path];
	}
}

static void
parla_add_file_url_string (NSMutableArray<NSString *> *paths, NSString *url_string)
{
	if (url_string == nil || [url_string length] == 0) {
		return;
	}

	NSURL *url = [NSURL URLWithString:url_string];
	if (url != nil && [url isFileURL]) {
		parla_add_unique_path (paths, [url path]);
	}
}

static NSArray<NSString *> *
parla_paths_from_pasteboard (NSPasteboard *pasteboard)
{
	NSMutableArray<NSString *> *paths = [NSMutableArray array];
	if (pasteboard == nil) {
		return paths;
	}

	NSDictionary *options = @{
		NSPasteboardURLReadingFileURLsOnlyKey: @YES
	};
	NSArray *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
	                                          options:options];
	for (NSURL *url in urls) {
		if ([url isFileURL]) {
			parla_add_unique_path (paths, [url path]);
		}
	}

	NSString *file_url = [pasteboard stringForType:NSPasteboardTypeFileURL];
	parla_add_file_url_string (paths, file_url);

	G_GNUC_BEGIN_IGNORE_DEPRECATIONS
	id files = [pasteboard propertyListForType:NSFilenamesPboardType];
	G_GNUC_END_IGNORE_DEPRECATIONS
	if ([files isKindOfClass:[NSArray class]]) {
		for (id file in (NSArray *) files) {
			if ([file isKindOfClass:[NSString class]]) {
				parla_add_unique_path (paths, file);
			}
		}
	} else if ([files isKindOfClass:[NSString class]]) {
		parla_add_unique_path (paths, files);
	}

	return paths;
}

static BOOL
parla_pasteboard_has_file_url (NSPasteboard *pasteboard)
{
	if (pasteboard == nil) {
		return NO;
	}

	NSDictionary *options = @{
		NSPasteboardURLReadingFileURLsOnlyKey: @YES
	};
	if ([pasteboard canReadObjectForClasses:@[[NSURL class]]
	                              options:options]) {
		return YES;
	}

	G_GNUC_BEGIN_IGNORE_DEPRECATIONS
	NSArray *types = @[
		NSPasteboardTypeFileURL,
		@"public.file-url",
		NSFilenamesPboardType,
	];
	G_GNUC_END_IGNORE_DEPRECATIONS
	return [pasteboard availableTypeFromArray:types] != nil;
}

@implementation ParlaMacosFileDropHandler

- (id)initWithCallback:(ParlaMacosFileDropCallback)cb userData:(gpointer)data
{
	self = [super init];
	if (self != nil) {
		callback = cb;
		user_data = data;
	}
	return self;
}

- (void)dealloc
{
	[super dealloc];
}

- (BOOL)canAcceptDraggingInfo:(id<NSDraggingInfo>)sender
{
	return parla_pasteboard_has_file_url ([sender draggingPasteboard]);
}

- (BOOL)performDraggingInfo:(id<NSDraggingInfo>)sender
{
	NSString *path = [parla_paths_from_pasteboard ([sender draggingPasteboard]) firstObject];
	if (path == nil || callback == NULL) {
		return NO;
	}

	NSView *view = [[sender draggingDestinationWindow] contentView];
	NSPoint point = [sender draggingLocation];
	if (view != nil) {
		point = [view convertPoint:point fromView:nil];
		NSRect bounds = [view bounds];
		point.x -= NSMinX (bounds);
		point.y = [view isFlipped]
			? point.y - NSMinY (bounds)
			: NSMaxY (bounds) - point.y;
	}

	callback ([path fileSystemRepresentation], point.x, point.y, user_data);
	return YES;
}

@end

static ParlaMacosFileDropHandler *
parla_handler_for_view (id view)
{
	return objc_getAssociatedObject (view, &parla_drop_handler_key);
}

static NSDragOperation
parla_call_super_drag_operation (id self, SEL selector, id<NSDraggingInfo> sender)
{
	Class superclass = class_getSuperclass (object_getClass (self));
	if (superclass == Nil || class_getInstanceMethod (superclass, selector) == NULL) {
		return NSDragOperationNone;
	}

	struct objc_super super_info = {
		.receiver = self,
		.super_class = superclass,
	};
	typedef NSDragOperation (*MsgSendSuper)(struct objc_super *, SEL, id);
	return ((MsgSendSuper) objc_msgSendSuper) (&super_info, selector, sender);
}

static BOOL
parla_call_super_bool (id self, SEL selector, id<NSDraggingInfo> sender)
{
	Class superclass = class_getSuperclass (object_getClass (self));
	if (superclass == Nil || class_getInstanceMethod (superclass, selector) == NULL) {
		return NO;
	}

	struct objc_super super_info = {
		.receiver = self,
		.super_class = superclass,
	};
	typedef BOOL (*MsgSendSuper)(struct objc_super *, SEL, id);
	return ((MsgSendSuper) objc_msgSendSuper) (&super_info, selector, sender);
}

static NSDragOperation
parla_dragging_entered (id self, SEL selector, id<NSDraggingInfo> sender)
{
	ParlaMacosFileDropHandler *handler = parla_handler_for_view (self);
	if (handler != nil && [handler canAcceptDraggingInfo:sender]) {
		return NSDragOperationCopy;
	}
	return parla_call_super_drag_operation (self, selector, sender);
}

static NSDragOperation
parla_dragging_updated (id self, SEL selector, id<NSDraggingInfo> sender)
{
	ParlaMacosFileDropHandler *handler = parla_handler_for_view (self);
	if (handler != nil && [handler canAcceptDraggingInfo:sender]) {
		return NSDragOperationCopy;
	}
	return parla_call_super_drag_operation (self, selector, sender);
}

static BOOL
parla_prepare_for_drag_operation (id self, SEL selector, id<NSDraggingInfo> sender)
{
	ParlaMacosFileDropHandler *handler = parla_handler_for_view (self);
	if (handler != nil && [handler canAcceptDraggingInfo:sender]) {
		return YES;
	}
	return parla_call_super_bool (self, selector, sender);
}

static BOOL
parla_perform_drag_operation (id self, SEL selector, id<NSDraggingInfo> sender)
{
	ParlaMacosFileDropHandler *handler = parla_handler_for_view (self);
	if (handler != nil && [handler performDraggingInfo:sender]) {
		return YES;
	}
	return parla_call_super_bool (self, selector, sender);
}

static void
parla_install_drop_subclass (NSView *view)
{
	if (objc_getAssociatedObject (view, &parla_drop_subclass_key) != nil) {
		return;
	}

	Class original = object_getClass (view);
	char name[256];
	snprintf (name, sizeof (name), "ParlaFileDrop_%s_%p",
	          class_getName (original), view);

	Class subclass = objc_allocateClassPair (original, name, 0);
	if (subclass == Nil) {
		return;
	}

	class_addMethod (subclass, @selector (draggingEntered:),
	                 (IMP) parla_dragging_entered, "Q@:@");
	class_addMethod (subclass, @selector (draggingUpdated:),
	                 (IMP) parla_dragging_updated, "Q@:@");
	class_addMethod (subclass, @selector (prepareForDragOperation:),
	                 (IMP) parla_prepare_for_drag_operation, "c@:@");
	class_addMethod (subclass, @selector (performDragOperation:),
	                 (IMP) parla_perform_drag_operation, "c@:@");
	objc_registerClassPair (subclass);

	object_setClass (view, subclass);
	objc_setAssociatedObject (view, &parla_drop_subclass_key, @YES,
	                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void
parla_macos_install_file_drop_handler (GtkWidget                  *widget,
                                       ParlaMacosFileDropCallback  callback,
                                       gpointer                    user_data)
{
	if (!GTK_IS_WIDGET (widget) || callback == NULL) {
		return;
	}

	GtkNative *native = gtk_widget_get_native (widget);
	if (native == NULL) {
		return;
	}

	GdkSurface *surface = gtk_native_get_surface (native);
	if (!GDK_IS_MACOS_SURFACE (surface)) {
		return;
	}

	NSWindow *window = (NSWindow *) gdk_macos_surface_get_native_window (
		GDK_MACOS_SURFACE (surface));
	NSView *view = [window contentView];
	if (view == nil) {
		return;
	}

	G_GNUC_BEGIN_IGNORE_DEPRECATIONS
	NSArray *types = @[
		NSPasteboardTypeFileURL,
		NSPasteboardTypeURL,
		@"public.file-url",
		@"public.url",
		@"public.item",
		NSFilenamesPboardType,
	];
	G_GNUC_END_IGNORE_DEPRECATIONS
	[view registerForDraggedTypes:types];
	[window registerForDraggedTypes:types];

	parla_install_drop_subclass (view);

	ParlaMacosFileDropHandler *handler =
		[[ParlaMacosFileDropHandler alloc] initWithCallback:callback
		                                           userData:user_data];
	objc_setAssociatedObject (view, &parla_drop_handler_key, handler,
	                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[handler release];
}

#endif
