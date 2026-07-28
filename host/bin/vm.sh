#!/usr/bin/bash
# xsync — libvirt lifecycle for the Windows guest.
#
#   vm.sh start <game-id>   start the VM, telling the guest which game to launch
#   vm.sh stop              graceful shutdown, escalating to destroy on timeout
#   vm.sh kill              immediate destroy
#   vm.sh status            domain state
#   vm.sh wait              block until the domain is no longer running

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/xsync-common.sh"

VIRSH="virsh --connect qemu:///system"

# "I could not ask" is not the same answer as "it is not there".
#
# This used to collapse every failure into "undefined": if virsh produced no
# output for any reason — libvirtd restarting, the socket gone, no polkit agent,
# a permissions change — the state was reported as undefined, vm_gone() below
# returned true, and the caller concluded QEMU was gone.
#
# Read the next comment block to see why that is the worst possible default
# here. A momentary libvirt failure would hand out permission to unbind a GPU
# that QEMU still has mapped.
#
# So separate the two cases by asking libvirt something that does not involve
# this domain. If that works, the domain genuinely is not defined; if it does
# not, we simply do not know, and "unknown" is a state no caller treats as safe.
vm_state() {
    local s
    s="$($VIRSH domstate "$XSYNC_VM_NAME" 2>/dev/null | head -1 | tr -d '\r')"
    if [[ -n "$s" ]]; then
        echo "$s"
    elif $VIRSH version >/dev/null 2>&1; then
        echo "undefined"
    else
        echo "unknown"
    fi
}

# CRITICAL DISTINCTION.
#
# libvirt has seven domain states and only ONE of them means the QEMU process is
# gone: "shut off". In "in shutdown", "paused", "pmsuspended", "crashed" and
# "idle" the process is still alive and still owns the passed-through GPU.
#
# Treating anything other than "shut off" as stopped is how you end up unbinding
# the 4090 from vfio-pci while QEMU has it mapped — which is unrecoverable
# without a reboot, i.e. exactly the black TV this project must never produce.
# The clean shutdown path hits "in shutdown" for a noticeable window, so this is
# not a theoretical race: it fires on a completely normal quit.
# Note "unknown" is deliberately absent from this list, so an unreadable state
# means NOT gone and the GPU is left alone. Refusing to act on an answer we do
# not have costs a failed teardown; acting on a wrong one costs the card.
#
# Also called once, not twice. Two separate virsh calls could straddle a state
# change and disagree with each other.
vm_gone() {
    local s
    s="$(vm_state)"
    [[ "$s" == "shut off" || "$s" == "undefined" ]]
}

# True while QEMU exists in any form. Use this to decide whether it is safe to
# touch the GPU.
vm_alive() {
    ! vm_gone
}

# Narrower: actually executing (not paused). Only for reporting/preflight.
vm_running() {
    [[ "$(vm_state)" == "running" ]]
}

vm_defined() {
    $VIRSH dominfo "$XSYNC_VM_NAME" >/dev/null 2>&1
}

# Which profile the domain is currently defined on: install, maint or play.
#
# tools/xsync-setup records this in domain metadata precisely so it can be read
# back. Inferring it from the presence of a hostdev would be guesswork; this is
# what the renderer actually intended.
vm_profile() {
    $VIRSH dumpxml "$XSYNC_VM_NAME" 2>/dev/null \
        | sed -n 's|.*<xsync:profile[^>]*>\([^<]*\)</xsync:profile>.*|\1|p' \
        | head -1
}

