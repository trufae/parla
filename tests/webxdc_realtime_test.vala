using Dc;
using Dc.Webxdc;

public int run_fake_realtime_server () {
    var calls = new Json.Array ();
    string hold = "";
    string fail = "";
    string? held = null;
    bool link_peers = false;
    string page = "<!doctype html><script src='webxdc.js'></script>";
    int64 event_request = 0;
    var events = new Queue<Json.Object> ();
    string? line;
    while ((line = stdin.read_line ()) != null) {
        var req = object_from_json (line);
        string method = req.get_string_member ("method");
        var args = req.get_array_member ("params");
        var result = new Json.Node (Json.NodeType.NULL);
        if (method.has_prefix ("send_webxdc_") || method == "leave_webxdc_realtime")
            calls.add_object_element (req);
        switch (method) {
        case "get_system_info": result.init_object (new Json.Object ()); break;
        case "get_webxdc_info":
            result.init_object (object_from_json ("{\"name\":\"Realtime test\",\"selfAddr\":\"fixture\"}"));
            break;
        case "get_full_chat_by_id":
            result.init_object (object_from_json ("{\"name\":\"Test chat\"}"));
            break;
        case "get_config": result.init_string ("Fixture"); break;
        case "get_webxdc_blob":
            result.init_string (Base64.encode (page.data));
            break;
        case "test_page": page = args.get_string_element (0); break;
        case "send_webxdc_status_update": break;
        case "test_link": link_peers = true; break;
        case "get_next_event":
            assert (event_request == 0);
            event_request = req.get_int_member ("id");
            break;
        case "test_event": events.push_tail (args.get_object_element (0)); break;
        case "test_calls": result.init_array (calls); break;
        case "test_hold": hold = args.get_string_element (0); break;
        case "test_fail": fail = args.get_string_element (0); break;
        case "test_release":
            assert (held != null);
            stdout.printf ("%s\n", held);
            held = null;
            hold = "";
            break;
        case "send_webxdc_realtime_data":
            if (link_peers) {
                var ev = new Json.Object ();
                ev.set_string_member ("kind", "WebxdcRealtimeData");
                ev.set_int_member ("msgId", args.get_int_element (1));
                ev.set_array_member ("data", args.get_array_element (2));
                var context = new Json.Object ();
                context.set_int_member ("contextId", args.get_int_element (0) == 1 ? 2 : 1);
                context.set_object_member ("event", ev);
                events.push_tail (context);
            }
            break;
        case "send_webxdc_realtime_advertisement":
        case "leave_webxdc_realtime":
            break;
        default: error ("Unexpected realtime RPC: %s", method);
        }
        if (event_request != 0 && !events.is_empty ()) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (events.pop_head ());
            stdout.printf ("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}\n",
                event_request.to_string (), Json.to_string (node, false));
            event_request = 0;
        }
        if (method != "get_next_event") {
            var response = new Json.Object ();
            response.set_string_member ("jsonrpc", "2.0");
            response.set_int_member ("id", req.get_int_member ("id"));
            if (method == fail) {
                fail = "";
                response.set_object_member ("error", object_from_json (
                    "{\"code\":-32000,\"message\":\"Offline\"}"));
            } else {
                response.set_member ("result", result);
            }
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (response);
            string reply = Json.to_string (node, false);
            if (method == hold) held = reply;
            else stdout.printf ("%s\n", reply);
        }
        stdout.flush ();
    }
    return 0;
}

private async Json.Array realtime_calls (RpcClient rpc, uint count) throws Error {
    for (int i = 0; i < 100; i++) {
        var result = yield rpc.call ("test_calls", Params.begin ().build ());
        if (result.get_array ().get_length () >= count) return result.get_array ();
        yield nap (10);
    }
    error ("Expected %u realtime calls", count);
}

private async void finish_realtime (RealtimeSession session) {
    session.close ();
    for (int i = 0; i < 100 && !session.finished; i++) yield nap (10);
    assert (session.finished);
}

