using Dc.Webxdc;

[CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_sandbox_launch")]
private extern void* launch (string helper, bool internet, bool acceleration, bool wasm, out InputStream input, out OutputStream output) throws Error;
[CCode (cheader_filename = "webxdc_sandbox.h", cname = "parla_webxdc_sandbox_stop")]
private extern void terminate (void* process);

private async void exercise (string helper, bool internet, bool wasm, MainLoop loop) {
    void* process = null;
    try {
        InputStream input;
        OutputStream output;
        process = launch (helper, internet, false, wasm, out input, out output);
        var wire = new Wire (input, output);
        bool passed = false;
        wire.received.connect ((obj) => {
            try {
                string op = Wire.text (obj, "op");
                stderr.printf ("sandbox: %s\n", op);
                if (op == "ready") {
                    assert (Wire.number (obj, "version") == Wire.VERSION);
                    assert (Wire.flag (obj, "internet") == internet);
                    var policy = Wire.packet ("open");
                    policy.set_string_member ("title", "Webxdc sandbox test");
                    foreach (string name in new string[] { "internet", "wasm", "webgl", "developer", "acceleration" })
                        policy.set_boolean_member (name, false);
                    policy.set_boolean_member ("internet", internet);
                    policy.set_boolean_member ("wasm", wasm);
                    wire.send (policy);
                    var load = Wire.packet ("load");
                    load.set_string_member ("value", "webxdc://app/index.html");
                    wire.send (load);
                    wire.send (Wire.packet ("present"));
                } else if (op == "blob") {
                    assert (Wire.resource_path (Wire.text (obj, "path")));
                    var resource = Wire.packet ("resource");
                    resource.set_int_member ("id", Wire.number (obj, "id"));
                    resource.set_string_member ("mime", "text/html");
                    string page = """<!doctype html><p>Sandbox test</p><script>
(async()=>{
 const send = text => window.webkit.messageHandlers.webxdc.postMessage(text);
 try {
  let compiled = false;
  try { await WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0,0])); compiled = true; } catch(e) {}
  if (compiled !== %s) throw new Error('Wasm policy mismatch');
  if (!%s) {
   let blocked = false;
   addEventListener('securitypolicyviolation', e => { if(e.effectiveDirective === 'connect-src') blocked = true; });
   try { await fetch('https://webxdc-network-test.invalid/'); } catch(e) {}
   await new Promise(resolve => setTimeout(resolve, 100));
   if (!blocked) throw new Error('Missing offline CSP enforcement');
  }
  send('PASS');
 } catch(e) { send(String(e)); }
})();</script>""".printf (wasm.to_string (), internet.to_string ());
                    resource.set_string_member ("data", Base64.encode (page.data));
                    wire.send (resource);
                } else if (op == "message") {
                    string result = Wire.text (obj, "json");
                    if (result != "PASS") error ("Page policy check: %s", result);
                    passed = true;
                    wire.stop ();
                } else assert_not_reached ();
            } catch (Error e) { error ("Sandbox protocol: %s", e.message); }
        });
        wire.ended.connect ((reason) => {
            if (!passed) error ("Sandbox closed: %s", reason ?? "EOF");
        });
        yield wire.read ();
        terminate (process);
        stdout.printf ("Sandbox rendering, CSP, Wasm policy, IPC and closure (internet=%s wasm=%s): PASS\n",
            internet.to_string (), wasm.to_string ());
        loop.quit ();
    } catch (Error e) { error ("Sandbox launch: %s", e.message); }
}

int main (string[] args) {
    if (args.length < 2) return 2;
    var loop = new MainLoop ();
    Timeout.add_seconds (20, () => { stderr.printf ("Sandbox test timed out\n"); Posix.abort (); return Source.REMOVE; });
    exercise.begin (args[1], "--online" in args, "--wasm" in args, loop);
    loop.run ();
    return 0;
}
