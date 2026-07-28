#!/usr/bin/bash
# xsync — hand the GPU between the host driver and vfio-pci.
#
#   gpu.sh status    show current binding
#   gpu.sh release   host driver -> vfio-pci   (before starting the VM)
#   gpu.sh reclaim   vfio-pci -> host driver   (after the VM exits)
#
# reclaim is deliberately forgiving: it retries, and never aborts the caller's
# recovery path. A black TV is the worst outcome this project can produce, so
# reclaim tries everything it can and reports rather than dying.

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/xsync-common.sh"

# ---------------------------------------------------------------- inspection

gpu_status() {
    local addr drv
    while read -r addr; do
        [[ -n "$addr" ]] || continue
        if ! pci_exists "$addr"; then
            echo "$addr  MISSING"
            continue
        fi
        drv="$(pci_driver "$addr")"
        printf '%s  %s\n' "$addr" "$drv"
    done < <(gpu_devices)
}

gpu_bound_to() {
    # Ownership of the GPU as a whole, not per-function.
    #
    # The functions legitimately sit on *different* host drivers when idle: on the
    # reference machine 01:00.0 is on nvidia while 01:00.1 (HDMI audio) is on
    # snd_hda_intel. So comparing driver names across functions is meaningless.
    # What actually matters is only ever: has vfio-pci taken them, or not?
    #
    #   host      no function is on vfio-pci  -> host owns the GPU, safe to release
    #   vfio-pci  every function is on vfio-pci -> VM owns the GPU
    #   partial   some but not all            -> a previous run cleaned up badly
    #   unbound   the video function is on NO driver at all
    #
    # That last state is the whole reason this cannot just count vfio-pci.
    # Read the comment above bind_host: after vfio has held a card,
    # drivers_probe frequently leaves it bound to nothing, which is invisible to
    # a "not vfio-pci" test while the display stays dead. bind_host was hardened
    # against exactly that; this function was not, so it reported `host` for a
    # driverless GPU -- and every consumer treats `host` as healthy.
    #
    # The consequence was that the black TV disabled its own repair: xsync-recover
    # runs from ExecStopPost= after every session, saw `host`, logged "already
    # healthy -- nothing to do" and exited before reaching the status dump that
    # would have shown `none`. `sudo xsync-recover`, the documented remedy, was
    # the same no-op, and xsync-doctor reported all-clear.
    local addr drv total=0 vfio=0 none=0
    while read -r addr; do
        [[ -n "$addr" ]] || continue
        (( total++ ))
        drv="$(pci_driver "$addr")"
        [[ "$drv" == "vfio-pci" ]] && (( vfio++ ))
        [[ "$drv" == "none" ]] && (( none++ ))
    done < <(gpu_devices)

    # The video function specifically is what drives the TV, so judge on it
    # rather than on a count that a healthy audio function could mask.
    local video_drv
    video_drv="$(pci_driver "$XSYNC_GPU_PCI")"

    if (( vfio == total )) && (( total > 0 )); then echo vfio-pci
    elif (( vfio > 0 )); then                       echo partial
    elif [[ "$video_drv" == "none" ]]; then         echo unbound
    elif (( none > 0 )); then                       echo partial
    else                                            echo host
    fi
}

# ---------------------------------------------------------------- gpu clients

# Processes still holding /dev/nvidia* keep the modules pinned. Ask nicely, then insist.
kill_gpu_clients() {
    local pids
    pids="$(fuser -v /dev/nvidia* 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    if [[ -z "$pids" ]]; then
        log "no residual GPU clients"
        return 0
    fi
    warn "GPU still held by: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 2
    pids="$(fuser -v /dev/nvidia* 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    if [[ -n "$pids" ]]; then
        warn "forcing: $(echo "$pids" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        kill -KILL $pids 2>/dev/null || true
        sleep 1
    fi
}

# ---------------------------------------------------------------- binding

unbind_device() {
    local addr="$1" drv
    drv="$(pci_driver "$addr")"
    if [[ "$drv" == none ]]; then
        return 0
    fi
    log "unbinding $addr from $drv"
    echo "$addr" >"/sys/bus/pci/devices/$addr/driver/unbind" 2>/dev/null
}

bind_vfio() {
    local addr="$1"
    echo vfio-pci >"/sys/bus/pci/devices/$addr/driver_override" 2>/dev/null \
        || { error "cannot set driver_override on $addr"; return 1; }
    echo "$addr" >/sys/bus/pci/drivers_probe 2>/dev/null || true
    [[ "$(pci_driver "$addr")" == "vfio-pci" ]]
}

