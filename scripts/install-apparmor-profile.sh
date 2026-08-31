#!/bin/sh
set -eu

profile=$1
destdir=${DESTDIR:-}

# A staged install is building a native package: include the policy in the
# package, but never try to load it into the build host's kernel.
if [ -n "$destdir" ]; then
    target="$destdir/etc/apparmor.d/parla"
    install -d "${target%/*}"
    install -m 0644 "$profile" "$target"
    exit 0
fi

# AppArmor is optional. On other Linux systems WebKitGTK's sandbox works
# without this policy, so do not create an unused /etc/apparmor.d directory.
# Only Ubuntu's opt-in userns restriction needs this policy. AppArmor systems
# without that kernel knob should not receive a profile they do not need.
if [ ! -r /sys/module/apparmor/parameters/enabled ] \
        || ! grep -q '^Y' /sys/module/apparmor/parameters/enabled \
        || [ ! -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] \
        || ! grep -q '^1' \
            /proc/sys/kernel/apparmor_restrict_unprivileged_userns \
        || ! command -v apparmor_parser >/dev/null 2>&1; then
    exit 0
fi

target=/etc/apparmor.d/parla
install -d "${target%/*}"
install -m 0644 "$profile" "$target"
apparmor_parser --replace "$target"
echo "Installed and loaded AppArmor policy for WebKitGTK: $target"
