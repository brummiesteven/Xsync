#!/usr/bin/bash
# xsync — guided installer.
#
#   ./install.sh            walk through setup, stopping at anything that needs you
#   ./install.sh --check    report what is done and what is left, change nothing
#
# This does NOT autodetect your hardware. It cannot: passing the wrong PCI
# address to VFIO takes down the display of the machine you are typing on. What
# it does is sequence the steps, refuse to run one before its prerequisites are
# met, and tell you exactly which value to fill in and where.
#
# Safe to re-run. Every step checks whether it is already done.

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# Overridable so the prompt flow can be exercised against a throwaway config
# instead of the real one, which holds the user's secrets.
CONF="${XSYNC_CONF:-$HERE/config/xsync.conf}"
EXAMPLE="$HERE/config/xsync.conf.example"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

b()    { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mstopped:\033[0m %s\n' "$*" >&2; exit 1; }

say_step() { printf '\n'; b "$*"; }

# Root is needed for most of this, but NOT for the first steps -- and asking for
# it up front would mean the config file ends up owned by root, which is the one
# file the user has to keep editing.
as_root() {
    if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------- 1. platform

say_step "1. Platform"

if [[ ! -r /proc/cpuinfo ]]; then die "this is not a Linux machine"; fi

if grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo; then
    ok "CPU virtualisation extensions present"
else
    bad "no vmx/svm in /proc/cpuinfo — enable virtualisation in firmware first"
    die "hardware virtualisation is not available"
fi

if [[ -d /sys/kernel/iommu_groups ]] && [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
    ok "IOMMU is on ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
    IOMMU_OK=1
else
    todo "IOMMU is off — this needs kernel args and a reboot (step 4)"
    IOMMU_OK=0
fi

for c in virsh qemu-system-x86_64 jq python3; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c present"
    else bad "$c missing — install libvirt/qemu/jq/python3 for your distro"; MISSING=1; fi
done
[[ -n "${MISSING:-}" ]] && die "install the missing packages and re-run"

# ---------------------------------------------------------------- prompting

# Read the current value of a key from the config.
conf_get() {
    grep -E "^$1=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' '
}

# Write a key, replacing any existing line. Written with a temp file and mv so a
# failure part-way cannot leave a half-rewritten config holding the user's
# secrets.
conf_set() {
    local k="$1" v="$2" tmp
    tmp="$(mktemp)"
    if grep -qE "^$k=" "$CONF" 2>/dev/null; then
        sed "s|^$k=.*|$k=$v|" "$CONF" >"$tmp"
    else
        cat "$CONF" >"$tmp" 2>/dev/null || true
        printf '%s=%s\n' "$k" "$v" >>"$tmp"
    fi
    chmod 0640 "$tmp"
    mv "$tmp" "$CONF"
}

# Ask for one value, offering a detected default.
#
#   ask <key> <prompt> <default> [secret]
#
# Enter accepts the default. A blank default means the answer is required, and
# it will keep asking -- these are values with no sane fallback, and guessing one
# produces a broken install that fails much later with an unrelated message.
ask() {
    local key="$1" prompt="$2" default="$3" secret="${4:-}" reply
    while :; do
        if [[ -n "$default" ]]; then
            printf '  %s\n    [%s]: ' "$prompt" "$default"
        else
            printf '  %s\n    : ' "$prompt"
        fi
        if [[ "$secret" == "secret" ]]; then read -r reply; else read -r reply; fi
        reply="${reply:-$default}"
        if [[ -z "$reply" ]]; then
            printf '    this one has no default and is required\n'
            continue
        fi
        conf_set "$key" "$reply"
        if [[ "$secret" == "secret" ]]; then ok "$key set"; else ok "$key=$reply"; fi
        return 0
    done
}

# Best guesses, so most answers are just Enter.
detect_gpu()       { lspci -D 2>/dev/null | grep -i 'vga compatible' | head -1 | cut -d' ' -f1; }
detect_gpu_audio() {
    local g; g="$(detect_gpu)"
    [[ -z "$g" ]] && return
    # The HDMI audio function is the same device at function .1.
    lspci -D 2>/dev/null | grep -i 'audio device' | grep "^${g%.*}." | head -1 | cut -d' ' -f1
}
detect_usb()  { "$HERE/tools/xsync-find-usb" 2>/dev/null | grep -oP 'XSYNC_USB_PCI=\K\S+' | head -1; }
detect_user() { echo "${SUDO_USER:-$USER}"; }
detect_steam() {
    local u; u="$(detect_user)"
    for d in "/var/home/$u/.local/share/Steam" "/home/$u/.local/share/Steam" \
             "/var/home/$u/.steam/steam" "/home/$u/.steam/steam"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
    echo "/var/home/$u/.local/share/Steam"
}

# ---------------------------------------------------------------- 2. config

say_step "2. Configuration"

if [[ -f "$CONF" ]]; then
    ok "config exists: $CONF"
else
    if (( CHECK_ONLY )); then
        todo "no config yet — would copy from the example"
    else
        cp "$EXAMPLE" "$CONF" && chmod 0640 "$CONF"
        ok "created $CONF from the example (mode 0640 — it will hold secrets)"
    fi
fi

# Values that have no safe default and that xsync cannot guess.
NEEDED=(XSYNC_GPU_PCI XSYNC_GPU_AUDIO_PCI XSYNC_USB_PCI XSYNC_USER XSYNC_STEAM_ROOT)
UNSET=()
if [[ -f "$CONF" ]]; then
    for k in "${NEEDED[@]}"; do
        v="$(grep -E "^${k}=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
        [[ -z "$v" ]] && UNSET+=("$k")
    done
fi

if (( ${#UNSET[@]} )); then
    if (( CHECK_ONLY )); then
        bad "these still need values in $CONF:"
        for k in "${UNSET[@]}"; do printf '      %s\n' "$k"; done
        printf '\n'
        todo "run ./install.sh (without --check) to be asked for them"
        exit 1
    fi

    printf '\n'
    b "  A few things xsync cannot work out on its own."
    printf '  Press Enter to accept a suggestion in brackets.\n\n'

    for k in "${UNSET[@]}"; do
        case "$k" in
        XSYNC_GPU_PCI)
            printf '\n'
            lspci -D 2>/dev/null | grep -iE 'vga compatible|3d controller' | sed 's/^/      /'
            ask XSYNC_GPU_PCI "Which GPU should the guest take over?" "$(detect_gpu)"
            ;;
        XSYNC_GPU_AUDIO_PCI)
            printf '\n'
            lspci -D 2>/dev/null | grep -i 'audio device' | sed 's/^/      /'
            ask XSYNC_GPU_AUDIO_PCI \
                "Its HDMI audio function (sound follows the video cable)" "$(detect_gpu_audio)"
            ;;
        XSYNC_USB_PCI)
            printf '\n'
            "$HERE/tools/xsync-find-usb" 2>/dev/null | sed 's/^/      /' || true
            printf '\n'
            ask XSYNC_USB_PCI \
                "Which USB controller carries your gamepad? (it leaves the host during a game)" \
                "$(detect_usb)"
            ;;
        XSYNC_USER)
            ask XSYNC_USER "Which user runs Steam?" "$(detect_user)"
            ;;
        XSYNC_STEAM_ROOT)
            ask XSYNC_STEAM_ROOT "Where is that user's Steam directory?" "$(detect_steam)"
            ;;
        *)
            ask "$k" "$k" ""
            ;;
        esac
    done
    printf '\n'
fi

# Optional, but the install goes better if they are answered now rather than
# discovered as a failure three steps later.
if ! (( CHECK_ONLY )); then
    if [[ -z "$(conf_get XSYNC_SGDB_API_KEY)" ]]; then
        printf '\n'
        b "  SteamGridDB API key (optional)"
        printf '      Without it, shortcuts get plain generated artwork instead of\n'
        printf '      real cover art. Free key: https://www.steamgriddb.com/profile/preferences/api\n'
        printf '      Leave blank to skip.\n'
        printf '    : '
        read -r sgdb
        if [[ -n "$sgdb" ]]; then conf_set XSYNC_SGDB_API_KEY "$sgdb"; ok "artwork key set"
        else todo "no key — artwork will be generated locally"; fi
    fi

    if [[ -z "$(conf_get XSYNC_WINDOWS_KEY)" ]]; then
        printf '\n'
        b "  Windows product key (optional)"
        printf '      Leave blank to install unactivated — Windows runs fine, with a\n'
        printf '      watermark and some personalisation locked. You can activate later\n'
        printf '      in Settings > System > Activation.\n'
        printf '\n'
        printf '      If blank, setup uses Microsoft'"'"'s published generic Pro key purely to\n'
        printf '      choose the edition. It grants no licence and activates nothing —\n'
        printf '      it exists because unattended setup stops dead on the product-key\n'
        printf '      screen if no key is present at all.\n'
        printf '    : '
        read -r winkey
        if [[ -n "$winkey" ]]; then
            conf_set XSYNC_WINDOWS_KEY "$winkey"
            ok "product key set — Windows will activate with it"
        else
            todo "no key — Windows will install unactivated"
        fi
    fi

    win_iso="$(conf_get XSYNC_WINDOWS_ISO)"
    if [[ -z "$win_iso" || ! -f "$win_iso" ]]; then
        printf '\n'
        b "  Windows 11 ISO"
        printf '      Not shipped with xsync — it is 5+ GB and not redistributable.\n'
        printf '      tools/xsync-fetch-iso downloads it from Microsoft directly.\n'
        printf '      Give a path (existing file, or where it should be saved).\n'
        ask XSYNC_WINDOWS_ISO "Windows 11 ISO path" "${win_iso:-/var/lib/xsync/iso/win11.iso}"
    fi

    virtio_iso="$(conf_get XSYNC_VIRTIO_ISO)"
    if [[ -z "$virtio_iso" || ! -f "$virtio_iso" ]]; then
        printf '\n'
        b "  virtio-win driver ISO"
        printf '      Windows Setup cannot see the virtual disk without it and stops\n'
        printf '      at "no drives found".\n'
        ask XSYNC_VIRTIO_ISO "virtio-win ISO path" "${virtio_iso:-/var/lib/xsync/iso/virtio-win.iso}"
    fi
    printf '\n'
fi

ok "all required values are set"

# ---------------------------------------------------------------- 3. doctor

say_step "3. Preflight"

if [[ -x "$HERE/tools/xsync-doctor" ]]; then
    if "$HERE/tools/xsync-doctor" >/dev/null 2>&1; then
        ok "xsync-doctor reports no failures"
    else
        todo "xsync-doctor found problems — showing them now"
        "$HERE/tools/xsync-doctor" || true
        printf '\n'
        todo "fix anything marked ✗, then re-run ./install.sh"
        (( CHECK_ONLY )) || exit 1
    fi
fi

# ---------------------------------------------------------------- 4. install

say_step "4. Host install"

# ALWAYS re-run the installer, never skip because a unit file happens to exist.
#
# Treating "the unit exists" as "installed and current" meant an upgrade did
# nothing at all. Every runtime entry point executes out of /var/lib/xsync/app,
# which is refreshed only by `xsync-setup install` -- so a user who git-pulled a
# fix and ran ./install.sh as the README instructs got "systemd units installed"
# and "setup is complete" while continuing to run the OLD code, with the OLD
# sudoers rule. That included the sudoers wildcard that permitted passwordless
# start of arbitrary systemd units: pulling the security fix and running the
# documented command left the machine exactly as vulnerable as before, and said
# it was fine.
#
# xsync-setup install is idempotent by design, so re-running costs a second.
if (( CHECK_ONLY )); then
    if [[ -f /etc/systemd/system/xsync-session@.service ]]; then
        ok "systemd units installed"
        if ! cmp -s "$HERE/host/bin/xsync-session" /var/lib/xsync/app/host/bin/xsync-session 2>/dev/null; then
            todo "the installed copy differs from this checkout — run ./install.sh to update it"
        fi
    else
        todo "would run: sudo tools/xsync-setup install"
    fi
else
    as_root "$HERE/tools/xsync-setup" install || die "xsync-setup install failed"
    ok "units, sudoers rule and deployed copy are up to date"
fi
UNITS_OK=1

if (( IOMMU_OK == 0 )); then
    if (( CHECK_ONLY )); then
        todo "would run: sudo tools/xsync-setup kargs, then reboot"
    else
        as_root "$HERE/tools/xsync-setup" kargs || die "could not set kernel args"
        printf '\n'
        b "  REBOOT REQUIRED"
        todo "IOMMU kernel args are staged. Reboot, then re-run ./install.sh"
        exit 0
    fi
fi

# ---------------------------------------------------------------- 5. guest

say_step "5. Windows guest"

DISK="$(grep -E '^XSYNC_VM_DISK=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')"
DISK="${DISK:-/var/lib/xsync/win11.raw}"

if as_root test -f "$DISK" 2>/dev/null; then
    ok "guest disk exists: $DISK"
    if as_root virsh --connect qemu:///system dominfo xsync-win11 >/dev/null 2>&1; then
        prof="$(as_root "$HERE/host/bin/vm.sh" profile 2>/dev/null | tail -1)"
        ok "domain defined (profile: ${prof:-unknown})"
        if [[ "$prof" != "play" ]]; then
            todo "switch to passthrough when the guest is ready: sudo tools/xsync-setup vm play"
        fi
    else
        todo "define the domain: sudo tools/xsync-setup vm install"
    fi
else
    # Check the media before telling anyone to run the installer.
    #
    # These two paths are not in the required-values check at step 2, because a
    # host install is perfectly valid without them. The cost was that a user got
    # all the way through configuration, kernel args and a reboot before finding
    # out they had no ISO -- xsync-install-windows does check, but by then it is
    # the fourth thing they have been asked to do rather than the first.
    WIN_ISO="$(grep -E '^XSYNC_WINDOWS_ISO=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')"
    VIRTIO_ISO="$(grep -E '^XSYNC_VIRTIO_ISO=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')"

    todo "no guest yet. Windows needs installing into the VM."
    printf '\n'

    if [[ -n "$WIN_ISO" && -f "$WIN_ISO" ]]; then
        ok "Windows ISO: $WIN_ISO ($(du -h "$WIN_ISO" 2>/dev/null | cut -f1))"
    else
        bad "Windows 11 ISO missing${WIN_ISO:+ (XSYNC_WINDOWS_ISO=$WIN_ISO)}"
        printf '        fetch it:  sudo tools/xsync-fetch-iso --out /var/lib/xsync/win11.iso\n'
        printf '        then set:  XSYNC_WINDOWS_ISO=/var/lib/xsync/win11.iso\n'
    fi

    if [[ -n "$VIRTIO_ISO" && -f "$VIRTIO_ISO" ]]; then
        ok "virtio-win ISO: $VIRTIO_ISO ($(du -h "$VIRTIO_ISO" 2>/dev/null | cut -f1))"
    else
        bad "virtio-win ISO missing${VIRTIO_ISO:+ (XSYNC_VIRTIO_ISO=$VIRTIO_ISO)}"
        printf '        Windows Setup cannot see the virtio disk without it, so the\n'
        printf '        install stops at "no drives found".\n'
        printf '        fetch it:  curl -Lo /var/lib/xsync/virtio-win.iso \\\n'
        printf '                     https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso\n'
        printf '        then set:  XSYNC_VIRTIO_ISO=/var/lib/xsync/virtio-win.iso\n'
    fi

    printf '\n'
    if [[ -n "$WIN_ISO" && -f "$WIN_ISO" && -n "$VIRTIO_ISO" && -f "$VIRTIO_ISO" ]]; then
        todo "both ISOs present — install Windows: sudo tools/xsync-install-windows"
    else
        todo "get the ISOs above, set their paths in $CONF, then re-run ./install.sh"
    fi
fi

# ---------------------------------------------------------------- done

printf '\n'
b "Where you are"
if [[ ! -f "$DISK" ]] 2>/dev/null; then
    todo "build the guest (step 5), then re-run ./install.sh"
elif [[ "${prof:-}" != "play" ]]; then
    todo "sign into the Xbox app in the guest, then: sudo tools/xsync-setup vm play"
else
    ok "setup is complete — launch Xbox from Steam Big Picture"
    printf '      Install a game, quit, and it appears in your library.\n'
fi
printf '\n'
printf '  Recovery, if a handoff ever leaves the TV black:\n'
printf '      ssh %s@<this machine>\n' "${SUDO_USER:-$USER}"
printf '      sudo systemctl start xsync-recover.service\n\n'