private async void check_webxdc_realtime () {
    var rpc = new RpcClient ();
    try {
        yield rpc.start ({ test_executable, "--fake-realtime" });
        rpc.account_id = 1;
        var session = new RealtimeSession (rpc, 1, 100);
        var other = new RealtimeSession (rpc, 2, 100);
        assert (session.join ("one"));
        assert (!session.join ("duplicate"));
        assert (other.join ("two"));
        yield realtime_calls (rpc, 2);
        var payload = object_from_json ("{\"data\":[0,127,128,255]}").get_member ("data");
        assert (!session.send ("stale", payload));
        assert (session.send ("one", payload));
        var calls = yield realtime_calls (rpc, 3);
        assert (calls.get_object_element (2).get_string_member ("method") == "send_webxdc_realtime_data");
        var params = calls.get_object_element (2).get_array_member ("params");
        assert (params.get_int_element (0) == 1 && params.get_int_element (1) == 100);
        assert (params.get_array_element (2).get_int_element (3) == 255);

        // Exercise actual EventHandler routing before its foreground filter.
        uint received = 0;
        session.data_received.connect ((id, data) => {
            assert (id == "one" && data.get_int_element (3) == 255);
            received++;
        });
        other.data_received.connect (() => { assert_not_reached (); });
        var handler = new EventHandler (rpc);
        handler.start.begin ();
        rpc.account_id = 2;
        var event = object_from_json ("{\"contextId\":1,\"event\":{\"kind\":\"WebxdcRealtimeData\",\"msgId\":100,\"data\":[0,127,128,255]}}");
        var array = new Json.Array ();
        array.add_object_element (event);
        var event_params = new Json.Node (Json.NodeType.ARRAY);
        event_params.set_array (array);
        yield rpc.call ("test_event", event_params);
        for (int i = 0; i < 100 && received == 0; i++) yield nap (10);
        assert (received == 1);
        var data_event = event.get_object_member ("event");
        assert (!RealtimeSession.route_event (new RpcClient (), 1, "WebxdcRealtimeData", data_event));
        assert (!RealtimeSession.route_event (rpc, 3, "WebxdcRealtimeData", data_event));
        assert (RealtimeSession.route_event (rpc, 1, "WebxdcRealtimeAdvertisementReceived", data_event));
        assert ((yield realtime_calls (rpc, 3)).get_length () == 3);

        // An in-flight send finishes before leave; queued sends are dropped.
        yield rpc.call ("test_hold", Params.begin ().add_string ("send_webxdc_realtime_data").build ());
        assert (session.send ("one", payload));
        yield realtime_calls (rpc, 4);
        assert (session.send ("one", payload));
        session.close ();
        assert (!session.send ("one", payload) && !session.join ("late"));
        assert (!RealtimeSession.route_event (rpc, 1, "WebxdcRealtimeAdvertisementReceived", data_event));
        var reopened = new RealtimeSession (rpc, 1, 100);
        assert (reopened.join ("reopened"));
        assert ((yield realtime_calls (rpc, 4)).get_length () == 4);
        yield rpc.call ("test_release", Params.begin ().build ());
        calls = yield realtime_calls (rpc, 6);
        assert (calls.get_object_element (4).get_string_member ("method") == "leave_webxdc_realtime");
        assert (calls.get_object_element (5).get_string_member ("method") == "send_webxdc_realtime_advertisement");
        assert (calls.get_object_element (5).get_array_member ("params").get_int_element (0) == 1);
        yield finish_realtime (reopened);
        yield finish_realtime (other);
        assert (session.finished);

        // Close while joining; no queued data may recreate the channel.
        yield rpc.call ("test_hold", Params.begin ().add_string ("send_webxdc_realtime_advertisement").build ());
        var joining = new RealtimeSession (rpc, 1, 101);
        assert (joining.join ("joining"));
        yield realtime_calls (rpc, 9);
        joining.send ("joining", payload);
        joining.close ();
        yield rpc.call ("test_release", Params.begin ().build ());
        yield finish_realtime (joining);
        calls = yield realtime_calls (rpc, 10);
        assert (calls.get_object_element (9).get_string_member ("method") == "leave_webxdc_realtime");

        // A failed join closes the JS handle and still leaves core's gossip.
        yield rpc.call ("test_fail", Params.begin ().add_string ("send_webxdc_realtime_advertisement").build ());
        var failed = new RealtimeSession (rpc, 1, 102);
        bool failure_seen = false;
        failed.channel_failed.connect ((id, message) => {
            assert (id == "failed" && message.contains ("Offline"));
            failure_seen = true;
        });
        failed.join ("failed");
        yield realtime_calls (rpc, 12);
        assert (failure_seen && !failed.send ("failed", payload));
        yield finish_realtime (failed);
        var unused = new RealtimeSession (rpc, 1, 103);
        yield finish_realtime (unused);
        assert ((yield realtime_calls (rpc, 12)).get_length () == 12);

        // The JS contract allows a new handle after leave, but core must
        // finish the old leave before the new advertisement or payload.
        var rejoin = new RealtimeSession (rpc, 1, 100);
        rejoin.join ("old");
        yield realtime_calls (rpc, 13);
        yield rpc.call ("test_hold", Params.begin ().add_string ("leave_webxdc_realtime").build ());
        rejoin.leave ("old");
        yield realtime_calls (rpc, 14);
        assert (rejoin.join ("new"));
        assert (rejoin.send ("new", payload));
        assert (!rejoin.send ("old", payload));
        rejoin.leave ("old");
        assert (!RealtimeSession.route_event (rpc, 1, "WebxdcRealtimeData", data_event));
        assert ((yield realtime_calls (rpc, 14)).get_length () == 14);
        yield rpc.call ("test_release", Params.begin ().build ());
        calls = yield realtime_calls (rpc, 16);
        assert (calls.get_object_element (14).get_string_member ("method") == "send_webxdc_realtime_advertisement");
        assert (calls.get_object_element (15).get_string_member ("method") == "send_webxdc_realtime_data");
        yield finish_realtime (rejoin);
    } catch (Error e) { error ("Realtime regression: %s", e.message); }
    rpc.stop ();
}

public void test_webxdc_realtime () {
    var loop = new MainLoop ();
    check_webxdc_realtime.begin (() => { loop.quit (); });
    loop.run ();
}

public void test_webxdc_realtime_bytes () {
    foreach (string invalid in new string[] {
        "null", "{}", "\"bytes\"", "[256]", "[-1]", "[1.5]", "[true]", "[null]", "[[]]"
    }) {
        var obj = object_from_json ("{\"data\":%s}".printf (invalid));
        assert (RealtimeSession.parse_data (obj.get_member ("data")) == null);
    }
    var data = new Json.Array ();
    var node = new Json.Node (Json.NodeType.ARRAY);
    node.set_array (data);
    assert (RealtimeSession.parse_data (node).get_size () == 0);
    for (int i = 0; i < RealtimeSession.MAX_DATA; i++) data.add_int_element (i % 256);
    assert (RealtimeSession.parse_data (node).get_size () == RealtimeSession.MAX_DATA);
    data.add_int_element (0);
    assert (RealtimeSession.parse_data (node) == null);
}
