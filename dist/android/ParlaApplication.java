package io.github.trufae.parla;

import android.system.ErrnoException;
import android.system.Os;
import java.io.File;
import org.gtk.android.RuntimeApplication;

/** Supply Android-owned paths before GTK starts Parla's native main(). */
public final class ParlaApplication extends RuntimeApplication {
    @Override
    public void onCreate() {
        try {
            Os.setenv("PARLA_ANDROID_FILES", getFilesDir().getAbsolutePath(), true);
            Os.setenv("PARLA_ANDROID_CACHE", getCacheDir().getAbsolutePath(), true);
            Os.setenv("TMPDIR", getCacheDir().getAbsolutePath(), true);
            Os.setenv("PARLA_RPC_SERVER", new File(getApplicationInfo().nativeLibraryDir,
                    "libchatmail-rpc.so").getAbsolutePath(), true);
        } catch (ErrnoException error) {
            throw new IllegalStateException("Cannot initialize Parla", error);
        }
        super.onCreate();
    }
}
