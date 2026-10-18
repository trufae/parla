namespace Dc {

    /* GTK's Android content files can return a non-null get_path() that is
       only a URI component. The RPC process needs an actual filesystem file. */
    public class LocalFile : Object {
        public string path { get; private set; default = ""; }
        public string name { get; private set; default = "attachment"; }
        public bool temporary { get; private set; default = false; }

        public static async LocalFile from_file (GLib.File file) throws Error {
            var result = new LocalFile ();
            result.name = file.get_basename () ?? "attachment";
            string? path = file.is_native () ? file.get_path () : null;
            if (path != null) {
                result.path = path;
                return result;
            }

            try {
                var info = yield file.query_info_async (
                    FileAttribute.STANDARD_DISPLAY_NAME, FileQueryInfoFlags.NONE);
                string? name = info.get_display_name ();
                if (name != null && name.length > 0) result.name = name;
            } catch (Error e) {
                // Some content providers allow reading but expose no metadata.
            }
            string basename = Path.get_basename (result.name);
            int dot = basename.last_index_of_char ('.');
            string suffix = dot > 0 ? basename.substring (dot) : "";
            GLib.FileIOStream stream;
            var tmp = GLib.File.new_tmp ("parla-XXXXXX" + suffix, out stream);
            result.path = tmp.get_path ();
            result.temporary = true;
            stream.close ();
            yield file.copy_async (tmp, FileCopyFlags.OVERWRITE,
                                   Priority.DEFAULT, null, null);
            return result;
        }

        /* Transfer cleanup to the composer's existing temporary-file owner. */
        public string take_path () {
            temporary = false;
            return path;
        }

        ~LocalFile () {
            if (temporary) FileUtils.unlink (path);
        }
    }
}
