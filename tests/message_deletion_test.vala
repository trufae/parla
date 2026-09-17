using Dc;

private Json.Object parse (string text) {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (text);
    } catch (Error e) {
        error ("Invalid fixture: %s", e.message);
    }
    return parser.get_root ().get_object ();
}

private void selection_scope () {
    // Outgoing, received, unencrypted, system, another chat, and failed load.
    var messages = parse ("""
        {
          "10": {"chatId": 100, "sender": {"id": 1}, "isInfo": false, "showPadlock": true},
          "11": {"chatId": 100, "sender": {"id": 1}, "isInfo": false, "showPadlock": true},
          "12": {"chatId": 100, "sender": {"id": 9}, "isInfo": false, "showPadlock": true},
          "13": {"chatId": 100, "sender": {"id": 1}, "isInfo": false, "showPadlock": false},
          "14": {"chatId": 100, "sender": {"id": 1}, "isInfo": true, "showPadlock": true},
          "15": {"chatId": 200, "sender": {"id": 1}, "isInfo": false, "showPadlock": true},
          "16": {"kind": "loadingError"},
          "17": null
        }
        """);
    assert (MessageDeletion.common_chat (messages, { 10 }) == 100);
    assert (MessageDeletion.common_chat (messages, { 10, 11 }) == 100);
    assert (MessageDeletion.common_chat (messages, {}) == 0);
    foreach (int id in new int[] { 12, 13, 14, 15, 16, 17, 18 }) {
        assert (MessageDeletion.common_chat (messages, { 10, id }) == 0);
        assert (MessageDeletion.common_chat (messages, { id, 10 }) == 0);
    }
}

private void chat_scope () {
    var chat = parse ("""{"canSend": true, "isEncrypted": true, "isSelfTalk": false}""");
    assert (MessageDeletion.can_delete_in_chat (chat));
    chat.set_boolean_member ("canSend", false); // Left group or contact request.
    assert (!MessageDeletion.can_delete_in_chat (chat));
    chat.set_boolean_member ("canSend", true);
    chat.set_boolean_member ("isEncrypted", false);
    assert (!MessageDeletion.can_delete_in_chat (chat));
    chat.set_boolean_member ("isEncrypted", true);
    chat.set_boolean_member ("isSelfTalk", true);
    assert (!MessageDeletion.can_delete_in_chat (chat));
    assert (!MessageDeletion.can_delete_in_chat (new Json.Object ()));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/message-deletion/selection-scope", selection_scope);
    Test.add_func ("/message-deletion/chat-scope", chat_scope);
    return Test.run ();
}
