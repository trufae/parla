using Dc.Webxdc;

private void paths () {
    foreach (string path in new string[] { "/index.html", "js/app.js", "/assets/a b.png", "/" })
        assert (Wire.resource_path (path));
    foreach (string path in new string[] { "", "../secret", "/../secret", "a/../../secret",
        "//etc/passwd", "file:///etc/passwd", "C:\\secret", "a\\..\\secret" })
        assert (!Wire.resource_path (path));
}

private void fields () {
    var obj = Wire.packet ("blob");
    obj.set_string_member ("id", "1");
    obj.set_int_member ("internet", 1);
    try { Wire.number (obj, "id"); assert_not_reached (); } catch (Error e) {}
    try { Wire.flag (obj, "internet"); assert_not_reached (); } catch (Error e) {}
    try { Wire.text (obj, "missing"); assert_not_reached (); } catch (Error e) {}
}

private void read_frame (uint8[] data, bool valid, int limit = Wire.MAX_FRAME) {
    var input = new MemoryInputStream.from_bytes (new Bytes (data));
    var output = new MemoryOutputStream.resizable ();
    var wire = new Wire (input, output, limit);
    var loop = new MainLoop ();
    int messages = 0;
    string? failure = null;
    wire.received.connect (() => { messages++; });
    wire.ended.connect ((reason) => { failure = reason; loop.quit (); });
    wire.read.begin ();
    loop.run ();
    assert (valid ? messages == 1 && failure == null : messages == 0 && failure != null);
}

private void frames () {
    read_frame ({ 0, 0, 0, 2, '{', '}' }, true);
    read_frame ({ 0xff, 0xff, 0xff, 0xff }, false);
    read_frame ({ 0, 0, 0 }, false);
    read_frame ({ 0, 0, 0, 4, '{' }, false);
    read_frame ({ 0, 0, 0, 2, '[', ']' }, false);
    read_frame ({ 0, 0, 0, 3, '{', '}', 0 }, false);
    read_frame ({ 0, 0, 0, 2, 0xff, 0xff }, false);
    read_frame ({ 0, 0, 0, 2, '{', '}' }, false, 1);
}

private void writes () {
    var output = new MemoryOutputStream.resizable ();
    var input = new MemoryInputStream ();
    var wire = new Wire (input, output);
    wire.send (Wire.packet ("first"));
    wire.send (Wire.packet ("second"));
    while (output.get_data_size () < 37) MainContext.default ().iteration (true);
    unowned uint8[] bytes = output.get_data ();
    assert (bytes[3] == 14 && bytes[21] == 15);
    wire.stop ();
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/webxdc-wire/paths", paths);
    Test.add_func ("/webxdc-wire/types", fields);
    Test.add_func ("/webxdc-wire/frames", frames);
    Test.add_func ("/webxdc-wire/writes", writes);
    return Test.run ();
}
