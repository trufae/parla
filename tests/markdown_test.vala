private string strip_gtk_links (string markup) throws RegexError {
    return /<\/?a(\s[^>]*)?>/.replace (markup, -1, 0, "");
}

private void assert_valid_pango_markup (string markup) {
    try {
        Pango.AttrList attrs;
        string parsed;
        unichar accel;
        Pango.parse_markup (strip_gtk_links (markup), -1, 0,
                            out attrs, out parsed, out accel);
    } catch (Error e) {
        assert_not_reached ();
    }
}

private void test_table_grid () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;

    string markup = Dc.Markdown.format (
        "| Name | Qty |\n" +
        "| --- | ---: |\n" +
        "| Apples | 12 |\n" +
        "| Pear | 7 |");

    assert (markup ==
        "<tt>Name   | Qty\n" +
        "-------+----\n" +
        "Apples |  12\n" +
        "Pear   |   7</tt>");
    assert_valid_pango_markup (markup);
}

private void test_table_with_inline_markup_and_link () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;

    string markup = Dc.Markdown.format (
        "| Thing | URL |\n" +
        "| --- | --- |\n" +
        "| **bold** | https://example.com |");

    assert (markup.contains ("<tt>Thing"));
    assert (markup.contains ("<b>bold</b>"));
    assert (markup.contains ("<a href=\"https://example.com\">"));
    assert_valid_pango_markup (markup);
}

private void test_plain_pipe_text_is_not_table () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;

    string markup = Dc.Markdown.format ("hello | world\nnot a separator");

    assert (!markup.contains ("<tt>"));
    assert (markup == "hello | world\nnot a separator");
}

private void test_task_checkboxes () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;

    string markup = Dc.Markdown.format (
        "* [ ] Todo\n" +
        "* [x] Done\n" +
        "  * [x] Nested");

    assert (markup == "⬜ Todo\n✅ Done\n  ✅ Nested");
    assert_valid_pango_markup (markup);
}

private void test_task_checkboxes_skip_code () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;

    string markup = Dc.Markdown.format ("`* [x] Done`");

    assert (markup == "<tt>* [x] Done</tt>");
    assert_valid_pango_markup (markup);
}

private void test_code_block_highlighting () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.ADAPTIVE;
    Dc.SyntaxHighlight.dark_mode = false;

    string markup = Dc.Markdown.format (
        "```c\nint x = 42; // answer\nputs (\"hi\");\n```");

    assert (markup.has_prefix ("<tt>"));
    assert (markup.has_suffix ("</tt>"));
    /* keyword/type, number, comment (italic) and string all colored */
    assert (markup.contains (">int</span>"));
    assert (markup.contains (">42</span>"));
    assert (markup.contains ("style=\"italic\">// answer</span>"));
    assert (markup.contains (">&quot;hi&quot;</span>"));
    assert (markup.contains (">puts</span>"));
    assert_valid_pango_markup (markup);
}

private void test_code_block_highlighting_escapes () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.ADAPTIVE;
    Dc.SyntaxHighlight.dark_mode = false;

    string markup = Dc.Markdown.format (
        "```\nif (a < b && c > 0) return \"x&y\";\n```");

    assert (markup.contains ("&lt;"));
    assert (markup.contains ("&amp;&amp;"));
    assert (markup.contains ("&gt;"));
    assert_valid_pango_markup (markup);
}

private void test_code_block_theme_none_is_plain () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.NONE;

    string markup = Dc.Markdown.format ("```c\nint x = 42;\n```");

    assert (markup == "<tt>int x = 42;\n</tt>");
    assert_valid_pango_markup (markup);
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.ADAPTIVE;
}

private void test_code_block_tilde_fence () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.NONE;

    string markup = Dc.Markdown.format ("~~~c\nint x = 42;\n~~~");

    assert (markup == "<tt>int x = 42;\n</tt>");
    assert_valid_pango_markup (markup);
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.ADAPTIVE;
}

private void test_code_block_fences_must_match () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.NONE;

    /* A tilde fence is only closed by tildes, so backtick fences
       survive inside it as literal content. */
    string markup = Dc.Markdown.format ("~~~\n```c\nint x = 42;\n```\n~~~");

    assert (markup == "<tt>```c\nint x = 42;\n```\n</tt>");
    assert_valid_pango_markup (markup);
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.ADAPTIVE;
}

private void test_inline_code_stays_plain () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    Dc.SyntaxHighlight.theme = Dc.CodeTheme.ADAPTIVE;

    string markup = Dc.Markdown.format ("`int x = 42;`");

    assert (markup == "<tt>int x = 42;</tt>");
}

private void test_unicode_and_multiple_replacements () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    string markup = Dc.Markdown.format (
        "α `β` γ `δ` https://example.com/é");

    assert (markup == "α <tt>β</tt> γ <tt>δ</tt> "
        + "<a href=\"https://example.com/é\"><span underline=\"single\">"
        + "https://example.com/é</span></a>");
}

private void test_rendering_modes () {
    Dc.Markdown.mode = Dc.MarkdownMode.ENABLED;
    assert (Dc.Markdown.format ("**bold** and `code`") ==
        "<b>bold</b> and <tt>code</tt>");

    Dc.Markdown.mode = Dc.MarkdownMode.STRIPPED;
    assert (Dc.Markdown.format ("**bold** and `code`") == "bold and code");

    Dc.Markdown.mode = Dc.MarkdownMode.DISABLED;
    assert (Dc.Markdown.format ("**bold** and `code`") ==
        "**bold** and `code`");
}

