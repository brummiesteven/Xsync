# xsync — status

Read `PLAN.md` for the architecture and `docs/FINDINGS.md` for everything learned
during bring-up. Most of FINDINGS is non-obvious and expensive to rediscover.

Last updated: 2026-07-27.

---

## Where things stand

**The pipeline works end to end.** A launch from Steam hands the GPU to the VM,
boots Windows, starts the game, and — when the game exits — powers the VM off,
takes the GPU back, syncs the Steam library and restores the session.

Verified working on the reference machine:

- [x] Windows 11 installed unattended, debloated, Game Pass provisioned
- [x] Xbox app signed in, a 145 GB title installed and launching on the
      passed-through GPU
- [x] GPU release → vfio-pci → VM → reclaim → host driver, repeatedly, no wedges
- [x] Game enumeration → `shortcuts.vdf` → Steam, with SteamGridDB artwork
- [x] Clean session teardown and restore, including `systemctl stop` mid-session
- [x] Exit chain: game exits → guest shuts down → VM off → GPU back → sync → restore
- [x] Xbox dongle reaching the guest via USB controller passthrough, and every
      USB device returning to the host afterwards
- [x] Nothing but black on the TV between the handoff and the game appearing

Measured timings:

- trigger → VM running: **5-15s**
- VM start → guest agent reachable: **6-16s**
- game exit → gaming mode back on the TV: **12-16s**
- gamescope restored after GPU reclaim: **2s**

---

## The one thing to know

The reference machine drives a **TV, not a monitor**, and that shapes the design.
Every handoff drops the HDMI signal twice, and a TV that loses signal goes to
standby. A TV in standby stops answering on the DDC lines, so the connector reads
`disconnected` with a 0-byte EDID and gamescope has no output to start on.

NVIDIA exposes no CEC adapter, so **the TV cannot be woken from software**. This
was hit for real: the TV switched off overnight, gaming mode could not restart,
and SteamOS fell back to the desktop.

`xsync-display-watch` handles it. Switch the TV on and gaming mode returns
automatically within about ten seconds.

If it ever does not:

```bash
rm -f /tmp/chimeraos-short-session-tracker
printf '[Autologin]\nSession=gamescope-session.desktop\n' | sudo tee /etc/sddm.conf.d/zz-steamos-autologin.conf
sudo systemctl restart sddm
```

---

## Nothing visible before the game

The GPU and the display are the same cable, so the host cannot keep drawing once
the GPU is handed over — there is no way to keep Steam on screen while the VM
boots. What xsync does instead is make every stage in between render as black.

Verified by capturing every frame of a cold boot with `virsh screenshot`: **40 of
45 frames are pure black** (mean 0, max 0). The desktop itself is black at every
point and stays black across a power cycle. Windows contributes nothing: the boot
animation is off (`bcdedit /set {globalsettings} bootuxdisabled on`) and the
sign-in screen is forced to flat black.

Two things survived that. The TianoCore firmware logo is handled by
`XSYNC_HIDE_FIRMWARE_LOGO` (default on), which hides the GPU's option ROM from
the guest: with no emulated display in the play profile, the ROM's GOP driver is
the only thing OVMF can draw with, so removing it leaves the firmware with no
graphics console and nothing to draw.

Verified on a real launch. The card comes up perfectly well without its ROM —
`NVIDIA GeForce RTX 4090 | status=OK | 3840x2160 | drv=32.0.15.9636` — and no
display device is in a problem state. It is also *faster*: the guest agent
answered **23s** after VM start against **31s** with the ROM attached, because
the firmware no longer initialises a graphics console it is only going to draw a
logo on. Set the key to 0 to get the firmware console back if a future driver
ever regresses on this.

The other is a brief dim sign-in fade, and that one is not fixable here:
`HideAutoLogonUI` is an Enterprise/IoT setting and this guest is Windows 11 Pro.

A guest-side splash video was built to cover the gap and then **removed**. It is
triggered at logon, so it could only ever start after the firmware phase and the
sign-in screen — the two things actually worth covering — and by then there is
nothing left to hide but black. See `docs/FINDINGS.md`.

