#!/usr/bin/bash
# xsync — talk to the Windows guest over qemu-guest-agent.
#
#   guest.sh ping                 is the guest agent responding?
#   guest.sh wait [timeout]       block until the guest is up
#   guest.sh exec <program> [args...]   run a program in the guest, return its stdout
#   guest.sh games                enumerate installed Xbox games (JSON)
#   guest.sh launch <game-id>     launch a game (or the Xbox app if empty)
#   guest.sh playing              is a game still running?
#   guest.sh downloading          is a Game Pass download/install in progress?
#   guest.sh shutdown             ask Windows to shut down
#
# qemu-guest-agent ships on the virtio-win ISO, so this needs nothing extra
# installed in the guest beyond the standard virtio drivers. Using it instead of
# a shared filesystem also means the watchdog's liveness signal and the control
# channel are the same thing: if the guest stops answering, that *is* the failure.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/xsync-common.sh"

VIRSH="virsh --connect qemu:///system"
AGENT_DIR='C:\Program Files\xsync'
AGENT_PS1="$AGENT_DIR\\xsync-agent.ps1"

# The agent is PowerShell, not a compiled binary. That means no Windows build
# toolchain is needed to hack on xsync, and the guest side stays readable — it
# uses inline C# via Add-Type for the XInput calls, compiled by the .NET that
# Windows already ships.
agent() {
    local action="$1"; shift
    guest_exec 'powershell.exe' '-NoProfile' '-NonInteractive' '-ExecutionPolicy' 'Bypass' \
        '-File' "$AGENT_PS1" '-Action' "$action" "$@"
}

# Raw guest-agent RPC. Quiet on failure; callers decide what that means.
#
# But "failure" here covers two situations that must not be conflated:
#
#   1. The guest agent did not answer. A real guest problem, and the thing
#      every caller is actually trying to measure.
#   2. We never reached libvirt at all — no polkit agent on a plain tty, the
#      user not in the 'libvirt' group, the socket down. The guest may be
#      perfectly healthy and still running a game.
#
# Swallowing stderr made both look identical: "unreachable". That is worse than
# unhelpful, because it is the DEFAULT outcome for anyone running this by hand.
# xsync normally runs as root under xsync-session@.service, where connecting
# just works, so the broken case only ever shows up during manual debugging —
# and then it sends you hunting a guest fault that does not exist.
#
# Distinguish them by asking libvirt something that does not involve the guest
# at all. If domstate also fails, the guest was never the problem.
_LIBVIRT_WARNED=0
_agent() {
    local out
    if out="$($VIRSH qemu-agent-command "$XSYNC_VM_NAME" "$1" --timeout 10 2>/dev/null)"; then
        printf '%s\n' "$out"
        return 0
    fi

    if ! $VIRSH domstate "$XSYNC_VM_NAME" >/dev/null 2>&1; then
        if (( _LIBVIRT_WARNED == 0 )); then
            _LIBVIRT_WARNED=1
            error "cannot reach libvirt — this is NOT a guest failure"
            error "  run as root (sudo), or add $USER to the 'libvirt' group"
        fi
    fi
    return 1
}

guest_ping() {
    _agent '{"execute":"guest-ping"}' | grep -q 'return'
}

# Measure wall clock, not accumulated sleeps.
#
# Counting only the sleeps ignores however long each probe itself takes, which
# makes the timeout mean something other than what it says: guest_ping can block
# for the full 10s virsh timeout, so a nominal 300s budget could keep polling for
# the better part of half an hour before giving up. It also under-reports how
# long the wait actually took -- an observed "ready after 18s" was 46s of real
# time, which is exactly the sort of quietly wrong number that sends you looking
# in the wrong place later.
guest_wait() {
    local timeout="${1:-$XSYNC_BOOT_TIMEOUT}"
    local start deadline
    start="$(date +%s)"
    deadline=$(( start + timeout ))
    log "waiting up to ${timeout}s for the guest agent"
    while :; do
        if guest_ping; then
            log "guest agent responded after $(( $(date +%s) - start ))s"
            return 0
        fi
        (( $(date +%s) >= deadline )) && break
        sleep 2
    done
    error "guest agent did not respond within ${timeout}s"
    return 1
}

