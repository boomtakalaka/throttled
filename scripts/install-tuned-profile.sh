#!/bin/sh
set -eu
umask 022

# Install a TuneD profile that runs throttled.service only while the
# power-profiles-daemon "performance" profile is active, wire that profile into
# /etc/tuned/ppd.conf, and make sure throttled no longer starts at boot.
#
# Requires tuned + tuned-ppd to be the active power profile provider.

PPD_CONF=/etc/tuned/ppd.conf
TUNED_PROFILE=performance-throttled
TUNED_TARGET=performance
HOOK_NAME=throttled-profile.sh
# TuneD >= 2.x loads user profiles from /etc/tuned/profiles/<name>/tuned.conf.
PROFILE_DIR=$(python3 -c 'import tuned.consts as c; print(c.USER_PROFILES_DIR)' 2>/dev/null \
    || echo /etc/tuned/profiles)

usage() {
    cat <<'EOF'
Usage: sudo scripts/install-tuned-profile.sh

Installs the "performance-throttled" TuneD profile, maps the PPD "performance"
profile to it in /etc/tuned/ppd.conf, then disables throttled.service so the
power profile controls when it runs.

Must be run as root.
EOF
}

restore_ppd_conf() {
    if [ -e "$PPD_CONF.orig" ]; then
        cp -p "$PPD_CONF.orig" "$PPD_CONF"
    else
        sed -i "s|^$TUNED_TARGET=$TUNED_PROFILE\$|$TUNED_TARGET=throughput-performance|" "$PPD_CONF"
    fi
}

patch_ppd_conf() {
    if grep -q "^$TUNED_TARGET=$TUNED_PROFILE\$" "$PPD_CONF"; then
        return 0
    fi
    if ! grep -q "^$TUNED_TARGET=" "$PPD_CONF"; then
        echo "Missing '$TUNED_TARGET=' mapping in $PPD_CONF." >&2
        return 1
    fi
    [ -e "$PPD_CONF.orig" ] || cp -p "$PPD_CONF" "$PPD_CONF.orig"
    sed -i "s|^$TUNED_TARGET=.*|$TUNED_TARGET=$TUNED_PROFILE|" "$PPD_CONF"
}

sync_service() {
    # TuneD only runs the hook when the profile changes, so reconcile the
    # service with whatever profile is active right now.
    if tuned-adm active 2>/dev/null | grep -q "^Current active profile: $TUNED_PROFILE\$"; then
        "$PROFILE_DIR/$TUNED_PROFILE/$HOOK_NAME" start
    else
        "$PROFILE_DIR/$TUNED_PROFILE/$HOOK_NAME" stop
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must run as root." >&2
    usage >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

command -v tuned-adm >/dev/null 2>&1 || {
    echo "tuned is not installed; this setup requires tuned + tuned-ppd." >&2
    exit 1
}

if [ ! -f "$PPD_CONF" ]; then
    echo "$PPD_CONF not found; tuned-ppd does not appear to be configured." >&2
    exit 1
fi

install -d -m 0755 "$PROFILE_DIR/$TUNED_PROFILE"
install -m 0644 "$ROOT_DIR/tuned/profiles/$TUNED_PROFILE/tuned.conf" \
    "$PROFILE_DIR/$TUNED_PROFILE/tuned.conf"
# The hook must live inside the profile directory: TuneD refuses to execute
# scripts outside its profile directories.
install -m 0755 "$ROOT_DIR/tuned/profiles/$TUNED_PROFILE/$HOOK_NAME" \
    "$PROFILE_DIR/$TUNED_PROFILE/$HOOK_NAME"

# Clean up paths used by earlier revisions of this installer.
rm -rf "/etc/tuned/$TUNED_PROFILE"
rm -f /usr/local/bin/"$HOOK_NAME"

# Let TuneD rescan so the new profile is known before tuned-ppd validates it.
systemctl restart tuned
if ! tuned-adm profile_info "$TUNED_PROFILE" >/dev/null 2>&1; then
    echo "TuneD still does not see '$TUNED_PROFILE' in $PROFILE_DIR." >&2
    echo "Restoring $PPD_CONF and restarting tuned-ppd to leave PPD working." >&2
    restore_ppd_conf
    systemctl restart tuned-ppd 2>/dev/null || true
    exit 1
fi

patch_ppd_conf

# Stop throttled from starting at boot; the profile hook owns its lifecycle.
systemctl disable throttled.service 2>/dev/null || true
systemctl restart tuned-ppd
sync_service

echo "Done. Select the 'performance' power profile to start throttled."
echo "Switch to 'balanced' or 'power-saver' to stop it."
echo "throttled.service is now: $(systemctl is-active throttled.service 2>/dev/null || true)"
