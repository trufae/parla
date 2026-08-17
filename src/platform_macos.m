#include "platform.h"

#if defined(__APPLE__)

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdint.h>
#include <gtk/gtk.h>
#include <gdk/macos/gdkmacos.h>


static char parla_drop_handler_key;
static char parla_drop_subclass_key;

@interface ParlaMacosPlaybackState : NSObject {
	BOOL active;
	BOOL ended;
	BOOL completion_sent;
	NSUInteger schedule_generation;
	ParlaAudioFinishedCallback callback;
	gpointer user_data;
}
- (id)initWithCallback:(ParlaAudioFinishedCallback)cb
              userData:(gpointer)data;
- (NSUInteger)beginSchedule;
- (void)cancelSchedule;
- (void)invalidate;
- (BOOL)hasEnded;
- (void)completeGeneration:(NSUInteger)generation;
@end

@implementation ParlaMacosPlaybackState

- (id)initWithCallback:(ParlaAudioFinishedCallback)cb
              userData:(gpointer)data
{
	self = [super init];
	if (self != nil) {
		active = YES;
		ended = NO;
		completion_sent = NO;
		schedule_generation = 0;
		callback = cb;
		user_data = data;
	}
	return self;
}

- (NSUInteger)beginSchedule
{
	@synchronized (self) {
		ended = NO;
		completion_sent = NO;
		return ++schedule_generation;
	}
}

- (void)cancelSchedule
{
	@synchronized (self) {
		ended = NO;
		completion_sent = NO;
		schedule_generation++;
	}
}

- (void)invalidate
{
	@synchronized (self) {
		active = NO;
		schedule_generation++;
	}
}

- (BOOL)hasEnded
{
	@synchronized (self) {
		return ended;
	}
}

- (void)completeGeneration:(NSUInteger)generation
{
	ParlaAudioFinishedCallback cb = NULL;
	gpointer data = NULL;
	@synchronized (self) {
		if (!active || completion_sent || generation != schedule_generation) {
			return;
		}
		ended = YES;
		completion_sent = YES;
		cb = callback;
		data = user_data;
	}
	if (cb != NULL) cb (TRUE, data);
}

@end

@interface ParlaMacosAudioBackend : NSObject {
	AVAudioEngine *engine;
	AVAudioPlayerNode *player;
	AVAudioUnitTimePitch *time_pitch;
	AVAudioFile *file;
	ParlaMacosPlaybackState *state;
	AVAudioFramePosition segment_start_frame;
	AVAudioFramePosition current_frame;
	BOOL segment_scheduled;
}
- (id)initWithPath:(const gchar *)path
          callback:(ParlaAudioFinishedCallback)cb
          userData:(gpointer)data;
- (BOOL)scheduleFromFrame:(AVAudioFramePosition)start_frame;
- (BOOL)playAudio;
- (void)pauseAudio;
- (void)stopAudio;
- (void)seekToSeconds:(NSTimeInterval)seconds;
- (void)setPlaybackRate:(float)rate;
- (NSTimeInterval)positionSeconds;
- (NSTimeInterval)durationSeconds;
- (BOOL)isPlaying;
- (BOOL)canSeek;
@end

@implementation ParlaMacosAudioBackend

- (id)initWithPath:(const gchar *)path
          callback:(ParlaAudioFinishedCallback)cb
          userData:(gpointer)data
{
	self = [super init];
	if (self == nil) return nil;

	NSString *file_path = [NSString stringWithUTF8String:path];
	if (file_path == nil) {
		[self release];
		return nil;
	}
	NSError *error = nil;
	file = [[AVAudioFile alloc]
		initForReading:[NSURL fileURLWithPath:file_path]
		error:&error];
	if (file == nil || file.processingFormat.sampleRate <= 0) {
		[self release];
		return nil;
	}

	state = [[ParlaMacosPlaybackState alloc] initWithCallback:cb
	                                                userData:data];
	engine = [[AVAudioEngine alloc] init];
	player = [[AVAudioPlayerNode alloc] init];
	time_pitch = [[AVAudioUnitTimePitch alloc] init];
	time_pitch.rate = 1.0f;
	[engine attachNode:player];
	[engine attachNode:time_pitch];
	[engine connect:player to:time_pitch format:file.processingFormat];
	[engine connect:time_pitch to:engine.mainMixerNode
	                            format:file.processingFormat];
	[engine prepare];
	if (![engine startAndReturnError:&error] || ![self scheduleFromFrame:0]) {
		[self release];
		return nil;
	}
	return self;
}

- (void)dealloc
{
	[state invalidate];
	[player stop];
	[engine stop];
	[player release];
	[time_pitch release];
	[engine release];
	[file release];
	[state release];
	[super dealloc];
}