# Run a program in the guest and echo its stdout.
guest_exec() {
    local prog="$1"; shift
    local args_json="[]"
    if (( $# )); then
        args_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
    fi

    local pid_json pid
    pid_json="$(_agent "$(jq -nc \
        --arg p "$prog" --argjson a "$args_json" \
        '{execute:"guest-exec",arguments:{path:$p,arg:$a,"capture-output":true}}')")"
    pid="$(echo "$pid_json" | jq -r '.return.pid // empty' 2>/dev/null)"
    [[ -n "$pid" ]] || { error "guest-exec failed for $prog"; return 1; }

    # Poll for completion.
    #
    # The timeout is generous and configurable because some guest work is
    # legitimately slow: a GPU driver install runs for minutes, and enumeration
    # bounces through a scheduled task in the user session. A host timeout
    # shorter than the guest's own limits turns a working operation into a
    # reported failure.
    # Wall clock, like the two wait loops. This one needed it most and was the
    # one left behind: every iteration issues a virsh RPC that can block for the
    # full 10s agent timeout, plus an untimed domstate fallback, so counting
    # `sleep 1` iterations overstated the budget by up to 11x. With
    # XSYNC_GUEST_EXEC_TIMEOUT=2400 for the driver install and a guest that has
    # bugchecked but kept QEMU alive, a configured 40 minutes became about seven
    # hours of a black TV.
    local limit="${XSYNC_GUEST_EXEC_TIMEOUT:-300}"
    local status rc start deadline
    start="$(date +%s)"
    deadline=$(( start + limit ))
    while (( $(date +%s) < deadline )); do
        status="$(_agent "$(jq -nc --argjson pid "$pid" \
            '{execute:"guest-exec-status",arguments:{pid:$pid}}')")"
        if echo "$status" | jq -e '.return.exited == true' >/dev/null 2>&1; then
            echo "$status" | jq -r '.return["out-data"] // empty' | base64 -d 2>/dev/null
            # Propagate the guest process's exit status. Discarding it meant a
            # failed launch (for instance "no interactive user is logged on")
            # was reported to the host as a success, and the session then sat
            # waiting for a game that was never going to start.
            #
            # Report it as a plain 1 rather than returning the raw value.
            # `return` truncates to 8 bits, so a Windows exit code of 256 came
            # back as 0 -- success -- and 0xC0000005 (access violation) came
            # back as 5. The real value goes in the log instead, where it is
            # readable and cannot be silently reinterpreted.
            rc="$(echo "$status" | jq -r '.return.exitcode // 0')"
            if [[ "$rc" != "0" ]]; then
                local err
                err="$(echo "$status" | jq -r '.return["err-data"] // empty' | base64 -d 2>/dev/null | head -c 400)"
                warn "guest process exited with code $rc"
                [[ -n "$err" ]] && warn "guest stderr: $err"
                return 1
            fi
            return 0
        fi
        sleep 1
    done
    error "guest-exec timed out for $prog after $(( $(date +%s) - start ))s"
    return 1
}

# Convenience: run a PowerShell one-liner in the guest.
guest_ps() {
    guest_exec 'powershell.exe' '-NoProfile' '-NonInteractive' '-Command' "$1"
}

guest_games() {
    # The agent's enumerator writes a JSON array to stdout.
    agent enumerate
}

guest_launch() {
    local game_id="${1:-}"
    if [[ -z "$game_id" || "$game_id" == "xbox-app" ]]; then
        log "launching the Xbox app"
        agent launch -GameId 'xbox-app'
    else
        log "launching game: $game_id"
        agent launch -GameId "$game_id"
    fi
}

# Is a Game Pass download or install still running in the guest?
#
# Asked before the guest is powered off on EVERY exit path, because none of them
# knew about downloads: the watcher only ever looked at the Xbox app process and
# processes under C:\XboxGames, and a download is done by GamingServices, which
# is neither. Quitting after starting a 300 GB install threw it away.
# The guest's boot time, as an ISO string. Changes when Windows restarts.
guest_boot_id() {
    guest_exec 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' \
        -NoProfile -NonInteractive -Command \
        "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')" 2>/dev/null \
        | tr -d '\r' | grep -m1 '[0-9]'
}

guest_downloading() {
    agent downloading 2>/dev/null | grep -qi '^yes'
}

guest_playing() {
    agent status 2>/dev/null | grep -q '"playing"[[:space:]]*:[[:space:]]*true'
}

# Has the guest declared the session OVER, as opposed to merely not playing yet?
#
# The distinction matters for exactly one thing: the host takes a single final
# game-list capture on the way out, and "not playing" is also true for the whole
# launch window before the game appears. Spending the capture there means the one
# snapshot that could include a game installed during this session never gets
# taken. Only the guest watcher sets this, and only once the game has gone.
guest_ended() {
    # Bounded, because this runs inside the exit monitor's poll loop. A status
    # query is a sub-second operation; inheriting the 300s guest-exec default
    # would let one unlucky call stall the supervisory loop for five minutes,
    # which is precisely when it needs to be responsive.
    local XSYNC_GUEST_EXEC_TIMEOUT=15
    agent status 2>/dev/null | grep -q '"ended"[[:space:]]*:[[:space:]]*true'
}

# Copy a file from the host into the guest over the agent channel.
#
# Scripts are pushed with a UTF-8 BOM for the same reason xsync-make-unattend
# adds one: Windows PowerShell 5.1 misdecodes BOM-less UTF-8 as Windows-1252 and
# turns em dashes into stray smart quotes, which breaks parsing in confusing ways.
guest_push() {
    local src="$1" dest="$2"
    [[ -f "$src" ]] || { error "no such file: $src"; return 1; }

    # Stage the exact bytes to send, BOM included for scripts.
    #
    # PowerShell 5.1 decodes a BOM-less file as Windows-1252, so any non-ASCII
    # character in a pushed script silently becomes mojibake.
    local tmpdir
    tmpdir="$(mktemp -d)" || { error "could not create a temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local srcfile="$src"
    if [[ "$src" == *.ps1 ]]; then
        srcfile="$tmpdir/payload"
        { printf '\xEF\xBB\xBF'; cat "$src"; } >"$srcfile" \
            || { error "could not stage $src"; return 1; }
    fi

    # Always write to a staging path first. The guest agent's file API refuses to
    # open handles under C:\Program Files (it returns no handle at all, with no
    # error), so writing directly to the install directory silently fails. Staging
    # somewhere it will write, then copying inside the guest, works for any
    # destination — the copy runs as SYSTEM, which can write anywhere.
    local stage='C:\ProgramData\xsync\.push.tmp'

    local handle
    handle="$(_agent "$(jq -nc --arg p "$stage" \
        '{execute:"guest-file-open",arguments:{path:$p,mode:"wb"}}')" \
        | jq -r '.return // empty')"
    [[ -n "$handle" ]] || { error "could not open the staging file in the guest"; return 1; }

    # Write in chunks, and never put the payload on a command line.
    #
    # This used to base64 the whole file into a shell variable and pass it to jq
    # as --arg. Both halves of that break on real files: the encoded blob is an
    # argv entry, so ARG_MAX (2 MiB here) caps a push at roughly 1.5 MiB of
    # source, and the resulting single guest-file-write asks the agent to
    # swallow the entire file in one request.
    #
    # The failure is not subtle once you hit it — "jq: Argument list too long"
    # — but every script xsync pushes sits comfortably under the limit, so it
    # stayed invisible until the first genuinely large payload went through.
    #
    # There is a second, undocumented ceiling: a single guest-file-write of
    # 64 KiB returns {"count":65536}, while 256 KiB returns an empty response —
    # no error, no partial count, nothing to distinguish it from a hang. So the
    # chunk size is a measured limit, not a guess, and 64 KiB is the largest
    # size observed to work rather than the largest that might.
    #
    # --rawfile keeps every byte off the command line regardless of chunk size,
    # which is what makes the ARG_MAX half of this permanently fixed rather
    # than merely pushed further away.
    local ok=1 chunk
    split -b 65536 -a 4 "$srcfile" "$tmpdir/c." \
        || { error "could not split $src for transfer"; ok=0; }
    if (( ok )); then
        for chunk in "$tmpdir"/c.*; do
            base64 -w0 <"$chunk" | tr -d '\n' >"$chunk.b64"
            if ! _agent "$(jq -nc --argjson h "$handle" --rawfile b "$chunk.b64" \
                    '{execute:"guest-file-write",arguments:{handle:$h,"buf-b64":$b}}')" \
                    | jq -e '.return.count' >/dev/null 2>&1; then
                error "guest rejected a chunk of $(basename "$src")"
                ok=0
                break
            fi
        done
    fi

    _agent "$(jq -nc --argjson h "$handle" \
        '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null 2>&1

    (( ok )) || { error "failed writing the staging file"; return 1; }

    if [[ "$stage" == "$dest" ]]; then
        log "pushed $(basename "$src") -> $dest"
        return 0
    fi

    # Escape for a PowerShell single-quoted literal by doubling every quote.
    # $dest is built from a host filename, so without this a file named
    # x'; <arbitrary powershell>; '.ps1 breaks out and runs as Local System in
    # the guest.
    local dest_ps="${dest//\'/\'\'}"
    local stage_ps="${stage//\'/\'\'}"

    local out
    out="$(guest_ps "New-Item -ItemType Directory -Force -Path (Split-Path -Parent '$dest_ps') | Out-Null; Copy-Item -LiteralPath '$stage_ps' -Destination '$dest_ps' -Force; if (Test-Path -LiteralPath '$dest_ps') { 'OK' } else { 'FAIL' }" 2>/dev/null)"
    if grep -q OK <<<"$out"; then
        log "pushed $(basename "$src") -> $dest"
        return 0
    fi
    error "failed copying staged file to $dest"
    return 1
}

# Push a script and run it in the guest's *interactive* session rather than as
# Local System. Needed for anything touching per-user state — AppX registration,
# launching packaged apps, anything that must appear on the desktop.
guest_run_user() {
    local src="$1"
    local dest="C:\\ProgramData\\xsync\\$(basename "$src")"
    guest_push "$src" "$dest" || return 1
    log "running $(basename "$src") in the guest's user session"
    agent run-user -ScriptPath "$dest"
}

# Wait for a real interactive session, not merely a responding agent.
#
# guest_wait returns as soon as qemu-guest-agent answers, and the agent runs as
# Local System in session 0 -- which exists long before Windows has finished
# autologon. On this machine the gap is about twelve seconds, and every launch
# fired inside it fails with "no interactive user is logged on".
#
# The failure is quiet in the worst way: the launch is only a warning, so the
# session proceeds to RUNNING, the watchdog starts, and the host log looks like
# a healthy handoff. The user is simply left staring at the Xbox app with the
# game they asked for never having started.
#
# Poll for explorer.exe rather than a logon event: it is the thing whose absence
# actually breaks the launch, so it cannot report ready while launching would
# still fail.
guest_wait_user() {
    # Its own budget, not the agent's. See XSYNC_USER_TIMEOUT in xsync.conf:
    # this wait happens with the host session already gone, so it is paid for in
    # black-screen seconds, and it warrants a tighter bound than the agent wait.
    local timeout="${1:-${XSYNC_USER_TIMEOUT:-$XSYNC_BOOT_TIMEOUT}}"

    # Probe with tasklist, not PowerShell, and bound every probe.
    #
    # The first version of this used powershell.exe, and it deadlocked the
    # handoff: starting PowerShell seconds after boot has to JIT and load
    # modules while the disk is saturated by logon, and a single probe issued at
    # T+24s had still not returned ninety seconds later. Meanwhile the identical
    # command run by hand answered instantly, because by then the guest was idle.
    #
    # Worse, guest_exec defaults to a 300s timeout, so one slow probe outlived
    # the caller's entire 120s budget -- the loop could not even give up on
    # schedule. Scope the shorter limit here (bash dynamic scoping means
    # guest_exec sees it) so the outer timeout is honoured.
    #
    # tasklist is a small native binary with no runtime to warm up, which is
    # exactly what a poll issued during the noisiest part of boot needs.
    local XSYNC_GUEST_EXEC_TIMEOUT=10

    # Wall clock, for the same reason as guest_wait above: the first version of
    # this counted only its sleeps and reported "ready after 18s" for a wait that
    # actually took 46 seconds of real time.
    local start deadline
    start="$(date +%s)"
    deadline=$(( start + timeout ))
    log "waiting up to ${timeout}s for the interactive session"
    while :; do
        if guest_exec 'C:\Windows\System32\tasklist.exe' \
                /FI 'IMAGENAME eq explorer.exe' /NH 2>/dev/null \
                | grep -qi 'explorer\.exe'; then
            log "interactive session ready after $(( $(date +%s) - start ))s"
            return 0
        fi
        (( $(date +%s) >= deadline )) && break
        sleep 3
    done
    # Say what the guest WAS doing, not just that it failed.
    #
    # This fires intermittently (3 of 19 launches on 29 Jul) and the bare
    # "no interactive session" told nobody anything: the guest is powered off
    # moments later by the abort, taking the evidence with it. Grab it here,
    # while the agent is still answering, because there is no second chance.
    #
    # Probes are individually bounded and every one is best-effort: this runs on
    # a path that is already failing and must not make things worse.
    error "no interactive session appeared within ${timeout}s"
    (
        local XSYNC_GUEST_EXEC_TIMEOUT=15
        local who procs
        who="$(guest_exec 'C:\Windows\System32\query.exe' user 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
        [[ -n "$who" ]] && error "  logged-on sessions: ${who}" || error "  logged-on sessions: <none reported>"

        procs="$(guest_exec 'C:\Windows\System32\tasklist.exe' /NH 2>/dev/null \
                 | tr -d '\r' | awk '{print $1}' \
                 | grep -iE 'explorer|logonui|winlogon|userinit|sihost|XboxPcApp|StartMenu|dwm' \
                 | sort -u | tr '\n' ' ')"
        [[ -n "$procs" ]] && error "  shell processes present: ${procs}" \
                          || error "  shell processes present: <none of explorer/logonui/winlogon/userinit/sihost/dwm>"
    ) || true
    return 1
}

# Copy a file OUT of the guest.
#
# The counterpart to guest_push, and missing until a 2.6 MB kernel minidump
# needed to come back to the host for analysis. Everything that diagnoses a
# guest problem from the outside -- crash dumps, PresentMon captures,
# screenshots -- is useless if it cannot leave the guest.
#
# Chunked for the same reason the push is: guest-file-read is capped well below
# the size of anything worth retrieving, and a single oversized request returns
# an empty response rather than an error.
guest_pull() {
    local src="$1" dest="$2"
    local handle
    handle="$(_agent "$(jq -nc --arg p "$src" \
        '{execute:"guest-file-open",arguments:{path:$p,mode:"rb"}}')" \
        | jq -r '.return // empty')"
    [[ -n "$handle" ]] || { error "could not open $src in the guest"; return 1; }

    : >"$dest" || { error "cannot write $dest"; return 1; }
    local resp b64 eof count total=0
    while :; do
        resp="$(_agent "$(jq -nc --argjson h "$handle" \
            '{execute:"guest-file-read",arguments:{handle:$h,count:65536}}')")"
        b64="$(echo "$resp" | jq -r '.return["buf-b64"] // empty')"
        eof="$(echo "$resp" | jq -r '.return.eof // false')"
        count="$(echo "$resp" | jq -r '.return.count // 0')"
        if [[ -z "$resp" ]]; then
            error "guest-file-read failed after ${total} bytes"
            _agent "$(jq -nc --argjson h "$handle" '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null 2>&1
            return 1
        fi
        # Check the HOST-side write too, and count what actually landed.
        #
        # This reported success from the agent's byte count while discarding the
        # status of the local write, so a missing parent directory or a full disk
        # printed "pulled ... (2621440 bytes)" and exited 0 over a truncated or
        # empty file -- on the diagnostic path you reach for when something has
        # already gone wrong.
        if [[ -n "$b64" ]]; then
            printf '%s' "$b64" | base64 -d >>"$dest" \
                || { error "write to $dest failed after ${total} bytes"; \
                     _agent "$(jq -nc --argjson h "$handle" '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null 2>&1; \
                     return 1; }
        fi
        total=$(( total + count ))
        [[ "$eof" == "true" ]] && break
        (( count == 0 )) && break
    done
    _agent "$(jq -nc --argjson h "$handle" \
        '{execute:"guest-file-close",arguments:{handle:$h}}')" >/dev/null 2>&1
    local landed
    landed="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    if [[ "$landed" != "$total" ]]; then
        error "short pull: guest sent ${total} bytes, ${landed} landed in $dest"
        return 1
    fi
    log "pulled $src -> $dest (${total} bytes)"
    return 0
}

guest_shutdown() {
    log "asking the guest to shut down"
    _agent '{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}' >/dev/null 2>&1 || true
}

case "${1:-ping}" in
    ping)     guest_ping && echo alive || { echo unreachable; exit 1; } ;;
    wait)     guest_wait "${2:-}" ;;
    wait-user) guest_wait_user "${2:-}" ;;
    exec)     shift; guest_exec "$@" ;;
    ps)       shift; guest_ps "$*" ;;
    games)    guest_games ;;
    launch)   guest_launch "${2:-}" ;;
    playing)  guest_playing && echo yes || { echo no; exit 1; } ;;
    ended)    guest_ended && echo yes || { echo no; exit 1; } ;;
    downloading) guest_downloading && echo yes || { echo no; exit 1; } ;;
    boot-id)  guest_boot_id ;;
    push)     guest_push "${2:?source}" "${3:?destination}" ;;
    pull)     guest_pull "${2:?source}" "${3:?destination}" ;;
    run-user) guest_run_user "${2:?script}" ;;
    shutdown) guest_shutdown ;;
    *) echo "usage: $0 {ping|wait|wait-user|exec|ps|games|launch|playing|ended|downloading|boot-id|push|pull|run-user|shutdown}" >&2; exit 64 ;;
esac
