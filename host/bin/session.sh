#!/usr/bin/bash
# xsync — stop and restore the host gamescope/Steam session.
#
#   session.sh stop     shut Steam down cleanly, then stop the display manager
#   session.sh start    start the display manager (autologin brings Steam back)
#   session.sh status   report whether the session is up
#
# Steam is asked to exit *gracefully* before the display manager is stopped.
# This matters: Steam rewrites shortcuts.vdf when it exits, so killing it would
# either lose the library sync or have Steam clobber our changes on next launch.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/xsync-common.sh"

STEAM_BIN="${XSYNC_STEAM_ROOT}/ubuntu12_32/steam"

run_as_user() {
    setpriv --reuid="$XSYNC_UID" --regid="$XSYNC_GID" --init-groups \
        env HOME="/var/home/$XSYNC_USER" \
            XDG_RUNTIME_DIR="/run/user/$XSYNC_UID" \
            "$@"
}

steam_running() {
    pgrep -u "$XSYNC_USER" -x steam >/dev/null 2>&1
}

session_stop() {
    need_root
    set_phase STOP_SESSION

    if steam_running; then
        log "asking Steam to shut down cleanly (flushes shortcuts.vdf)"
        run_as_user "$STEAM_BIN" -shutdown >/dev/null 2>&1 || true

        local waited=0
        while steam_running && (( waited < 25 )); do
            sleep 1
            (( waited++ ))
        done
        if steam_running; then
            warn "Steam did not exit after ${waited}s — continuing anyway"
        else
            log "Steam exited cleanly after ${waited}s"
        fi
    else
        log "Steam not running"
    fi

    log "stopping $XSYNC_DISPLAY_MANAGER"
    systemctl stop "$XSYNC_DISPLAY_MANAGER" || warn "failed to stop $XSYNC_DISPLAY_MANAGER"

    # Clear it on the way down too: the session we just ended deliberately would
    # otherwise be recorded as a crash the moment it lasted under a minute.
    clear_short_session_tracker

    # SDDM teardown can leave the gamescope user unit behind; make sure it is gone
    # so nothing is holding the GPU when we try to unbind it.
    if run_as_user systemctl --user is-active "$XSYNC_SESSION_UNIT" >/dev/null 2>&1; then
        warn "$XSYNC_SESSION_UNIT still active — stopping it"
        run_as_user systemctl --user stop "$XSYNC_SESSION_UNIT" || true
    fi

    local waited=0
    while pgrep -x gamescope-wl >/dev/null 2>&1 && (( waited < 10 )); do
        sleep 1
        (( waited++ ))
    done
    if pgrep -x gamescope-wl >/dev/null 2>&1; then
        warn "gamescope still running — killing"
        pkill -KILL -x gamescope-wl 2>/dev/null || true
        sleep 1
    fi

    log "host session stopped"
}

# SteamOS/Bazzite decide which session autologin starts using
# /etc/sddm.conf.d/zz-steamos-autologin.conf. The zz- prefix makes it override
# steamos.conf, and "switch to desktop" writes the Plasma one-shot session there.
#
# That file persists. If it says Plasma when we restart the display manager, the
# user lands on the KDE desktop instead of Big Picture — every single time they
# quit a game. So the session to return to is asserted explicitly rather than
# assumed. This mirrors what /usr/bin/return-to-gamemode does.
ensure_gamescope_session() {
    local conf=/etc/sddm.conf.d/zz-steamos-autologin.conf
    local want=gamescope-session.desktop

    if [[ -f "$conf" ]] && grep -q "Session=$want" "$conf"; then
        log "autologin already set to gaming mode"
        return 0
    fi

    if [[ -f "$conf" ]]; then
        warn "autologin was set to: $(grep -o 'Session=.*' "$conf" | head -1) — forcing gaming mode"
    fi

    # Check the write. This file is how gaming mode comes back, and failing to
    # create it while logging success meant the user landed on the desktop after
    # every game with a log that said otherwise.
    if ! mkdir -p "$(dirname "$conf")" 2>/dev/null; then
        error "could not create $(dirname "$conf") — cannot force gaming mode"
        return 1
    fi
    if ! printf '[Autologin]\nSession=%s\n' "$want" >"$conf" 2>/dev/null; then
        error "could not write $conf — cannot force gaming mode"
        return 1
    fi
    chmod 0644 "$conf" 2>/dev/null || true

    # SDDM also preselects the last-used session from its own state file.
    local state=/var/lib/sddm/state.conf
    if [[ -f "$state" ]] && grep -q 'oneshot' "$state"; then
        sed -i "s|^Session=.*|Session=/usr/share/wayland-sessions/$want|" "$state" 2>/dev/null || true
        log "cleared the one-shot desktop session from sddm state"
    fi

    log "autologin set to gaming mode"
}

