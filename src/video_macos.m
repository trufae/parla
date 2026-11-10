#include "platform.h"

#import <AVFoundation/AVFoundation.h>
#include <gtk/gtk.h>
#include <glib/gi18n-lib.h>
#include <math.h>

/* Feed AVPlayer's decoded frames into Gtk.Video independently of optional
 * GTK media modules, keeping the same controls and overlay as on Linux. */
typedef struct {
	GtkMediaStream parent_instance;
	AVPlayer *player;
	AVPlayerItemVideoOutput *output;
	GdkTexture *texture;
	CGAffineTransform orientation;
	graphene_matrix_t transform;
	int width;
	int height;
	guint timer;
	guint seek_serial;
	gboolean needs_frame;
} ParlaVideoStream;

typedef GtkMediaStreamClass ParlaVideoStreamClass;

static void parla_video_paintable_init (GdkPaintableInterface *iface);
G_DEFINE_TYPE_WITH_CODE (ParlaVideoStream, parla_video_stream, GTK_TYPE_MEDIA_STREAM,
	G_IMPLEMENT_INTERFACE (GDK_TYPE_PAINTABLE, parla_video_paintable_init))

static gint64
video_time_us (CMTime time)
{
	return CMTIME_IS_NUMERIC (time)
		? MAX ((gint64) 0, CMTimeConvertScale (time, G_USEC_PER_SEC,
			kCMTimeRoundingMethod_Default).value) : 0;
}

