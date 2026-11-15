using Parla.Terminal;

int main () {
    try {
        string root = DirUtils.make_tmp ("parla-colors-XXXXXX");
        Environment.set_variable ("XDG_CONFIG_HOME", root, true);
        string folder = Path.build_filename (root, "parla");
        string colors = Path.build_filename (folder, "colors.ini");
        string layout = Path.build_filename (folder, "terminal.ini");
        var options = new CliOptions ();
        assert (options.value ("theme") == "default");
        assert (!FileUtils.test (colors, FileTest.EXISTS));
        options.change ("chat_info", "on");
        foreach (var preset in Theme.PRESETS) {
            options.change ("theme", preset);
            assert (new CliOptions ().value ("theme") == preset);
        }
        options.change ("color_status", "#123ABC:blue");
        options.change ("theme", "forest");
        options = new CliOptions ();
        assert (options.theme ().get_color ("status") == "#123abc:blue");
        options.change ("color_status", "inherit");
        options = new CliOptions ();
        assert (options.theme ().get_color ("status") == new Theme ("forest").get_color ("status"));
        foreach (var name in new string[] { "theme", "color_status", "color_missing" }) {
            try { options.change (name, "invalid"); assert_not_reached (); }
            catch (IOError.INVALID_ARGUMENT e) { }
        }
        assert (new CliOptions ().value ("theme") == "forest");
        options.reset_colors ();
        options.reset_colors (); // Reset is also valid on a fresh installation.
        options.save (); // A pending layout save must not resurrect colors.
        assert (!FileUtils.test (colors, FileTest.EXISTS));
        assert (options.value ("theme") == "default");
        assert (new CliOptions ().enabled ("chat_info"));
        var view = new View ();
        options.apply (view);
        assert (view.info_visible);

        // Existing terminal.ini colors migrate once, without losing layout.
        FileUtils.set_contents (layout, "[Terminal]\nchat_info=on\ntheme=ocean\ncolor_status=red\n");
        options = new CliOptions ();
        assert (options.value ("theme") == "ocean");
        assert (options.theme ().get_color ("status") == "red");
        assert (FileUtils.test (colors, FileTest.EXISTS));
        File.new_for_path (colors).delete ();
        options = new CliOptions ();
        assert (options.value ("theme") == "default" && options.value ("color_status") == "inherit");
        assert (options.enabled ("chat_info"));

        FileUtils.set_contents (colors, "[Terminal]\ntheme=missing\ncolor_status=#bad\ncolor_message=cyan\nchat_info=off\n");
        options = new CliOptions ();
        assert (options.value ("theme") == "default" && options.value ("color_status") == "inherit");
        assert (options.theme ().get_color ("message") == "cyan" && options.enabled ("chat_info"));
        options.reset_colors ();
        assert (options.theme ().get_color ("message") == new Theme ().get_color ("message"));

        // Failed writes and deletes must leave the active theme intact.
        options.change ("theme", "ember");
        File.new_for_path (colors).delete ();
        DirUtils.create (colors, 0700);
        string blocker = Path.build_filename (colors, "blocker");
        FileUtils.set_contents (blocker, "");
        try { options.change ("theme", "ocean"); assert_not_reached (); }
        catch (FileError e) { }
        try { options.reset_colors (); assert_not_reached (); }
        catch (IOError.NOT_EMPTY e) { }
        assert (options.value ("theme") == "ember");
        File.new_for_path (blocker).delete ();
        File.new_for_path (colors).delete ();
        File.new_for_path (layout).delete ();
        DirUtils.remove (folder);
        DirUtils.remove (root);
    } catch (Error e) { error ("Color preferences: %s", e.message); }
    return 0;
}
