/** Decode Core's QR module path, excluding its decorative SVG logo.
 * Core performs QR encoding; no graphics or QR library is needed by the CLI. */
internal class CliQr : Object {
    public static string render (string svg, out int columns, out int rows) throws Error {
        columns = rows = 0;
        if (svg.length > 2097152) throw new IOError.INVALID_DATA ("QR image is too large");
        var path = new Regex ("\\bd=\"((?:M[0-9]+,[0-9]+h1v1h-1z)+)\"");
        MatchInfo match;
        if (!path.match (svg, 0, out match))
            throw new IOError.INVALID_DATA ("Unsupported QR image from Core; use the invite link");
        string modules = match.fetch (1);
        var pixel = new Regex ("M([0-9]+),([0-9]+)h1v1h-1z");
        bool[] dark = new bool[177 * 177];
        int size = 0;
        pixel.match (modules, 0, out match);
        do {
            int x = int.parse (match.fetch (1)), y = int.parse (match.fetch (2));
            if (x < 0 || x >= 177 || y < 0 || y >= 177)
                throw new IOError.INVALID_DATA ("Invalid QR dimensions");
            dark[y * 177 + x] = true;
            size = int.max (size, int.max (x, y) + 1);
        } while (match.next ());
        if (size < 21 || (size - 21) % 4 != 0)
            throw new IOError.INVALID_DATA ("Invalid QR module grid");
        // Four-module white quiet zone, two vertical modules per character.
        columns = size + 8;
        rows = (columns + 1) / 2;
        var text = new StringBuilder ();
        for (int y = -4; y < size + 4; y += 2) {
            if (y > -4) text.append_c ('\n');
            for (int x = -4; x < size + 4; x++) {
                bool top = x >= 0 && x < size && y >= 0 && y < size && dark[y * 177 + x];
                bool bottom = x >= 0 && x < size && y + 1 >= 0 && y + 1 < size && dark[(y + 1) * 177 + x];
                text.append (top ? (bottom ? "█" : "▀") : (bottom ? "▄" : " "));
            }
        }
        return text.str;
    }
}