# Bazzite's gamescope-session-plus keeps a "short session" tracker at
# /tmp/chimeraos-short-session-tracker. Any session that ends within 60 seconds
# appends a line, and once five accumulate it decides Steam or gamescope is
# broken and deliberately switches the machine to the desktop session
# ("detected broken steam or gamescope failure, will try to reset the session").
#
# That heuristic is aimed at genuine crash loops, but xsync stops the session on
# purpose every time a game launches. Five short play sessions - or, as happened
# here, a few failed starts while the TV was in standby - are enough to trip it,
# after which gaming mode refuses to start at all and the user is dumped on the
# KDE desktop with no obvious cause.
#
# Our teardowns are intentional, so they must not count as failures.
clear_short_session_tracker() {
    local tracker=/tmp/chimeraos-short-session-tracker
    if [[ -f "$tracker" ]]; then
        local n; n="$(wc -l <"$tracker" 2>/dev/null || echo 0)"
        rm -f "$tracker"
        log "cleared Bazzite's short-session tracker ($n entr$([[ $n == 1 ]] && echo y || echo ies))"
    fi
}

session_start() {
    need_root
    set_phase RESTORE_SESSION

    clear_short_session_tracker
    # ensure_gamescope_session was deliberately made to return 1 when it cannot
    # write the autologin drop-in, and was then called without checking it.
    ensure_gamescope_session || error "could not ensure the gamescope session — sddm may autologin elsewhere"

    log "starting $XSYNC_DISPLAY_MANAGER"
    if ! systemctl start "$XSYNC_DISPLAY_MANAGER"; then
        error "failed to start $XSYNC_DISPLAY_MANAGER"
        return 1
    fi

    # Starting the DM is not the same as the session coming up. Confirm gamescope
    # actually appears, so a silent fallback to another session is caught here
    # rather than by the user staring at the wrong UI.
    local waited=0
    while (( waited < 60 )); do
        if pgrep -x gamescope-wl >/dev/null 2>&1; then
            log "gaming mode restored after ${waited}s"
            return 0
        fi
        sleep 2
        (( waited += 2 ))
    done

    # Report the failure the poll exists to detect.
    #
    # This returned 0 after warning, which made every caller's failure branch
    # dead code -- including xsync-display-watch's entire retry state machine.
    # The watcher would log "gaming mode restored", clear we_stopped_it and reset
    # restore_failures, so its guard could never fire again and MAX_RESTORE_FAILURES
    # could only ever count `systemctl start` failures, never the case its own
    # comment names. The TV sat on the wrong UI with a success line in the log.
    error "display manager is up but gamescope did not appear within ${waited}s"
    return 1
}

session_status() {
    printf 'display-manager: %s\n' "$(systemctl is-active "$XSYNC_DISPLAY_MANAGER" 2>/dev/null)"
    printf 'gamescope:       %s\n' \
        "$(pgrep -x gamescope-wl >/dev/null 2>&1 && echo running || echo stopped)"
    printf 'steam:           %s\n' \
        "$(steam_running && echo running || echo stopped)"
}

case "${1:-status}" in
    stop)   session_stop ;;
    start)  session_start ;;
    status) session_status ;;
    *) echo "usage: $0 {stop|start|status}" >&2; exit 64 ;;
esac