# Bind a device back to its host driver.
#
# `$want` is the driver that MUST end up bound for the video function. Testing
# merely "not vfio-pci" is not good enough: after vfio has held a GPU,
# drivers_probe frequently leaves it bound to *nothing*, which passes a
# "not vfio-pci" check while the display stays dead. That produced a black TV
# with a completely clean success log.
bind_host() {
    local addr="$1" want="${2:-}"

    # Clearing the override lets the normal driver match again.
    echo "" >"/sys/bus/pci/devices/$addr/driver_override" 2>/dev/null || true
    echo "$addr" >/sys/bus/pci/drivers_probe 2>/dev/null || true

    local cur; cur="$(pci_driver "$addr")"

    # Autoprobe didn't take: ask the driver to claim the device explicitly.
    if [[ -n "$want" && "$cur" != "$want" ]]; then
        if [[ -d "/sys/bus/pci/drivers/$want" ]]; then
            warn "$addr not claimed by $want after probe (driver: $cur) — binding explicitly"
            echo "$addr" >"/sys/bus/pci/drivers/$want/bind" 2>/dev/null || true
            cur="$(pci_driver "$addr")"
        fi
    fi

    if [[ -n "$want" ]]; then
        [[ "$cur" == "$want" ]]
    else
        # Audio function: any host driver is fine, just not vfio-pci and not none.
        [[ "$cur" != "vfio-pci" && "$cur" != "none" ]]
    fi
}

# ---------------------------------------------------------------- release

gpu_release() {
    need_root
    set_phase RELEASE_GPU

    local current
    current="$(gpu_bound_to)"
    if [[ "$current" == "vfio-pci" ]]; then
        log "GPU already bound to vfio-pci — nothing to do"
        return 0
    fi
    if [[ "$current" == "partial" ]]; then
        warn "GPU functions are split across vfio-pci and host drivers — re-releasing all"
    fi

    modprobe vfio-pci 2>/dev/null || true

    log "stopping nvidia-persistenced if running"
    systemctl stop nvidia-persistenced.service 2>/dev/null || true

    kill_gpu_clients

    log "unloading host GPU modules"
    local mod
    for mod in $XSYNC_GPU_MODULES; do
        if lsmod | grep -q "^${mod} "; then
            if ! retry 3 modprobe -r "$mod"; then
                error "could not unload $mod — GPU is still in use"
                lsmod | grep -E "^${mod} " >&2 || true
                return 1
            fi
            log "unloaded $mod"
        fi
    done

    local addr
    while read -r addr; do
        [[ -n "$addr" ]] || continue
        pci_exists "$addr" || { error "$addr not present"; return 1; }
        unbind_device "$addr"
        if ! retry "$XSYNC_GPU_REBIND_RETRIES" bind_vfio "$addr"; then
            error "failed to bind $addr to vfio-pci"
            return 1
        fi
        log "$addr -> vfio-pci"
    done < <(gpu_devices)

    log "GPU released to vfio-pci"
    return 0
}

# ------------------------------------------------------------ dongle recovery

# Nothing to do for the Xbox dongle on reclaim. Deliberately.
#
# Two attempts at "helping" here were both wrong, and both made things worse:
#
#  1. Reloading xone_dongle, on the theory that the dongle came back from
#     passthrough bound but with a dead radio. It fires while the device is
#     still settling from xhci_hcd being rebound, so the firmware upload times
#     out -- xone_dongle_fw_load: init radio failed: -110 -- leaving the dongle
#     in exactly the state it was meant to repair. The dead radio seen earlier
#     was caused by a manual reload, not by the passthrough.
#
#  2. Forcing pairing mode, on the theory that the bond is wiped every session.
#     A real session disproved it: the controller reconnected on its own 14
#     seconds after the GPU came back, with no pairing mode and no button
#     pressed. Setting it anyway just logged a spurious warning when the sysfs
#     control had not appeared yet, and would let a stray controller pair.
#
# The kernel re-enumerates the controller and binds the driver by itself. Both
# sides of the bond persist -- xone on Linux, and Windows on its side -- so
# pairing is a one-time cost per side, not per session. Leave it alone.

# ---------------------------------------------------------------- reclaim

