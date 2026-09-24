namespace Dc {

    internal uint8[] decode_rpc_blob (string blob) {
        // Core uses STANDARD_NO_PAD; GLib drops an unpadded final group.
        int rem = blob.length % 4;
        if (rem == 2) return Base64.decode (blob + "==");
        if (rem == 3) return Base64.decode (blob + "=");
        return Base64.decode (blob);
    }
}
