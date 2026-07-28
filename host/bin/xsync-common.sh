#!/usr/bin/bash
# xsync — shared helpers for host-side scripts.
# Sourced, not executed.

set -o pipefail

XSYNC_ROOT="${XSYNC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
XSYNC_CONF="${XSYNC_CONF:-$XSYNC_ROOT/config/xsync.conf}"

if [[ -r "$XSYNC_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$XSYNC_CONF"
else
    echo "xsync: config not found at $XSYNC_CONF" >&2
    exit 78   # EX_CONFIG
fi

: "${XSYNC_STATE_DIR:=/run/xsync}"
: "${XSYNC_LOG:=/var/log/xsync/xsync.log}"

# The game id that means "do guest maintenance" rather than "launch a game".
# Defined here so xsync-session and library.py cannot disagree about it.
: "${XSYNC_MAINTENANCE_ID:=xsync-maintenance}"

# The desktop user's primary group.
#
# setpriv needs a GID, and the config only carries a UID -- so the callers were
# passing the UID as the GID too. That is true on most single-user desktops and
# is not guaranteed anywhere. Where it is false, the library sync writes
# shortcuts.vdf and the artwork grid under the wrong group, which is exactly the
# "files Steam can no longer rewrite" failure that dropping privileges exists to
# avoid. Look it up instead of assuming, and only fall back to the UID if the
# lookup fails.
if [[ -z "${XSYNC_GID:-}" ]]; then
    if [[ -n "${XSYNC_USER:-}" ]]; then
        XSYNC_GID="$(id -g "$XSYNC_USER" 2>/dev/null || true)"
    fi
    : "${XSYNC_GID:=${XSYNC_UID:-}}"
fi

mkdir -p "$XSYNC_STATE_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$XSYNC_LOG")" 2>/dev/null || true

# Only log to file if we can actually write there. Testing once up front avoids
# bash emitting a redirect error on every single log line when running
# unprivileged before `xsync-setup install` has created /var/log/xsync.
# Note the redirection order: 2>/dev/null must come first, otherwise bash reports
# the failed append to the *current* stderr before the suppression takes effect.
if : 2>/dev/null >>"$XSYNC_LOG"; then
    XSYNC_LOG_TO_FILE=1
else
    XSYNC_LOG_TO_FILE=0
fi

# ---------------------------------------------------------------- logging

_log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    echo "$line" >&2
    if (( XSYNC_LOG_TO_FILE )); then
        echo "$line" >>"$XSYNC_LOG" 2>/dev/null || true
    fi
}

log()   { _log INFO  "$@"; }
warn()  { _log WARN  "$@"; }
error() { _log ERROR "$@"; }
die()   { error "$@"; exit 1; }

# Record the current phase so a recovery tool can tell where things stopped.
set_phase() {
    echo "$1" >"$XSYNC_STATE_DIR/phase" 2>/dev/null || true
    log "phase: $1"
}
get_phase() { cat "$XSYNC_STATE_DIR/phase" 2>/dev/null || echo IDLE; }

need_root() {
    [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 $*)"
}

# Retry a command a few times with a short backoff.
# usage: retry <attempts> <command...>
retry() {
    local attempts="$1"; shift
    local n=1
    until "$@"; do
        if (( n >= attempts )); then
            return 1
        fi
        warn "attempt $n/$attempts failed: $* — retrying"
        sleep 1
        (( n++ ))
    done
    return 0
}

# ---------------------------------------------------------------- pci helpers

# Is any xsync session unit alive right now?
#
# The state to match is active,activating -- NOT active.
#
# xsync-session@.service is Type=oneshot with RemainAfterExit=no, so for the
# entire multi-hour life of a play session systemd reports it as
# ActiveState=activating / SubState=start. It is never once "active", and it is
# "deactivating" for the whole of ExecStopPost afterwards. A --state=active
# query therefore returns nothing at every point in a session's life.
#
# This was got wrong today in two places at once, and in both the wrong answer
# was the dangerous one: the guard that stops xsync-recover tearing down a live
# game, and the guard that stops uninstall deleting the running orchestrator.
# Both looked correct, both were dead code. One implementation, used by both.
# Third state: deactivating. The comment above already named it -- a session unit
# is deactivating for the whole of ExecStopPost, and ExecStopPost IS xsync-recover
# -- and round 2 still stopped one state short. That left a 120-215s window where
# a live recovery was invisible to the very guards meant to see it.
#
# The pattern is a parameter so a test can drive the real function instead of
# re-implementing the systemctl call beside it, which is how the round-2 test
# managed to pass against the broken predicate.
session_unit_live() {
    local pattern="${1:-xsync-session@*.service}"
    systemctl list-units "$pattern" --state=active,activating,deactivating \
        --no-legend 2>/dev/null | grep -q .
}

pci_driver() {
    # Current kernel driver bound to a PCI address, or "none".
    local addr="$1" path
    path="/sys/bus/pci/devices/$addr/driver"
    if [[ -L "$path" ]]; then
        basename "$(readlink -f "$path")"
    else
        echo none
    fi
}

pci_exists() {
    [[ -d "/sys/bus/pci/devices/$1" ]]
}

# All PCI addresses xsync hands to the VM.
#
# The GPU and its audio function, plus optionally a whole USB controller. The
# controller is passed as a PCI device rather than attaching individual USB
# devices because the Xbox dongle resets on every USB hostdev attach, taking a
# new device number each time and leaving libvirt's recorded address stale.
gpu_devices() {
    echo "$XSYNC_GPU_PCI"
    [[ -n "${XSYNC_GPU_AUDIO_PCI:-}" ]] && echo "$XSYNC_GPU_AUDIO_PCI"
    [[ -n "${XSYNC_USB_PCI:-}" ]] && echo "$XSYNC_USB_PCI"
}
