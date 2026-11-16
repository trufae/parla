using Dc;

private void test_safest_defaults () {
    assert (!WebxdcSecurity.SAFE_ALLOW_INTERNET);
    assert (!WebxdcSecurity.SAFE_ALLOW_WASM);
    assert (!WebxdcSecurity.SAFE_ALLOW_WEBGL);
    assert (!WebxdcSecurity.SAFE_ALLOW_HARDWARE_ACCELERATION);
    assert (!WebxdcSecurity.SAFE_DEVELOPER_TOOLS);
}

private void test_wasm_csp () {
    string blocked = response_policy (false, false);
    assert (!blocked.contains ("'unsafe-eval'"));
    assert (!blocked.contains ("'wasm-unsafe-eval'"));
    assert (blocked.contains ("connect-src"));
    assert (!blocked.contains ("https:"));
    string wasm = response_policy (false, true);
    assert (wasm.contains ("'wasm-unsafe-eval'"));
    assert (!wasm.contains ("'unsafe-eval'"));
    assert (!wasm.contains ("https:"));
    assert (response_policy (true, false).contains ("https:"));
}

[CCode (cheader_filename = "webxdc_view.h", cname = "parla_webxdc_csp")]
private extern unowned string response_policy (bool internet, bool wasm);

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/webxdc-security/safest-defaults", test_safest_defaults);
    Test.add_func ("/webxdc-security/wasm-csp", test_wasm_csp);
    return Test.run ();
}
