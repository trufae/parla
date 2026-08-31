using Dc;

private void test_safest_defaults () {
    assert (!WebxdcSecurity.SAFE_ALLOW_INTERNET);
    assert (!WebxdcSecurity.SAFE_ALLOW_WASM);
    assert (!WebxdcSecurity.SAFE_ALLOW_WEBGL);
    assert (!WebxdcSecurity.SAFE_ALLOW_HARDWARE_ACCELERATION);
    assert (!WebxdcSecurity.SAFE_DEVELOPER_TOOLS);
}

private void test_wasm_csp () {
    var blocked = WebxdcSecurity.wasm_csp (false);
    assert (blocked != null);
    assert (!blocked.contains ("'unsafe-eval'"));
    assert (!blocked.contains ("'wasm-unsafe-eval'"));
    assert (WebxdcSecurity.wasm_csp (true) == null);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/webxdc-security/safest-defaults", test_safest_defaults);
    Test.add_func ("/webxdc-security/wasm-csp", test_wasm_csp);
    return Test.run ();
}
