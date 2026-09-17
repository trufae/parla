#!/bin/sh
# Fetch pinned upstream sources; an interrupted download never becomes a cache hit.
set -eu
cd "$(dirname "$0")/.."
mkdir -p rpm
while read -r sha file url; do
    case "$sha" in ''|'#'*) continue ;; esac
    if (cd rpm && printf '%s  %s\n' "$sha" "$file" | sha256sum -c - >/dev/null 2>&1); then
        echo "have $file"
        continue
    fi
    curl -fLsS --retry 4 --retry-delay 2 -o "rpm/$file.part" "$url"
    printf '%s  %s\n' "$sha" "rpm/$file.part" | sha256sum -c -
    mv "rpm/$file.part" "rpm/$file"
done < sources.lock