gpu_reclaim() {
    need_root

    # Never unbind vfio-pci from a card a live QEMU is still mapping.
    #
    # Both in-tree callers check this, but `reclaim` is a documented public
    # subcommand and the header invites using it as the "try everything" escape
    # hatch. Running it against a running VM pulls the device out from under
    # the guest, which per vm.sh wedges the card until the host reboots -- the
    # exact outcome this project treats as unacceptable.
    if [[ "${XSYNC_FORCE_RECLAIM:-0}" != "1" ]]; then
        local vmsh; vmsh="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/vm.sh"
        if [[ -x "$vmsh" ]] && ! "$vmsh" gone >/dev/null 2>&1; then
            error "the VM is still present (state: $("$vmsh" state 2>/dev/null)) — refusing to reclaim the GPU"
            error "stop it first, or set XSYNC_FORCE_RECLAIM=1 if you know it is safe"
            return 1
        fi
    fi

    set_phase RECLAIM_GPU

    local failed=0 addr

    while read -r addr; do
        [[ -n "$addr" ]] || continue
        if ! pci_exists "$addr"; then
            error "$addr missing during reclaim"
            failed=1
            continue
        fi
        if [[ "$(pci_driver "$addr")" == "vfio-pci" ]]; then
            unbind_device "$addr"
        fi
        echo "" >"/sys/bus/pci/devices/$addr/driver_override" 2>/dev/null || true
    done < <(gpu_devices)

    log "reloading host GPU modules"
    # Reverse of the unload order.
    local mods_rev="" mod
    for mod in $XSYNC_GPU_MODULES; do
        mods_rev="$mod $mods_rev"
    done
    for mod in $mods_rev; do
        if ! retry 3 modprobe "$mod"; then
            error "could not load $mod"
            failed=1
        fi
    done

    while read -r addr; do
        [[ -n "$addr" ]] || continue
        pci_exists "$addr" || continue
        # Only the video function must land on the configured host driver; the
        # audio function legitimately uses snd_hda_intel.
        local want=""
        [[ "$addr" == "$XSYNC_GPU_PCI" ]] && want="$XSYNC_GPU_HOST_DRIVER"
        if ! retry "$XSYNC_GPU_REBIND_RETRIES" bind_host "$addr" "$want"; then
            error "failed to rebind $addr to ${want:-a host driver} (now: $(pci_driver "$addr"))"
            failed=1
        else
            log "$addr -> $(pci_driver "$addr")"
        fi
    done < <(gpu_devices)


    if (( failed )); then
        error "GPU reclaim incomplete — restoring the session anyway"
        return 1
    fi

    wait_for_display

    log "GPU reclaimed by host"
    return 0
}

# Wait for a display to reappear after the GPU comes back.
#
# This machine drives a TV, not a monitor, and that difference matters: when the
# HDMI signal disappears during a handoff a TV will often drop to standby, and
# once it does it stops answering on the DDC lines. The connector then reads
# "disconnected" with a 0-byte EDID, the driver reports "Cannot find any crtc or
# sizes", and gamescope has no output to start on — so the session dies and the
# display manager falls back to the desktop session.
#
# NVIDIA does not register a CEC adapter (only amdgpu/i915 do), so there is no
# way to wake the TV from here. All we can do is give it a chance to come back,
# and report clearly when it does not, instead of silently starting a session
# that has nowhere to draw.
wait_for_display() {
    local conn timeout="${XSYNC_DISPLAY_WAIT:-20}" waited=0
    conn="$(display_connector)"
    [[ -n "$conn" ]] || { warn "no HDMI connector found for the GPU"; return 0; }

    while (( waited < timeout )); do
        if [[ "$(cat "$conn/status" 2>/dev/null)" == "connected" ]]; then
            log "display detected on $(basename "$conn") after ${waited}s"
            return 0
        fi
        # Nudge the driver to re-probe; harmless if the sink is genuinely absent.
        echo detect >"$conn/status" 2>/dev/null || true
        sleep 2
        (( waited += 2 ))
    done

    warn "no display detected on $(basename "$conn") after ${timeout}s"
    warn "the TV is most likely in standby — it should wake once it is switched on"
    return 0
}

# The connector the GPU actually drives (first connected one, else first HDMI).
display_connector() {
    local card c
    card="$(basename "$(readlink -f "/sys/bus/pci/devices/$XSYNC_GPU_PCI/drm/card"* 2>/dev/null | head -1)" 2>/dev/null)"
    for c in /sys/class/drm/${card}-*; do
        [[ -e "$c/status" ]] || continue
        [[ "$(cat "$c/status" 2>/dev/null)" == "connected" ]] && { echo "$c"; return; }
    done
    for c in /sys/class/drm/${card}-HDMI*; do
        [[ -e "$c/status" ]] && { echo "$c"; return; }
    done
}

# ---------------------------------------------------------------- entrypoint

case "${1:-status}" in
    status)  gpu_status ;;
    bound)   gpu_bound_to ;;
    release) gpu_release ;;
    reclaim) gpu_reclaim ;;
    *) echo "usage: $0 {status|bound|release|reclaim}" >&2; exit 64 ;;
esac
