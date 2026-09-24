using Dc;

private const string PNG_ICON =
    "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAIAAAACUFjqAAAAFElEQVR4nGPkSvnF"
    + "gBsw4ZEbwdIAvZEBfDrzQQkAAAAASUVORK5CYII=";

private void binary_blobs () {
    for (int length = 0; length <= 258; length++) {
        var data = new uint8[length];
        for (int i = 0; i < length; i++) data[i] = (uint8) i;
        var expected = new Bytes (data);
        string padded = Base64.encode (data);
        foreach (string blob in new string[] { padded, padded.replace ("=", "") }) {
            var decoded = new Bytes (decode_rpc_blob (blob));
            assert (decoded.compare (expected) == 0);
        }
    }
}

private void png_icon () {
    foreach (string blob in new string[] { PNG_ICON, PNG_ICON.replace ("=", "") }) {
        try {
            var bytes = new Bytes (decode_rpc_blob (blob));
            assert (bytes.get_size () == 77);
            var texture = Gdk.Texture.from_bytes (bytes);
            assert (texture.width == 10 && texture.height == 10);
        } catch (Error e) {
            error ("Valid Webxdc icon rejected: %s", e.message);
        }
    }
}

private void invalid_icons () {
    foreach (string blob in new string[] { "", "bm90IGFuIGltYWdl", PNG_ICON.substring (0, 32) }) {
        try {
            Gdk.Texture.from_bytes (new Bytes (decode_rpc_blob (blob)));
            assert_not_reached ();
        } catch (Error e) {
            // Invalid images must still raise an error for the caller's fallback.
        }
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/rpc-blob/binary", binary_blobs);
    Test.add_func ("/rpc-blob/png-icon", png_icon);
    Test.add_func ("/rpc-blob/invalid-icons", invalid_icons);
    return Test.run ();
}