- (BOOL)scheduleFromFrame:(AVAudioFramePosition)start_frame
{
	AVAudioFramePosition length = file.length;
	start_frame = MAX ((AVAudioFramePosition) 0, MIN (start_frame, length));
	AVAudioFramePosition remaining = length - start_frame;
	if (remaining <= 0) {
		segment_start_frame = length;
		segment_scheduled = NO;
		return NO;
	}

	AVAudioFrameCount frame_count = (AVAudioFrameCount) MIN (
		remaining, (AVAudioFramePosition) UINT32_MAX);
	NSUInteger generation = [state beginSchedule];
	ParlaMacosPlaybackState *scheduled_state = state;
	segment_start_frame = start_frame;
	current_frame = start_frame;
	segment_scheduled = YES;
	[player scheduleSegment:file
	          startingFrame:start_frame
	             frameCount:frame_count
	                 atTime:nil
	 completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
	       completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
		(void) type;
		dispatch_async (dispatch_get_main_queue (), ^{
			[scheduled_state completeGeneration:generation];
		});
	}];
	return YES;
}

- (BOOL)playAudio
{
	if (!segment_scheduled && ![self scheduleFromFrame:segment_start_frame]) {
		return NO;
	}
	if (!engine.running) {
		NSError *error = nil;
		if (![engine startAndReturnError:&error]) return NO;
	}
	[player play];
	return player.playing;
}

- (void)pauseAudio
{
	/* playerTimeForNodeTime: becomes unavailable after pausing, so retain the
	   last rendered source frame before stopping the render clock. */
	(void) [self positionSeconds];
	[player pause];
}

- (void)stopAudio
{
	[state cancelSchedule];
	[player stop];
	segment_start_frame = 0;
	current_frame = 0;
	segment_scheduled = NO;
}

- (void)seekToSeconds:(NSTimeInterval)seconds
{
	BOOL was_playing = player.playing;
	double sample_rate = file.processingFormat.sampleRate;
	AVAudioFramePosition target = (AVAudioFramePosition) llround (
		MAX (0.0, MIN (seconds, [self durationSeconds])) * sample_rate);
	[state cancelSchedule];
	[player stop];
	segment_scheduled = NO;
	segment_start_frame = target;
	current_frame = target;
	if ([self scheduleFromFrame:target] && was_playing) [player play];
}

- (void)setPlaybackRate:(float)rate
{
	time_pitch.rate = MAX (1.0f / 32.0f, MIN (rate, 32.0f));
}

- (NSTimeInterval)positionSeconds
{
	if ([state hasEnded]) return [self durationSeconds];
	AVAudioTime *node_time = player.lastRenderTime;
	AVAudioTime *player_time = node_time == nil
		? nil : [player playerTimeForNodeTime:node_time];
	AVAudioFramePosition frame = current_frame;
	if (player_time != nil && player_time.sampleTime >= 0) {
		frame = segment_start_frame + player_time.sampleTime;
		current_frame = MIN (frame, file.length);
	}
	return current_frame / file.processingFormat.sampleRate;
}

- (NSTimeInterval)durationSeconds
{
	return file.length / file.processingFormat.sampleRate;
}

- (BOOL)isPlaying
{
	return player.playing;
}

- (BOOL)canSeek
{
	return file.length > 0 && file.processingFormat.sampleRate > 0;
}

@end

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

gboolean
parla_audio_backend_supported (void)
{
	return TRUE;
}

gpointer
parla_audio_backend_new (const gchar                *path,
                         ParlaAudioFinishedCallback  callback,
                         gpointer                    user_data)
{
	if (path == NULL) return NULL;
	return [[ParlaMacosAudioBackend alloc] initWithPath:path
	                                           callback:callback
	                                            userData:user_data];
}

gboolean
parla_audio_backend_play (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	return backend != nil && [backend playAudio];
}

void
parla_audio_backend_pause (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	if (backend != nil) [backend pauseAudio];
}

void
parla_audio_backend_stop (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	if (backend != nil) [backend stopAudio];
}

void
parla_audio_backend_seek (gpointer handle, gint64 position_us)
{
	ParlaMacosAudioBackend *backend = handle;
	if (backend == nil) return;
	NSTimeInterval seconds = MAX ((gdouble) 0, position_us / 1000000.0);
	[backend seekToSeconds:seconds];
}

void
parla_audio_backend_set_rate (gpointer handle, gdouble rate)
{
	ParlaMacosAudioBackend *backend = handle;
	if (backend != nil) [backend setPlaybackRate:(float) rate];
}

gint64
parla_audio_backend_get_position (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	return backend == nil ? 0
		: (gint64) ([backend positionSeconds] * 1000000.0);
}

gint64
parla_audio_backend_get_duration (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	return backend == nil ? 0
		: (gint64) ([backend durationSeconds] * 1000000.0);
}

gboolean
parla_audio_backend_is_playing (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	return backend != nil && [backend isPlaying];
}

gboolean
parla_audio_backend_can_seek (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	return backend != nil && [backend canSeek];
}

void
parla_audio_backend_free (gpointer handle)
{
	ParlaMacosAudioBackend *backend = handle;
	[backend release];
}

#endif
