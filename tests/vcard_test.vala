using Dc;

public void test_vcard_metadata () {
    var msg = RpcParsers.parse_message (object_from_json (
        """{"viewType":"Vcard","fileName":"contact.vcf","vcardContact":{"addr":"alice@example.org","displayName":"Alice <&>","profileImage":"broken image"}}"""));
    assert (msg.is_vcard ());
    assert (msg.vcard_contact.name == "Alice <&>");
    assert (msg.vcard_contact.address == "alice@example.org");
    assert (VcardPreview.thumbnail (msg.vcard_contact) == null);
    assert (msg.dup ().vcard_contact == msg.vcard_contact);
    msg = new Message ();
    assert (!msg.is_vcard ());
    msg.file_name = "CONTACT.VCF";
    assert (msg.is_vcard ());
    msg.file_name = null;
    msg.file_mime = "text/x-vcard; charset=utf-8";
    assert (msg.is_vcard ());
    msg.file_mime = "text/plain";
    assert (!msg.is_vcard ());
    msg.file_path = "/tmp/card.vcf";
    assert (msg.is_vcard ());
    msg = RpcParsers.parse_message (object_from_json (
        """{"viewType":"File","fileName":"phone.vcf","vcardContact":{"addr":"","displayName":"Phone contact"}}"""));
    assert (msg.is_vcard ());
    assert (msg.vcard_contact.name == "Phone contact");
    assert (msg.vcard_contact.address == "");
    var unnamed = new VcardContact (object_from_json ("{}"));
    assert (unnamed.name == "Contact card");
}

private const string VCARD_ALICE = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Alice <&>\r\nEMAIL:alice@example.org\r\nEND:VCARD\r\n";
private const string VCARD_BOB = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bob\\, Example\r\nEMAIL:bob@example.org\r\nEND:VCARD\r\n";
private const string VCARD_PHONE = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Phone Contact\r\nTEL;TYPE=CELL:+34 123 456 789\r\nEND:VCARD\r\n";
private const string VCARD_NAME = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Name Only\r\nEND:VCARD\r\n";

/* Optional integration smoke against the installed backend. All accounts
   live in a fresh temporary directory, and no network I/O is started. */
