#pragma once
#import <Security/Security.h>

// Call only after validating the code signature. Both static and running code
// objects are accepted by SecCodeCopySigningInformation.
static inline OSStatus parla_webxdc_require_sandbox (SecCodeRef code)
{
    CFDictionaryRef info = NULL;
    OSStatus status = SecCodeCopySigningInformation (code, kSecCSSigningInformation, &info);
    if (status != errSecSuccess) return status;
    CFTypeRef entitlements = CFDictionaryGetValue (info, kSecCodeInfoEntitlementsDict);
    if (!entitlements || CFGetTypeID (entitlements) != CFDictionaryGetTypeID () ||
        CFDictionaryGetValue ((CFDictionaryRef)entitlements,
            CFSTR("com.apple.security.app-sandbox")) != kCFBooleanTrue)
        status = errSecCSReqFailed;
    CFRelease (info);
    return status;
}
