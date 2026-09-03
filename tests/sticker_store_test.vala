using Dc;

/* StickerStore only needs the application's data directory for filesystem
   operations, which these parsing tests do not exercise. */
namespace Dc {
    public class AccountFinder : Object {
        public static string get_parla_data_dir () {
            return "/tmp/parla-sticker-store-test";
        }
    }
}

private void test_format_independent_names () {
    Sticker? png = StickerStore.parse ("cats__😺__wave.png");
    assert (png != null);
    assert (png.pack == "cats");
    assert (png.emoji == "😺");
    assert (png.display_name == "wave.png");

    Sticker? extensionless = StickerStore.parse ("cats____blob");
    assert (extensionless != null);
    assert (extensionless.display_name == "blob");
}

private void test_foreign_names_are_ignored () {
    assert (!StickerStore.is_sticker_filename ("orphan.webp"));
    assert (!StickerStore.is_sticker_filename ("__😺__wave.png"));
    assert (!StickerStore.is_sticker_filename ("cats__😺__"));
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/sticker-store/format-independent-names",
        test_format_independent_names);
    Test.add_func ("/sticker-store/foreign-names",
        test_foreign_names_are_ignored);
    return Test.run ();
}
