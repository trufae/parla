namespace Dc {

    // Keep unfamiliar durations exact, including Core's full uint32 range.
    public string ephemeral_duration (int64 seconds) {
        if (seconds <= 0) return _("Off");
        if (seconds % 604800 == 0)
            return ngettext ("%s week", "%s weeks", (ulong) (seconds / 604800))
                .printf ((seconds / 604800).to_string ());
        if (seconds % 86400 == 0)
            return ngettext ("%s day", "%s days", (ulong) (seconds / 86400))
                .printf ((seconds / 86400).to_string ());
        if (seconds % 3600 == 0)
            return ngettext ("%s hour", "%s hours", (ulong) (seconds / 3600))
                .printf ((seconds / 3600).to_string ());
        if (seconds % 60 == 0)
            return ngettext ("%s minute", "%s minutes", (ulong) (seconds / 60))
                .printf ((seconds / 60).to_string ());
        return ngettext ("%s second", "%s seconds", (ulong) seconds)
            .printf (seconds.to_string ());
    }
}
