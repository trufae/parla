using Dc;

async void check_imports () throws Error {
    var source = File.new_for_uri (
        "resource:///io/github/trufae/Parla/icons/scalable/apps/parla-welcome.svg");
    assert (!source.is_native ());
    uint8[] expected;
    source.load_contents (null, out expected, null);

    var imported = yield LocalFile.from_file (source);
    string path = imported.path;
    assert (imported.temporary);
    assert (imported.name == "parla-welcome.svg");
    assert (path.has_suffix (".svg"));
    uint8[] actual;
    File.new_for_path (path).load_contents (null, out actual, null);
    assert (actual.length == expected.length);
    assert (Memory.cmp (actual, expected, actual.length) == 0);
    imported = null;
    assert (!FileUtils.test (path, FileTest.EXISTS));

    imported = yield LocalFile.from_file (source);
    path = imported.take_path ();
    imported = null;
    assert (FileUtils.test (path, FileTest.EXISTS));
    var native = yield LocalFile.from_file (File.new_for_path (path));
    assert (!native.temporary);
    assert (native.path == path);
    native = null;
    assert (FileUtils.test (path, FileTest.EXISTS));
    FileUtils.unlink (path);

    bool failed = false;
    try {
        yield LocalFile.from_file (File.new_for_uri ("resource:///missing.jpg"));
    } catch (Error e) {
        failed = true;
    }
    assert (failed);
}

int main () {
    var loop = new MainLoop ();
    int status = 0;
    check_imports.begin ((obj, res) => {
        try {
            check_imports.end (res);
        } catch (Error e) {
            stderr.printf ("Import failed: %s\n", e.message);
            status = 1;
        }
        loop.quit ();
    });
    loop.run ();
    return status;
}
