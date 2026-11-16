using Dc;

public int run_realtime_settings_test () {
    assert (Environment.get_variable ("PARLA_TEST_CONFIG") == Environment.get_user_config_dir ());
    var settings = new SettingsManager ();
    settings.load ();
    assert (settings.webxdc_realtime);
    assert (!settings.webxdc_allow_internet);
    settings.save_webxdc_realtime (false);
    var restored = new SettingsManager ();
    restored.load ();
    assert (!restored.webxdc_realtime && !restored.webxdc_allow_internet);
    restored.save_webxdc_realtime (true);
    settings.load ();
    assert (settings.webxdc_realtime && !settings.webxdc_allow_internet);
    stdout.printf ("Realtime enabled by default, persisted opt-out, separate internet policy: PASS\n");
    return 0;
}

#if WEBXDC
// The page drives its own JS. Tests observe the public broker/core boundary,
// so the same contract runs with every real sandbox and native web engine.
private async void wait_status (RpcClient rpc, int account, string payload) throws Error {
    for (int i = 0; i < 1000; i++) {
        var result = yield rpc.call ("test_calls", Params.begin ().build ());
        foreach (var node in result.get_array ().get_elements ()) {
            var call = node.get_object ();
            if (call.get_string_member ("method") != "send_webxdc_status_update") continue;
            var args = call.get_array_member ("params");
            if (args.get_int_element (0) == account && args.get_string_element (2).contains (payload)) return;
        }
        yield nap (20);
    }
    error ("Missing sandboxed app status %s for profile %d", payload, account);
}

private async void check_realtime_ui () {
    var rpc = new RpcClient ();
    var settings = new SettingsManager ();
    settings.load ();
    try {
        yield rpc.start ({ test_executable, "--fake-realtime" });
        rpc.account_id = 1;
        Webxdc.setup (rpc, settings);
        var handler = new EventHandler (rpc);
        handler.start.begin ();
        yield rpc.call ("test_link", Params.begin ().build ());
        string page = """<!doctype html><script src='webxdc.js'></script><script>
if (webxdc.joinRealtimeChannel) {
  const c = webxdc.joinRealtimeChannel();
  let received = false;
  const timer = setInterval(() => c.send(new Uint8Array([0,127,128,255])), 100);
  c.setListener(data => {
    if (data.length === 128000 && data.every(byte => byte === 255)) {
      webxdc.sendUpdate({payload: 'maximum-packet'}, '');
      return;
    }
    if (received) return;
    received = true;
    clearInterval(timer);
    c.send(new Uint8Array([0,127,128,255]));
    c.send(new Uint8Array(128000).fill(255));
    webxdc.sendUpdate({payload: {received: Array.from(data)}}, '');
  });
  webxdc.sendUpdate({payload: 'ready'}, '');
} else {
  webxdc.sendUpdate({payload: 'disabled'}, '');
  window.webkit.messageHandlers.webxdc.postMessage(JSON.stringify({type:'realtime-join',channel:'bypass'}));
}
</script>""";
        yield rpc.call ("test_page", Params.begin ().add_string (page).build ());
        var msg = new Message ();
        msg.id = 100; msg.chat_id = 10; msg.file_name = "realtime.xdc";
        Webxdc.open (null, rpc, msg);
        rpc.account_id = 2;
        Webxdc.open (null, rpc, msg);
        yield wait_status (rpc, 1, "ready");
        yield wait_status (rpc, 2, "ready");
        yield wait_status (rpc, 1, "[0,127,128,255]");
        yield wait_status (rpc, 2, "[0,127,128,255]");
        yield wait_status (rpc, 1, "maximum-packet");
        yield wait_status (rpc, 2, "maximum-packet");
        Webxdc.handle_event (rpc, 1, "WebxdcInstanceDeleted", object_from_json ("{\"msgId\":100}"));
        assert (Webxdc.running_apps (1, 10).length == 0);
        assert (Webxdc.is_running (100));
        settings.save_webxdc_realtime (false);
        for (int i = 0; i < 100 && Webxdc.is_running (100); i++) yield nap (10);
        assert (!Webxdc.is_running (100));
        var previous = yield rpc.call ("test_calls", Params.begin ().build ());
        uint before = previous.get_array ().get_length ();
        Webxdc.open (null, rpc, msg);
        yield wait_status (rpc, 2, "disabled");
        yield nap (100);
        var after = yield rpc.call ("test_calls", Params.begin ().build ());
        for (uint i = before; i < after.get_array ().get_length (); i++) {
            assert (after.get_array ().get_object_element (i).get_string_member ("method")
                != "send_webxdc_realtime_advertisement");
        }
        settings.save_webxdc_apps (false);
        for (int i = 0; i < 100 && Webxdc.is_running (100); i++) yield nap (10);
        assert (!Webxdc.is_running (100));
        stdout.printf ("Sandboxed apps exchange binary data; profile isolation and policy revocation: PASS\n");
    } catch (Error e) { error ("Realtime UI: %s", e.message); }
    rpc.stop ();
}

public int run_realtime_ui_test () {
    Adw.init ();
    var loop = new MainLoop ();
    check_realtime_ui.begin (() => { loop.quit (); });
    loop.run ();
    return 0;
}
#endif
