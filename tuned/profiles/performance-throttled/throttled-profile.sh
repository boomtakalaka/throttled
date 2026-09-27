#!/bin/sh
# TuneD calls this with "start" when the profile is applied and "stop" when it
# is unloaded. The "performance-throttled" TuneD profile maps the PPD
# "performance" profile to throttled.service, so the daemon only runs while
# that power profile is selected.
set -eu

case "${1:-}" in
    start)
        systemctl start throttled.service
        ;;
    stop)
        systemctl stop throttled.service
        ;;
    *)
        echo "usage: $0 {start|stop}" >&2
        exit 2
        ;;
esac
