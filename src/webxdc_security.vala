namespace Dc.WebxdcSecurity {

    /* Missing settings and the one-tap reset both resolve to these values. */
    public const bool SAFE_ALLOW_INTERNET = false;
    public const bool SAFE_ALLOW_WASM = false;
    public const bool SAFE_ALLOW_WEBGL = false;
    public const bool SAFE_ALLOW_HARDWARE_ACCELERATION = false;
    public const bool SAFE_DEVELOPER_TOOLS = false;

    /* Keep ordinary inline/archive scripts working while withholding both
       JavaScript eval and the CSP token which authorizes Wasm compilation. */
    public const string NO_WASM_CSP =
        "script-src 'self' 'unsafe-inline' data: blob: http: https:";

    public string? wasm_csp (bool allow_wasm) {
        return allow_wasm ? null : NO_WASM_CSP;
    }
}