private async void check_vcard_core (string server, string fixture, bool ui) {
    var rpc = new RpcClient ();
    string? snapshot = null;
    try {
        string folder = DirUtils.make_tmp ("parla-vcard-test-XXXXXX");
        yield rpc.start ({ server }, null, Path.build_filename (folder, "accounts"));
        int source = yield rpc.add_account ();
        int destination = yield rpc.add_account ();
        rpc.account_id = source;
        var before = yield rpc.get_contact_ids_for (source, null);
        var doc = yield VcardDocument.from_contents (rpc, VCARD_ALICE + VCARD_BOB, "friends.VCF");
        assert (doc.contacts.length == 2);
        assert (doc.contacts[0].name == "Alice <&>");
        assert (doc.contacts[1].address == "bob@example.org");
        assert (doc.has_email_contacts);
        var phone = yield VcardDocument.from_contents (rpc, VCARD_PHONE, "phone.vcf");
        assert (phone.contacts.length == 1);
        assert (phone.contacts[0].name == "Phone Contact");
        assert (phone.contacts[0].address == "");
        assert (!phone.has_email_contacts);
        assert (phone.contents == VCARD_PHONE);
        var name_only = yield VcardDocument.from_contents (rpc, VCARD_NAME);
        assert (name_only.contacts.length == 1);
        assert (name_only.contacts[0].name == "Name Only");
        assert (!name_only.has_email_contacts);
        var mixed = yield VcardDocument.from_contents (rpc, VCARD_PHONE + VCARD_ALICE + VCARD_NAME);
        assert (mixed.contacts.length == 3);
        assert (mixed.contacts[0].name == "Phone Contact");
        assert (mixed.contacts[1].address == "alice@example.org");
        assert (mixed.contacts[2].name == "Name Only");
        assert (mixed.has_email_contacts);
        var after = yield rpc.get_contact_ids_for (source, null);
        assert (before.get_length () == after.get_length ());

        // Saving/sharing a card must retain fields that core's preview metadata
        // does not expose, including phone numbers.
        snapshot = phone.write_temp ();
        var saved_phone = yield VcardDocument.load (rpc, File.new_for_path (snapshot));
        assert (saved_phone.contents == VCARD_PHONE);
        assert (saved_phone.contacts[0].name == "Phone Contact");
        FileUtils.unlink (snapshot);
        snapshot = doc.write_temp ();
        var loaded = yield VcardDocument.load (rpc, File.new_for_path (snapshot));
        assert (loaded.contents == doc.contents);
        FileUtils.set_contents (snapshot, "not a vcard");
        // Import the reviewed contents, even if the file was replaced.
        rpc.account_id = destination;
        var ids = yield rpc.import_vcard_contents (source, loaded.contents);
        assert (ids.get_length () == 2);
        var again = yield rpc.import_vcard_contents (source, loaded.contents);
        assert (again.get_int_element (0) == ids.get_int_element (0));
        var mixed_ids = yield rpc.import_vcard_contents (source, mixed.contents);
        assert (mixed_ids.get_length () == 1);
        assert (mixed_ids.get_int_element (0) == ids.get_int_element (0));
        var other_contacts = yield rpc.get_contact_ids_for (destination, null);
        assert (other_contacts.get_length () == 0);
        string exported = yield rpc.make_vcard (source, { (int) ids.get_int_element (0) });
        var roundtrip = yield VcardDocument.from_contents (rpc, exported);
        assert (roundtrip.contacts.length == 1);
        assert (roundtrip.contacts[0].address == "alice@example.org");
        assert (roundtrip.contacts[0].name == "Alice <&>");
        var keyed = yield VcardDocument.load (rpc, File.new_for_path (fixture));
        var own_ids = yield rpc.import_vcard_contents (destination, keyed.contents);
        assert (own_ids.get_length () == 1);
        string forwarded_card = yield rpc.make_vcard (destination, { (int) own_ids.get_int_element (0) });
        var own_document = yield VcardDocument.from_contents (rpc, forwarded_card);
        assert (own_document.contacts[0].address == "vcard@example.org");
        assert (forwarded_card.contains ("KEY"));
        FileUtils.set_contents (snapshot, forwarded_card);
        var original_key = yield rpc.parse_vcard (fixture);
        var exported_key = yield rpc.parse_vcard (snapshot);
        assert (original_key.get_object_element (0).get_string_member ("key")
            == exported_key.get_object_element (0).get_string_member ("key"));
        FileUtils.unlink (snapshot);
        snapshot = roundtrip.write_temp ();
        rpc.account_id = source;
        var draft = new Message ();
        draft.file_path = snapshot;
        draft.file_name = "contact.vcf";
        draft.view_type = AttachmentTypes.infer_outgoing_view_type (snapshot);
        draft.vcard_contact = roundtrip.contacts[0];
        assert (draft.is_vcard ());

        foreach (string invalid in new string[] { "", "garbage", "BEGIN:VCARD\nVERSION:4.0\nFN:Unfinished card" }) {
            bool rejected = false;
            try { yield VcardDocument.from_contents (rpc, invalid); }
            catch (Error e) { rejected = true; }
            assert (rejected);
        }
        FileUtils.set_data (snapshot, { 0xff, 0xfe, 0 });
        bool rejected_utf8 = false;
        try { yield VcardDocument.load (rpc, File.new_for_path (snapshot)); }
        catch (IOError.INVALID_DATA e) { rejected_utf8 = true; }
        assert (rejected_utf8);
        FileUtils.set_data (snapshot, new uint8[VcardDocument.MAX_BYTES + 1]);
        bool rejected_large = false;
        try { yield VcardDocument.load (rpc, File.new_for_path (snapshot)); }
        catch (IOError.INVALID_DATA e) { rejected_large = true; }
        assert (rejected_large);

        if (ui) {
            FileUtils.set_contents (snapshot, exported);
            var pixbuf = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, 96, 96);
            pixbuf.fill (0x44aa88ff);
            uint8[] png;
            pixbuf.save_to_buffer (out png, "png");
            var obj = new Json.Object ();
            obj.set_string_member ("addr", "alice@example.org");
            obj.set_string_member ("displayName", "Alice <&>");
            obj.set_string_member ("profileImage", Base64.encode (png));
            draft.vcard_contact = new VcardContact (obj);
            var texture = VcardPreview.thumbnail (draft.vcard_contact);
            assert (texture != null && texture.width <= 72 && texture.height <= 72);
            foreach (var style in new MessageStyle[] { MessageStyle.BUBBLES, MessageStyle.IRC, MessageStyle.WORKSPACE }) {
                MessageRow.style = style;
                var row = new MessageRow (draft);
                var preview = search_widget (row, typeof (VcardPreview));
                assert (preview != null);
                assert (search_widget (preview, typeof (Gtk.Label), "Alice <&>") != null);
                var window = new Gtk.Window ();
                window.set_default_size (360, 180);
                window.child = row;
                window.present ();
                yield nap (250);
                assert (preview.get_width () <= window.get_width ());
                audio_screenshot (window, "vcard-" + style.to_string () + ".png");
                window.destroy ();

                var phone_msg = new Message ();
                phone_msg.file_path = snapshot;
                phone_msg.file_name = "phone.vcf";
                phone_msg.vcard_contact = phone.contacts[0];
                var phone_row = new MessageRow (phone_msg);
                var phone_preview = search_widget (phone_row, typeof (VcardPreview));
                assert (phone_preview != null);
                assert (search_widget (phone_preview, typeof (Gtk.Label), "Phone Contact") != null);
                assert (search_widget (phone_preview, typeof (Gtk.Label), "vCard contact") != null);
                assert (phone_preview.tooltip_text == "Phone Contact");
            }
            var composer = new ComposeBar ();
            composer.configure_contacts (rpc, source);
            var host = new Gtk.Window ();
            host.child = composer;
            host.present ();
            composer.set_pending_attachment (snapshot, "contact.vcf");
            for (int i = 0; i < 100 && search_widget (composer, typeof (Gtk.Label), "Alice <&>") == null; i++)
                yield nap (10);
            assert (search_widget (composer, typeof (Gtk.Label), "Alice <&>") != null);
            yield nap (250);
            audio_screenshot (host, "vcard-composer.png");
            composer.set_pending_attachment (snapshot, "second.vcf");
            assert (search_widget (composer, typeof (VcardPreview)) == null);
            composer.cancel_active_mode ();
            FileUtils.set_contents (snapshot, VCARD_PHONE);
            composer.set_pending_attachment (snapshot, "phone.vcf");
            for (int i = 0; i < 100 && search_widget (composer, typeof (Gtk.Label), "Phone Contact") == null; i++)
                yield nap (10);
            assert (search_widget (composer, typeof (Gtk.Label), "Phone Contact") != null);
            audio_screenshot (host, "vcard-phone-composer.png");
            composer.close ();
            host.destroy ();
        }
        stdout.printf ("vCard parse, cards without email, mixed cards, preview without import, multi-contact import, deduplication, account isolation, export, public-key preservation, invalid files%s: PASS\n", ui ? ", thumbnails and composer" : "");
        yield rpc.stop_gracefully ();
    } catch (Error e) {
        error ("vCard integration: %s", e.message);
    } finally {
        if (snapshot != null) FileUtils.unlink (snapshot);
        rpc.stop ();
    }
}

public int run_vcard_core_test (string server, string fixture, bool ui) {
    if (ui) Adw.init ();
    var loop = new MainLoop ();
    check_vcard_core.begin (server, fixture, ui, () => { loop.quit (); });
    loop.run ();
    return 0;
}