Deferring the GPU attach — booting the VM headless and hot-plugging the GPU once
the guest is up — was prototyped and **abandoned**. The device attaches and
Windows enumerates it, but the driver will not start on a hot-added GPU
(`Video Controller (VGA Compatible)`, status Error), because a hot-plugged
device cannot enlarge its bridge's 64-bit prefetchable window after the fact.
See `docs/FINDINGS.md`.

---

## Test results

`sudo tools/xsync-test run safe` — **30 assertions, 0 failures**.
`sudo tools/xsync-test run all` adds the disruptive suite (blanks the TV).

| Test | What it proves |
|---|---|
| config / tooling | units, sudoers, exec bits all installed |
| guest scripts are ASCII | no BOM-less UTF-8 that PS 5.1 can mis-parse |
| GPU ownership | host owns the GPU at rest; IOMMU group isolated |
| libvirt state semantics | "running" is never mistaken for gone |
| shortcuts.vdf codec | round-trips exactly; refuses to rewrite a corrupt file |
| game id validation | command injection via a Steam shortcut is rejected |
| concurrency lock | a second launch cannot race the first |
| session cycle | teardown and restore, Steam returns |
| GPU cycle | release to vfio-pci and reclaim, repeatedly |
| recover from stuck GPU | the black-TV scenario recovers unattended |
| full handoff | launch → VM → guest → exit → GPU back → session back |
| watchdog kill | QEMU destroyed mid-session; host recovers in 5s |

---

## Known limitations

- **4K120 does not negotiate** on the reference display. The TV advertises
  3840x2160@120 and HDMI 2.1 FRL in its EDID, but the same EDID reports a
  maximum TMDS character rate of 600 MHz — HDMI 2.0, which caps 4K at 60. Every
  mode above 60 Hz returns `DISP_CHANGE_BADMODE`. This is a cable or TV-input
  setting, not an xsync problem. `xsync-display.ps1` now falls back through the
  available rates rather than giving up.
- **No Steam overlay during play.** By construction — the host session is gone.
  Exit is handled by the guest agent plus a host-side monitor.
- **Anti-cheat titles will not work**, and xsync will not ship VM masking.
- **No detection wizard.** Every value in `config/xsync.conf` is set by hand.

---

## Not yet done

**Performance numbers.** The GPU is confirmed working in the guest — full VRAM,
driving 4K, ~87% utilisation and 2520 MHz under load. But the test title opens on
an attract screen that waits for a gamepad button, and synthetic input does not
satisfy it. Someone has to press A. Forza ships an in-game benchmark; use that
for repeatable figures.

**Xbox Full Screen Experience.** `guest/agent/xsync-fse.ps1` is written and
parse-checked but deliberately **not applied**. It rewrites feature flags and
`DeviceForm`, needs a guest reboot, and its result can only be judged by looking
at the TV. It also re-binds the Guide button to the FSE task switcher, which
would disable xsync's own Guide exit overlay. To enable:

```bash
sudo /var/lib/xsync/app/host/bin/guest.sh run-user \
     /var/lib/xsync/app/guest/agent/xsync-fse.ps1
# then reboot the guest; Win+F11 toggles Xbox mode
```

**Guide-button exit overlay.** Implemented, not exercised — it needs a real
controller held for two seconds.

---

## Working on the guest without taking the TV

The `maint` profile boots the installed guest with a virtio display on VNC and
no passthrough, so the host session is undisturbed.

```bash
sudo tools/xsync-setup vm maint
sudo virsh start xsync-win11
sudo virsh screenshot xsync-win11 /tmp/guest.ppm
sudo /var/lib/xsync/app/host/bin/guest.sh run-user guest/agent/xsync-appearance.ps1
sudo virsh shutdown xsync-win11
sudo tools/xsync-setup vm play      # ALWAYS switch back
```

`xsync-session` refuses to start a handoff unless the domain is on the `play`
profile, and `xsync-doctor` reports which profile is active.

---

## Commands

```bash
sudo tools/xsync-doctor              # health check
sudo tools/xsync-test run safe       # non-disruptive assertions
sudo tools/xsync-test run disruptive # blanks the TV; needs it switched on

# Launch a game exactly as Steam does
sudo systemctl start --no-block xsync-session@<game-id>.service
sudo journalctl -u xsync-session@<game-id>.service -f

# Recover from anything
sudo /var/lib/xsync/app/host/bin/xsync-recover
```