private void test_explicit_rendering_mode_is_local () {
    Dc.Markdown.mode = Dc.MarkdownMode.DISABLED;

    assert (Dc.Markdown.format_with_mode (
        "**bold** and `code`", Dc.MarkdownMode.ENABLED) ==
        "<b>bold</b> and <tt>code</tt>");
    assert (Dc.Markdown.mode == Dc.MarkdownMode.DISABLED);
    assert (Dc.Markdown.format ("**bold**") == "**bold**");
}

private void test_strip_inline_markdown () {
    string plain = Dc.Markdown.strip (
        "# Title\n" +
        "foo **bar** __baz__ *qux* _quux_ ~~gone~~");

    assert (plain == "Title\nfoo bar baz qux quux gone");
}

private void test_strip_links_lists_and_quotes () {
    string plain = Dc.Markdown.strip (
        "> See [docs](https://example.com) and ![alt](img.png)\n" +
        "- one\n" +
        "1. two");

    assert (plain == "See docs and alt\none\ntwo");
}

private void test_strip_task_checkboxes () {
    string plain = Dc.Markdown.strip (
        "* [ ] Todo\n" +
        "* [x] Done\n" +
        "  * [x] Nested\n" +
        "* [x]");

    assert (plain ==
        "☐ Todo\n" +
        "✓ Done\n" +
        "  ✓ Nested\n" +
        "✓");
}

private void test_strip_task_checkboxes_standard_only () {
    string plain = Dc.Markdown.strip (
        "[x] Already stripped\n" +
        "*[x] Compact\n" +
        "- [x] Dash\n" +
        "+ [x] Plus\n" +
        "• [x] Bullet\n" +
        "Title * [x] Flattened");

    assert (plain ==
        "[x] Already stripped\n" +
        "*[x] Compact\n" +
        "[x] Dash\n" +
        "[x] Plus\n" +
        "• [x] Bullet\n" +
        "Title * [x] Flattened");
}

private void test_strip_preserves_code_contents () {
    string plain = Dc.Markdown.strip (
        "`**literal**`\n" +
        "```vala\n* [x] literal\n```");

    assert (plain == "**literal**\n* [x] literal");
}

private void test_strip_preserves_tilde_code_contents () {
    string plain = Dc.Markdown.strip (
        "~~~vala\n* [x] literal\n~~~");

    assert (plain == "* [x] literal");
}

private void test_preview_strips_before_newline_clamp () {
    string preview = Dc.Markdown.preview (
        "Intro\n" +
        "* [x] Done\n" +
        "* [ ] Todo\n" +
        "Hidden", 3, 240);

    assert (preview ==
        "Intro\n" +
        "✓ Done\n" +
        "☐ Todo…");
}

private void test_preview_strips_before_char_clamp () {
    string preview = Dc.Markdown.preview ("* [x] Done", 3, 3);

    assert (preview == "✓ D…");
}

private void test_single_line_preview_strips_before_newline_trim () {
    string preview = Dc.Markdown.single_line_preview (
        "Intro\n" +
        "* [x] Done\n" +
        "* [ ] Todo", 0);

    assert (preview == "Intro ✓ Done ☐ Todo");
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/markdown/table-grid", test_table_grid);
    Test.add_func ("/markdown/table-inline-markup-link", test_table_with_inline_markup_and_link);
    Test.add_func ("/markdown/plain-pipe-text", test_plain_pipe_text_is_not_table);
    Test.add_func ("/markdown/task-checkboxes", test_task_checkboxes);
    Test.add_func ("/markdown/task-checkboxes-skip-code", test_task_checkboxes_skip_code);
    Test.add_func ("/markdown/code-block-highlighting", test_code_block_highlighting);
    Test.add_func ("/markdown/code-block-highlighting-escapes", test_code_block_highlighting_escapes);
    Test.add_func ("/markdown/code-block-theme-none", test_code_block_theme_none_is_plain);
    Test.add_func ("/markdown/code-block-tilde-fence", test_code_block_tilde_fence);
    Test.add_func ("/markdown/code-block-fences-must-match", test_code_block_fences_must_match);
    Test.add_func ("/markdown/inline-code-stays-plain", test_inline_code_stays_plain);
    Test.add_func ("/markdown/unicode-multiple-replacements",
                   test_unicode_and_multiple_replacements);
    Test.add_func ("/markdown/rendering-modes", test_rendering_modes);
    Test.add_func ("/markdown/explicit-rendering-mode-is-local", test_explicit_rendering_mode_is_local);
    Test.add_func ("/markdown/strip-inline-markdown", test_strip_inline_markdown);
    Test.add_func ("/markdown/strip-links-lists-and-quotes", test_strip_links_lists_and_quotes);
    Test.add_func ("/markdown/strip-task-checkboxes", test_strip_task_checkboxes);
    Test.add_func ("/markdown/strip-task-checkboxes-standard-only", test_strip_task_checkboxes_standard_only);
    Test.add_func ("/markdown/strip-preserves-code-contents", test_strip_preserves_code_contents);
    Test.add_func ("/markdown/strip-preserves-tilde-code-contents", test_strip_preserves_tilde_code_contents);
    Test.add_func ("/markdown/preview-strips-before-newline-clamp", test_preview_strips_before_newline_clamp);
    Test.add_func ("/markdown/preview-strips-before-char-clamp", test_preview_strips_before_char_clamp);
    Test.add_func ("/markdown/single-line-preview-strips-before-newline-trim", test_single_line_preview_strips_before_newline_trim);
    return Test.run ();
}