# Hot-attach the Xbox wireless dongle if it is plugged in.
#
# Not declared in the domain XML on purpose: libvirt's schema won't accept
# startupPolicy on a USB hostdev, so a static entry would make the VM refuse to
# start whenever the dongle is absent. Attaching live keeps a missing dongle a
# warning rather than a failure, and lets it be plugged in after boot.
# Release the dongle from whatever host driver has claimed it.
#
# libvirt's managed='yes' is documented to detach the host driver, but for USB
# devices it does not reliably do so: on this machine xone-dongle keeps its grip
# on interface 1-2:1.0, libvirt still reports the device as attached, and Windows
# sees no controller at all. The failure is silent from every angle — the host
# log says "dongle attached", the domain XML lists the hostdev, and the guest
# just has no gamepad.
#
# Unbinding each interface by hand first is what actually frees it for QEMU.
dongle_release_from_host() {
    local vid="$XSYNC_DONGLE_VENDOR" pid="$XSYNC_DONGLE_PRODUCT"
    local dev iface drv released=0

    for dev in /sys/bus/usb/devices/*/; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        [[ "$(cat "$dev/idVendor")" == "$vid" && "$(cat "$dev/idProduct")" == "$pid" ]] || continue

        for iface in "$dev"*:*/; do
            [[ -e "$iface/driver" ]] || continue
            drv="$(basename "$(readlink -f "$iface/driver")")"
            log "unbinding $(basename "$iface") from $drv"
            echo "$(basename "$iface")" >"$iface/driver/unbind" 2>/dev/null && released=1
        done
    done

    # Unbinding can make the device re-enumerate, which changes its USB device
    # number. libvirt resolves the vendor/product pair to a bus/device address at
    # attach time, so attaching too soon pins a stale address: the domain ends up
    # referencing a device number that no longer exists and the guest sees no
    # controller, while everything on the host still reports success.
    #
    # With the host driver blacklisted (see tools/xsync-setup) nothing is bound
    # in the first place and this whole path is a no-op.
    if (( released )); then
        log "waiting for the dongle to settle after unbind"
        udevadm settle --timeout=5 2>/dev/null || sleep 2
    fi
    return 0
}

dongle_attach() {
    if ! lsusb -d "${XSYNC_DONGLE_VENDOR}:${XSYNC_DONGLE_PRODUCT}" >/dev/null 2>&1; then
        warn "Xbox dongle ${XSYNC_DONGLE_VENDOR}:${XSYNC_DONGLE_PRODUCT} not present — no controller in the VM"
        return 0
    fi

    dongle_release_from_host

    # Pin the *current* bus/device numbers rather than letting libvirt resolve
    # the vendor/product pair itself.
    #
    # A USB device gets a new device number every time it re-enumerates, and
    # detaching it when the previous VM shut down does exactly that. libvirt
    # resolves vendor/product to a concrete address once, at attach time, and
    # can land on a number that is already stale — producing a domain that
    # references a device which no longer exists. Nothing errors: the host logs
    # a successful attach, the domain lists the hostdev, and the guest simply
    # has no controller.
    local busnum devnum d
    for d in /sys/bus/usb/devices/*/; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(cat "$d/idVendor")" == "$XSYNC_DONGLE_VENDOR" ]] || continue
        [[ "$(cat "$d/idProduct")" == "$XSYNC_DONGLE_PRODUCT" ]] || continue
        busnum="$(cat "$d/busnum")"; devnum="$(cat "$d/devnum")"
        break
    done

    if [[ -z "${busnum:-}" || -z "${devnum:-}" ]]; then
        warn "could not resolve the dongle's USB address — skipping"
        return 0
    fi
    log "dongle at bus $busnum device $devnum"

    local xml="$XSYNC_STATE_DIR/dongle.xml"
    cat >"$xml" <<EOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${XSYNC_DONGLE_VENDOR}'/>
    <product id='0x${XSYNC_DONGLE_PRODUCT}'/>
    <address bus='${busnum}' device='${devnum}'/>
  </source>
</hostdev>
EOF
    # Attaching resets the device, which makes it re-enumerate with a new device
    # number - so the address libvirt just recorded is stale the moment it is
    # used, and the guest gets nothing. Verify the domain's recorded address
    # still matches reality, and retry with the new one if not.
    local attempt
    for attempt in 1 2 3; do
        $VIRSH attach-device "$XSYNC_VM_NAME" "$xml" --live >/dev/null 2>&1 || true
        sleep 3

        local live
        live="$(dongle_devnum)"
        local recorded
        recorded="$($VIRSH dumpxml "$XSYNC_VM_NAME" 2>/dev/null \
            | grep -A4 "0x${XSYNC_DONGLE_PRODUCT}" | grep -oP "device='\K[0-9]+" | head -1)"

        if [[ -n "$live" && "$live" == "$recorded" ]]; then
            log "Xbox dongle attached (bus $busnum device $live)"
            return 0
        fi

        warn "dongle re-enumerated during attach (recorded ${recorded:-none}, now ${live:-none}) — retrying"
        $VIRSH detach-device "$XSYNC_VM_NAME" "$xml" --live >/dev/null 2>&1 || true
        sleep 2
        devnum="$live"
        [[ -n "$devnum" ]] || { warn "dongle vanished — continuing without a controller"; return 0; }
        sed -i "s|device='[0-9]*'|device='${devnum}'|" "$xml"
    done

    warn "could not attach the Xbox dongle after 3 attempts — continuing without a controller"
}

# Current USB device number of the dongle, or empty if absent.
dongle_devnum() {
    local d
    for d in /sys/bus/usb/devices/*/; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(cat "$d/idVendor")" == "$XSYNC_DONGLE_VENDOR" ]] || continue
        [[ "$(cat "$d/idProduct")" == "$XSYNC_DONGLE_PRODUCT" ]] || continue
        cat "$d/devnum"
        return 0
    done
    return 1
}

