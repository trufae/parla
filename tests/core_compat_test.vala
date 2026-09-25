using Dc;

private Json.Object object_from_json (string text) {
    var parser = new Json.Parser ();
    try { parser.load_from_data (text); }
    catch (Error e) { error ("Invalid fixture: %s", e.message); }
    return parser.get_root ().get_object ();
}

private void test_presence () {
    foreach (string freshness in new string[] {
        "RecentlySeen", "Normal", "Old", "FutureValue"
    }) {
        var obj = object_from_json (
            "{\"freshness\":\"%s\",\"wasSeenRecently\":true}".printf (freshness));
        bool recent = freshness == "RecentlySeen";
        assert (RpcParsers.parse_contact (42, obj).was_seen_recently == recent);
        assert (RpcParsers.parse_chat_item (10, obj).was_seen_recently == recent);
        var message = new Json.Object ();
        message.set_object_member ("sender", obj);
        assert (RpcParsers.parse_message (message).sender_was_seen_recently == recent);
    }

    var legacy = object_from_json ("{\"wasSeenRecently\":true}");
    assert (RpcParsers.parse_contact (42, legacy).was_seen_recently);
    assert (RpcParsers.parse_chat_item (10, legacy).was_seen_recently);
    var absent = new Json.Object ();
    assert (!RpcParsers.parse_contact (42, absent).was_seen_recently);
}

private void test_message_identity () {
    // An account need not expose any address to identify its own messages.
    var self = object_from_json ("{\"fromId\":1}");
    assert (RpcParsers.parse_message (self).is_outgoing);
    var sender = object_from_json (
        "{\"sender\":{\"id\":1,\"address\":\"another@relay.example\"}}");
    assert (RpcParsers.parse_message (sender).is_outgoing);
    var other = object_from_json (
        "{\"fromId\":42,\"sender\":{\"id\":42,\"address\":\"self@relay.example\"}}");
    assert (!RpcParsers.parse_message (other).is_outgoing);
    assert (!RpcParsers.parse_message (new Json.Object ()).is_outgoing);
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/core-compat/presence", test_presence);
    Test.add_func ("/core-compat/message-identity", test_message_identity);
    return Test.run ();
}