static void
video_update_frame (ParlaVideoStream *self, CMTime time)
{
	if (![self->output hasNewPixelBufferForItemTime:time]) return;
	CVPixelBufferRef buffer = [self->output copyPixelBufferForItemTime:time
		itemTimeForDisplay:NULL];
	if (buffer == NULL) return;
	if (CVPixelBufferLockBaseAddress (buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
		CVPixelBufferRelease (buffer);
		return;
	}
	int width = (int) CVPixelBufferGetWidth (buffer);
	int height = (int) CVPixelBufferGetHeight (buffer);
	size_t stride = CVPixelBufferGetBytesPerRow (buffer);
	GBytes *bytes = g_bytes_new (CVPixelBufferGetBaseAddress (buffer), stride * height);
	GdkTexture *texture = gdk_memory_texture_new (width, height,
		GDK_MEMORY_B8G8R8A8, bytes, stride);
	g_bytes_unref (bytes);
	CVPixelBufferUnlockBaseAddress (buffer, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferRelease (buffer);

	gboolean resized = self->texture == NULL
		|| gdk_texture_get_width (self->texture) != width
		|| gdk_texture_get_height (self->texture) != height;
	g_set_object (&self->texture, texture);
	g_object_unref (texture);
	self->needs_frame = FALSE;
	if (resized) {
		CGRect bounds = CGRectApplyAffineTransform (CGRectMake (0, 0, width, height),
			self->orientation);
		self->width = (int) ceil (bounds.size.width);
		self->height = (int) ceil (bounds.size.height);
		graphene_matrix_init_from_2d (&self->transform,
			self->orientation.a, self->orientation.b,
			self->orientation.c, self->orientation.d,
			self->orientation.tx - bounds.origin.x,
			self->orientation.ty - bounds.origin.y);
		gdk_paintable_invalidate_size (GDK_PAINTABLE (self));
	}
	gdk_paintable_invalidate_contents (GDK_PAINTABLE (self));
}

static gboolean
video_tick (gpointer data)
{
	/* Notifications may close the viewer and release its stream. */
	ParlaVideoStream *self = g_object_ref (data);
	GtkMediaStream *stream = GTK_MEDIA_STREAM (self);
	gboolean keep = TRUE;
	@autoreleasepool {
		AVPlayerItem *item = self->player.currentItem;
		if (item.status == AVPlayerItemStatusFailed || self->player.status == AVPlayerStatusFailed) {
			NSError *error = item.error ?: self->player.error;
			gtk_media_stream_error (stream, G_IO_ERROR, G_IO_ERROR_FAILED, "%s",
				error != nil ? error.localizedDescription.UTF8String : _("Could not play video"));
			keep = FALSE;
		} else if (item.status == AVPlayerItemStatusReadyToPlay) {
			if (!gtk_media_stream_is_prepared (stream)) {
				gboolean audio = FALSE, video = FALSE;
				/* The item has already loaded its tracks before becoming ready.
				 * These synchronous accessors also support our macOS 13 baseline. */
				G_GNUC_BEGIN_IGNORE_DEPRECATIONS
				for (AVPlayerItemTrack *track in item.tracks) {
					audio |= [track.assetTrack.mediaType isEqualToString:AVMediaTypeAudio];
					video |= [track.assetTrack.mediaType isEqualToString:AVMediaTypeVideo];
					if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) {
						self->orientation = track.assetTrack.preferredTransform;
					}
				}
				G_GNUC_END_IGNORE_DEPRECATIONS
				gtk_media_stream_stream_prepared (stream, audio, video, TRUE,
					video_time_us (item.duration));
				if (gtk_media_stream_get_playing (stream)) [self->player play];
			}
			CMTime time = self->player.currentTime;
			video_update_frame (self, time);
			if (!gtk_media_stream_is_seeking (stream)) {
				gint64 position = video_time_us (time);
				gint64 duration = gtk_media_stream_get_duration (stream);
				gtk_media_stream_update (stream, position);
				if (gtk_media_stream_get_playing (stream) && duration > 0
					&& position >= duration && self->player.rate == 0) {
					if (gtk_media_stream_get_loop (stream)) {
						gtk_media_stream_seek (stream, 0);
					} else {
						gtk_media_stream_stream_ended (stream);
					}
				}
			}
			keep = gtk_media_stream_get_playing (stream)
				|| gtk_media_stream_is_seeking (stream)
				|| (gtk_media_stream_has_video (stream) && self->needs_frame);
		}
	}
	if (!keep) self->timer = 0;
	g_object_unref (self);
	return keep ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

static void
video_start_timer (ParlaVideoStream *self)
{
	if (self->timer == 0) self->timer = g_timeout_add (16, video_tick, self);
}

static gboolean
video_play (GtkMediaStream *stream)
{
	ParlaVideoStream *self = (ParlaVideoStream *) stream;
	if (gtk_media_stream_get_ended (stream)) gtk_media_stream_seek (stream, 0);
	if (gtk_media_stream_is_prepared (stream)) [self->player play];
	video_start_timer (self);
	return TRUE;
}

static void
video_pause (GtkMediaStream *stream)
{
	ParlaVideoStream *self = (ParlaVideoStream *) stream;
	[self->player pause];
}

typedef struct {
	ParlaVideoStream *stream;
	guint serial;
	gboolean finished;
} VideoSeek;

static gboolean
video_seek_complete (gpointer data)
{
	VideoSeek *seek = data;
	ParlaVideoStream *self = seek->stream;
	GtkMediaStream *stream = GTK_MEDIA_STREAM (self);
	if (seek->serial == self->seek_serial && gtk_media_stream_is_seeking (stream)) {
		if (seek->finished) {
			gtk_media_stream_update (stream, video_time_us (self->player.currentTime));
			gtk_media_stream_seek_success (stream);
			if (gtk_media_stream_get_playing (stream)) [self->player play];
		} else {
			gtk_media_stream_seek_failed (stream);
		}
		video_start_timer (self);
	}
	return G_SOURCE_REMOVE;
}

static void
video_seek_free (gpointer data)
{
	VideoSeek *seek = data;
	g_object_unref (seek->stream);
	g_free (seek);
}

static void
video_seek (GtkMediaStream *stream, gint64 timestamp)
{
	ParlaVideoStream *self = (ParlaVideoStream *) stream;
	VideoSeek *seek = g_new0 (VideoSeek, 1);
	seek->stream = g_object_ref (self);
	seek->serial = ++self->seek_serial;
	self->needs_frame = TRUE;
	gint64 duration = gtk_media_stream_get_duration (stream);
	if (duration > 0) timestamp = MIN (timestamp, duration);
	[self->player seekToTime:CMTimeMake (timestamp, G_USEC_PER_SEC)
		toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
		completionHandler:^(BOOL finished) {
			seek->finished = finished;
			/* AVFoundation may complete on another queue. GTK stays on
			 * the main context, including the final object unref. */
			g_idle_add_full (G_PRIORITY_DEFAULT, video_seek_complete, seek, video_seek_free);
		}];
	video_start_timer (self);
}

static void
video_update_audio (GtkMediaStream *stream, gboolean muted, double volume)
{
	ParlaVideoStream *self = (ParlaVideoStream *) stream;
	self->player.muted = muted;
	self->player.volume = volume;
}

static void
video_snapshot (GdkPaintable *paintable, GdkSnapshot *snapshot, double width, double height)
{
	ParlaVideoStream *self = (ParlaVideoStream *) paintable;
	if (self->texture == NULL || self->width <= 0 || self->height <= 0) return;
	GtkSnapshot *target = GTK_SNAPSHOT (snapshot);
	gtk_snapshot_save (target);
	gtk_snapshot_scale (target, width / self->width, height / self->height);
	/* Video outputs contain encoded frames; apply the track's display
	 * transform here, including rotation/mirroring from phone cameras. */
	gtk_snapshot_transform_matrix (target, &self->transform);
	graphene_rect_t rect = GRAPHENE_RECT_INIT (0, 0,
		gdk_texture_get_width (self->texture), gdk_texture_get_height (self->texture));
	gtk_snapshot_append_texture (target, self->texture, &rect);
	gtk_snapshot_restore (target);
}

static GdkPaintable *
video_current_image (GdkPaintable *paintable)
{
	ParlaVideoStream *self = (ParlaVideoStream *) paintable;
	if (self->texture == NULL) return gdk_paintable_new_empty (0, 0);
	GtkSnapshot *snapshot = gtk_snapshot_new ();
	video_snapshot (paintable, GDK_SNAPSHOT (snapshot), self->width, self->height);
	graphene_size_t size = GRAPHENE_SIZE_INIT (self->width, self->height);
	return gtk_snapshot_free_to_paintable (snapshot, &size);
}

static int
video_width (GdkPaintable *paintable)
{
	ParlaVideoStream *self = (ParlaVideoStream *) paintable;
	return self->width;
}

static int
video_height (GdkPaintable *paintable)
{
	ParlaVideoStream *self = (ParlaVideoStream *) paintable;
	return self->height;
}

static void
parla_video_paintable_init (GdkPaintableInterface *iface)
{
	iface->snapshot = video_snapshot;
	iface->get_current_image = video_current_image;
	iface->get_intrinsic_width = video_width;
	iface->get_intrinsic_height = video_height;
}

static void
video_dispose (GObject *object)
{
	ParlaVideoStream *self = (ParlaVideoStream *) object;
	if (self->timer != 0) {
		g_source_remove (self->timer);
		self->timer = 0;
	}
	[self->player pause];
	[self->player replaceCurrentItemWithPlayerItem:nil];
	[self->player release];
	self->player = nil;
	[self->output release];
	self->output = nil;
	g_clear_object (&self->texture);
	G_OBJECT_CLASS (parla_video_stream_parent_class)->dispose (object);
}

static void
parla_video_stream_class_init (ParlaVideoStreamClass *klass)
{
	G_OBJECT_CLASS (klass)->dispose = video_dispose;
	klass->play = video_play;
	klass->pause = video_pause;
	klass->seek = video_seek;
	klass->update_audio = video_update_audio;
}

static void
parla_video_stream_init (ParlaVideoStream *self)
{
	self->needs_frame = TRUE;
	self->orientation = CGAffineTransformIdentity;
}

GtkMediaStream *
parla_video_stream_new (const gchar *path)
{
	ParlaVideoStream *self = g_object_new (parla_video_stream_get_type (), NULL);
	@autoreleasepool {
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
		AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset
			automaticallyLoadedAssetKeys:@[@"tracks", @"duration", @"playable"]];
		self->output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
			(id) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
		}];
		self->output.suppressesPlayerRendering = YES;
		[item addOutput:self->output];
		self->player = [[AVPlayer alloc] initWithPlayerItem:item];
	}
	video_start_timer (self);
	return GTK_MEDIA_STREAM (self);
}