vm_start() {
    need_root
    set_phase START_VM

    vm_defined || die "domain '$XSYNC_VM_NAME' is not defined — run tools/xsync-setup"

    if vm_running; then
        warn "VM already running"
        return 0
    fi

    # What to launch is not baked in here: the orchestrator drives it over
    # qemu-guest-agent once the guest is actually up (see guest.sh).
    log "starting VM $XSYNC_VM_NAME"
    if ! $VIRSH start "$XSYNC_VM_NAME"; then
        error "virsh start failed"
        return 1
    fi

    # Wait for the domain to actually be running before handing control on.
    local waited=0
    while ! vm_running && (( waited < 30 )); do
        sleep 1
        (( waited++ ))
    done
    vm_running || { error "VM did not reach running state"; return 1; }

    # The dongle now arrives via the passed-through USB controller (see
    # XSYNC_USB_PCI); per-device attach is only used when that is disabled.
    if [[ -z "${XSYNC_USB_PCI:-}" ]]; then dongle_attach; fi

    log "VM running"
    return 0
}

vm_stop() {
    need_root
    set_phase STOP_VM

    if vm_gone; then
        log "VM already off"
        return 0
    fi

    log "requesting graceful shutdown (state: $(vm_state))"
    $VIRSH shutdown "$XSYNC_VM_NAME" >/dev/null 2>&1 || true

    # Wait for "shut off" specifically, not merely "no longer running".
    local waited=0
    while ! vm_gone && (( waited < XSYNC_SHUTDOWN_TIMEOUT )); do
        sleep 1
        (( waited++ ))
    done

    if ! vm_gone; then
        warn "no clean shutdown after ${waited}s (state: $(vm_state)) — destroying"
        $VIRSH destroy "$XSYNC_VM_NAME" >/dev/null 2>&1 || true
        # destroy is asynchronous; keep waiting for the process to actually go.
        waited=0
        while ! vm_gone && (( waited < 30 )); do
            sleep 1
            (( waited++ ))
        done
    else
        log "VM shut down cleanly after ${waited}s"
    fi

    if ! vm_gone; then
        error "VM still present after destroy (state: $(vm_state)) — GPU is NOT safe to reclaim"
        return 1
    fi
    return 0
}

vm_kill() {
    need_root
    log "force-destroying VM (state: $(vm_state))"
    $VIRSH destroy "$XSYNC_VM_NAME" >/dev/null 2>&1 || true
    local waited=0
    while ! vm_gone && (( waited < 30 )); do
        sleep 1
        (( waited++ ))
    done
    vm_gone
}

# Block until QEMU is genuinely gone.
#
# An optional timeout bounds the wait. Without one a guest that never shuts
# itself down (a hung game, a watcher that lost its exit condition) would leave
# the host session torn down indefinitely.
vm_wait() {
    local limit="${1:-0}" waited=0
    while ! vm_gone; do
        sleep 2
        (( waited += 2 ))
        if (( limit > 0 && waited >= limit )); then
            warn "VM still present after ${waited}s (limit ${limit}s)"
            return 1
        fi
    done
    log "VM is off"
    return 0
}

case "${1:-status}" in
    start)   vm_start "${2:-}" ;;
    stop)    vm_stop ;;
    kill)    vm_kill ;;
    wait)    vm_wait "${2:-0}" ;;
    status)  echo "$XSYNC_VM_NAME: $(vm_state)" ;;
    # These exit non-zero rather than printing, so callers can branch on them
    # instead of grepping status text (which always exited 0 and so silently
    # defeated every preflight guard that used it).
    state)   vm_state ;;
    defined) vm_defined ;;
    profile) vm_profile ;;
    gone)    vm_gone ;;
    alive)   vm_alive ;;
    running) vm_running ;;
    *) echo "usage: $0 {start <game-id>|stop|kill|wait [timeout]|status|state|defined|profile|gone|alive|running}" >&2; exit 64 ;;
esac
