# xsync — findings from end-to-end bring-up

Everything below was observed on the reference machine (Bazzite 43, Ryzen 9 7950X,
RTX 4090, 4K Samsung TV on HDMI-A-2) while getting Forza Horizon 6 running from
Steam Big Picture. Recorded because most of it is non-obvious, and every item
cost real time to diagnose.

---

## The two bugs that broke the core promise

### 1. The VM never shut down when a game exited

`Get-GameProcesses` ends with `return @(...)`, which looks like it always yields
an array. PowerShell unrolls arrays on output, so when exactly one process
matches — the normal case, since most games are a single executable — the caller
receives a bare `Process` object. Reading `.Count` on that throws under
`Set-StrictMode -Version Latest`.

The watcher therefore threw on its very first check and died silently. The game
would finish, nothing would notice, and the VM kept running and holding the GPU
indefinitely.

**Fix:** wrap every call site in `@(...)`. Also added a host-side exit monitor so
shutdown never depends on a single process staying alive inside the guest.

### 2. Game state was invisible to the host

Even with the above fixed, `status` reported `playing:false` while the game was
running. The host queries over qemu-guest-agent, which executes as **Local
System**, and reading `.Path` on a packaged (MSIX) game's process is denied even
for SYSTEM. The `catch` swallowed it and reported "not running".

**Fix:** match on the executable name (from `MicrosoftGame.config`) before
falling back to path matching.

---

## Session-boundary problems (a whole class)

qemu-guest-agent runs everything as Local System. These all fail there, silently:

| Operation | Symptom as SYSTEM | Fix |
|---|---|---|
| AppX registration | `0x80073CF9` "not allowed" | user session, **elevated** |
| `Get-AppxPackage` | returns almost nothing | user session |
| `Get-AppxPackageManifest` | no AUMID → every game skipped | user session, **elevated** |
| Launching a packaged app | task succeeds, no window appears | user session, **unelevated** |

Elevation matters in **both** directions: UWP/MSIX apps refuse to launch from an
elevated process, while AppX queries require admin. `Invoke-InUserSession` takes
an explicit `-Elevated` switch for exactly this reason.

---

## Bazzite / SteamOS specifics

### The short-session tracker will disable gaming mode

`gamescope-session-plus` appends a line to
`/tmp/chimeraos-short-session-tracker` whenever the session ends within 60
seconds. At five entries it decides Steam or gamescope is broken, prints
*"detected broken steam or gamescope failure"*, and calls
`steamos-session-select desktop` — permanently switching the machine to KDE.

xsync stops the session deliberately on every launch, so ordinary use trips this.
`session.sh` now clears the tracker on both teardown and restore.

### Autologin gets rewritten

The session that runs at boot is decided by
`/etc/sddm.conf.d/zz-steamos-autologin.conf`. The `zz-` prefix means it overrides
`steamos.conf`, and anything that fails writes the Plasma one-shot session there.
`session.sh` asserts the gamescope session explicitly rather than assuming.

### SELinux blocks systemd from /var/lib

Files created under `/var/lib` inherit `var_lib_t`, and systemd (`init_t`) is not
permitted to execute that type. The failure surfaces as a bare
`Permission denied ... status=203/EXEC`, which reads like a file-mode problem and
is not. Install relabels the executables `bin_t`.

---

## The TV is not a monitor, and that matters

The single most disruptive discovery.

When the HDMI signal disappears — which happens on **every** handoff, in both
directions — the TV drops to standby. A TV in standby stops answering on the DDC
lines, so:

- the connector reads `disconnected` with a **0-byte EDID**
- the NVIDIA driver logs `[drm] Cannot find any crtc or sizes`
- gamescope has no output and cannot start
- SteamOS then falls back to the desktop session

NVIDIA registers no CEC adapter (only amdgpu and i915 do), so **the TV cannot be
woken from software**. A function-level PCI reset, a full remove/rescan, and
forcing `nvidia_drm modeset=1` were all tried; none help, because the GPU is
healthy and the problem is that nothing is listening.

Mitigations now in place:

- `xsync-display-watch` — a system service that notices the moment the display
  returns and restores gaming mode automatically.
- `gpu.sh` waits for the display after reclaim and says plainly when the TV has
  not come back, rather than starting a session with nowhere to draw.

The VM's own output **does** wake the TV from standby if the TV is merely
sleeping. If it has been switched off at the set, nothing can wake it.

Note also: `nvidia_drm` must load with `modeset=1`, and it has to be a modprobe
*option* — `/usr/lib/modprobe.d/nvidia.conf` declares
`softdep nvidia post: nvidia-drm`, so the module is already loaded by the time a
`modprobe nvidia_drm modeset=1` command line would apply. Installed as
`/etc/modprobe.d/xsync-nvidia.conf`.

---

## 4K120: the TV supports it, the link does not

The EDID advertises the right modes and HDMI 2.1 capability:

```
VIC 118:  3840x2160  120.000000 Hz   270.000 kHz   1188.000000 MHz
Max Fixed Rate Link: ... 6, 8 and 10 Gbps on 4 lanes
```

But the same EDID block reports:

```
Maximum TMDS Character Rate: 600 MHz
```

600 MHz is HDMI 2.0 territory and caps 4K at 60 Hz. 4K120 requires FRL, which is
not being negotiated. Inside the guest, Windows lists 144/120/100 Hz modes at
3840x2160 but every attempt to apply one returns `DISP_CHANGE_BADMODE`, and it
stays at 4K60.

This is a cable or port issue, not a VM or xsync one. In order of likelihood:

1. The HDMI cable is not an Ultra High Speed (48 Gbps) certified cable.
2. The TV's port needs its enhanced HDMI mode enabled — on Samsung sets this is
   *Input Signal Plus* (older models: *HDMI UHD Color*), set per-input.

Worth checking both; the ceiling is 4K60 until FRL negotiates.

---

## Game-specific: Forza Horizon 6

- Shows a **"Forza Horizon 6 Compatibility Warning"** dialog on first launch in
  the VM and waits for input. Until it is dismissed the game sits at 0% GPU
  looking like a hang. The dialog has *Ignore Warning* / *Don't show again* /
  *More Information*; ticking "Don't show again" persists the choice.
- Ships `BenchmarkDefinition.x64.Release.dll` — it has a built-in benchmark,
  which is the right tool for repeatable performance numbers.
- Install is 156.76 GB of disk for ~145 GB of game.

---

## Windows install gotchas

| Symptom | Cause |
|---|---|
| Setup stops at "Select language" | answer file used `en-GB` against en-US media; setup silently discards the whole windowsPE pass |
| Setup stops at "Product key" | omitting `<ProductKey>` does **not** skip the prompt; a generic edition-selection key is required |
| "No bootable option or device" | the ISO waits for a keypress at "Press any key to boot from CD" |
| Guest script fails with a bogus parse error | UTF-8 **without BOM**; PowerShell 5.1 decodes as Windows-1252 and turns `—` into a smart quote that acts as a string delimiter |
| `pwsh` says a script is fine but the guest disagrees | pwsh 7 assumes UTF-8; Windows PowerShell 5.1 does not. Parse-checking is necessary but not sufficient |
| `@` types as `2` over VNC | QEMU's VNC keymap must match the guest layout |

Microsoft's ISO download API also requires an `ov-df.microsoft.com` device
fingerprint handshake (fetch `mdt.js`, echo back `w` and `rticks`) before
`GetProductDownloadLinksBySku` will answer. Without it every request is rejected
with "Sentinel marked this request as rejected". Implemented in
`tools/xsync-fetch-iso`.

---

## USB: pass the controller, not the device

Attaching the Xbox wireless dongle as a USB hostdev does not work, and fails in a
way that looks like success from every angle.

1. `managed='yes'` does not reliably detach the host driver. `xone-dongle` keeps
   its grip on the interface while libvirt still reports the hostdev attached.
2. Unbinding it by hand makes the device re-enumerate, which changes its USB
   device number.
3. libvirt resolves vendor/product to a concrete `bus`/`device` address once, at
   attach time. Attaching **itself** resets the device, so the address is stale
   the instant it is recorded.

Observed directly: successive attach attempts chased the device number 22 → 23 →
24 → 25 and never converged. The host logs "dongle attached", the domain lists
the hostdev, and the guest has no controller.

**Passing the whole USB controller as a PCI device solves it**, because
enumeration then happens inside the guest. On the reference machine `0a:00.0` is
alone in IOMMU group 20 and carries the dongle, the Bluetooth radio and the
wireless keyboard. Handing all three over is not a problem — the host session is
stopped during play and does not need them — and the guest gains Bluetooth,
which is a second route to pairing a controller.

Verified: the guest shows *Xbox Wireless Adapter for Windows* with status OK, and
all three devices return to the host when the session ends.

### Do NOT also blacklist the host driver

An early version of this paired controller passthrough with
`blacklist xone_dongle`, reasoning that the host should never touch a device the
guest owns. That was wrong, and it cost the user their controller.

Under controller passthrough the blacklist is unnecessary — unbinding `xhci_hcd`
from the PCI device disconnects every child device and releases their drivers
cleanly, whether or not `xone-dongle` was bound. It is also actively harmful:

**A dongle with no driver bound never receives its firmware, so it goes
completely inert — no LED, and the pair button does nothing.** It presents
exactly like failed hardware. `lsusb` still lists the device, so enumeration is
not evidence that the dongle works; the real check is whether anything is bound:

```bash
readlink /sys/bus/usb/devices/*/driver | grep xone-dongle
```

The blacklist is only correct in the fallback path where individual USB devices
are attached (`XSYNC_USB_PCI` empty), and there it costs the host its dongle.
`tools/xsync-setup` now picks per strategy, and removes a stale blacklist file
when controller passthrough is in use.

Leaving the driver loaded is better than merely harmless: the host needs the
dongle for native Steam gaming, and a controller paired to the dongle rather than
to host Bluetooth simply follows the dongle across a handoff.

Firmware on Bazzite is `/lib/firmware/xone_dongle_02e6.bin.xz`, not the older
`xow_dongle.bin` name — checking for the latter reports a false negative.

## Nothing should be visible between the handoff and the game

There is exactly one GPU and one display, so the instant the 4090 is unbound from
nvidia the host can draw nothing at all. There is no way to keep Steam on screen
while the VM boots, and no amount of sequencing changes that.

What CAN be removed is everything the guest would otherwise put on the TV before
the game appears. Left alone that is: the OVMF boot menu, the Windows boot
animation, the sign-in spinner, and a desktop with wallpaper, icons and a
taskbar. Rendering all of it black gives the same result the user actually wants
— the TV shows nothing until the game takes over.

- `<bootmenu enable='no'/>` in the play profile. It was `enable='yes'
  timeout='3000'`, which put a firmware menu on the TV for three seconds at the
  start of every launch. Nobody presses F12 from a sofa. The install profile
  keeps it.
- `bcdedit /set {globalsettings} bootuxdisabled on` plus `quietboot on` for the
  Windows boot animation.
- `guest/agent/xsync-appearance.ps1` for the desktop: empty wallpaper +
  `COLOR_BACKGROUND` black (an empty wallpaper path makes Windows paint the
  colour, so there is no flash of the default image while one loads), hidden
  desktop icons, taskbar auto-hide, and toasts off so nothing pops up over a game.

Two non-obvious details:

- Taskbar auto-hide has no API and no DWORD. It is bit 0 of byte 8 of the opaque
  `StuckRects3\Settings` binary blob.
- On 25H2 the per-user `TaskbarDa` value (widgets button) is write-protected and
  fails with "unauthorized operation" even from an elevated session. The machine
  policy `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests` works.

Also set here, and worth more than it looks:
`bcdedit /set {current} bootstatuspolicy ignoreallfailures` and
`recoveryenabled No`. xsync destroys the VM in some recovery paths, and by
default the *next* boot would stop on "Windows did not shut down correctly" —
a screen that needs a keypress, on a machine with no keyboard in front of it.

## A third domain profile: maint

`install` and `play` were not enough. Servicing an installed guest — applying
settings, taking screenshots, inspecting state — needed a way to boot Windows
without taking the GPU and the TV away from the host.

`maint` is the install profile with the install media removed and `<boot
dev='hd'/>`. Leaving the Windows ISO attached, as `install` does, is a standing
risk of booting into Setup against a disk that already has Windows on it.

```bash
sudo tools/xsync-setup vm maint && sudo virsh start xsync-win11
sudo virsh screenshot xsync-win11 /tmp/guest.ppm
sudo host/bin/guest.sh run-user guest/agent/xsync-appearance.ps1
```

`virsh screenshot` against this profile is the cheapest way to verify anything
visual, and it can be scripted into a frame-by-frame capture of a whole boot.

## Failures that report success

A recurring shape, and the most expensive class of bug in this project. Each of
these returned zero, logged nothing alarming, and did the wrong thing.

### `die` inside a command substitution only kills the subshell

`cputune="$(gen_cputune)"` runs the function in a subshell. A `die` in there
exits *that* shell; the parent carries on with an empty result. The config error
was printed and then completely ignored, and the domain rendered with **no CPU
pinning at all** — the exact cross-CCD stutter the pinning exists to prevent.

Check the status explicitly:

```bash
if ! cputune="$(gen_cputune)"; then die "..."; fi
```

The same shape bit `xsync-doctor`: it sourced `xsync-common.sh`, which calls
`exit 78` from inside itself, terminating doctor before its own `||` fallback
could run — and `2>/dev/null` swallowed the message. On the most likely first-run
state, a fresh clone with no config, doctor printed *nothing whatsoever*.

### `systemctl is-active` returns non-zero for `deactivating`

A session unit is `deactivating` for the entire time `ExecStopPost=` runs, which
is where much of the recovery happens. So "wait until the unit is no longer
active" breaks out immediately and judges a half-recovered machine.

Never wait on unit state. Wait on the conditions you actually care about — GPU
returned to the host, VM gone, display manager up.

### A pending reboot makes Windows Update lie

With a CBS reboot pending, `IUpdateDownloader.Download()` returns **success**
in seconds without downloading anything. The install then fails with
`0x80246007` (WU_E_DM_NOTDOWNLOADED) and the servicing log complains that the
package "failed to be changed to the Staged state". Nothing anywhere mentions
the reboot that caused all of it.

Check `Component Based Servicing\RebootPending` *before* attempting anything.

### Result codes without HRESULTs are not diagnostics

`IUpdateInstaller` gives a `ResultCode` (4 = failed) and an `HResult`. The
result code says only that something failed; the HRESULT says why. Logging only
the former turns a diagnosable failure into "it didn't work".

## Xbox Full Screen Experience

### `RtlSetFeatureConfigurations` only accepts the Runtime store

Passing `configType = 0` (Boot) returns `STATUS_INVALID_PARAMETER`. Code that
loops over both stores calling the API therefore fails exactly half its calls —
and since only the Runtime half ever succeeds, **nothing survives a reboot** and
the feature can never take effect no matter how often it is applied.

The Boot store is a registry hive, not an API:

```
HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\<obfuscatedId>
    EnabledState=2  EnabledStateOptions=0  Variant=0
    VariantPayload=0  VariantPayloadKind=0
```

The subkey is an **obfuscated** form of the feature id, not the id itself.

Boot overrides are additionally ignored if the boot status data file is missing
— normally created by telemetry, which a debloated guest has disabled. Create it
with `RtlCreateBootStatusDataFile` and flag `BootPending` via
`RtlSetSystemBootStatus`.

### FSE is a posture, not a shell replacement

It does **not** replace `explorer.exe`. Seeing `explorer` and
`StartMenuExperienceHost` after a reboot is normal *even when FSE is working*,
and is not evidence of failure. The real signal is *Settings > Gaming > Xbox
mode* gaining a "Choose home app" dropdown.

Feature ids are build-specific. Below 26200.8328 a non-handheld also needs a
panel-dimension override to pass the activation check — a lie the whole session
then depends on. Updating Windows past that build removes the requirement.

## The boot sequence, and what cannot be changed

Measured by capturing every frame of a cold boot with `virsh screenshot`. Note
that this only works on the `maint` profile: `play` has no video device, so what
the firmware draws on a passed-through GPU has never been observed.

- **The sign-in screen cannot be removed on Windows 11 Pro.** `HideAutoLogonUI`
  requires Enterprise, Education or IoT Enterprise. Replacing the shell via
  `Winlogon\Shell` breaks MSIX/UWP activation — i.e. the Xbox app, Gaming
  Services and every Game Pass title — so it is not an option at any edition.
- **`DisableLogonBackgroundImage` does not give black.** It gives the accent
  colour. `PersonalColors_Background` and `PersonalColors_Accent` under
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization` are what LogonUI
  actually consults; per-user accent settings are ignored there.
- **`DisableStatusMessages` does not remove "Welcome".** It governs the verbose
  status family ("Applying user settings"), a different code path.
- **Whatever OVMF draws becomes the BGRT, and `bootuxdisabled` does not suppress
  it.** Microsoft's documentation is explicit that a firmware BGRT logo "is
  always displayed and you can't suppress the custom logo". So a custom OVMF
  logo would occupy the entire black stretch that no user-session video can
  reach — at the cost of building edk2, since the logo is compiled into
  `LogoDxe` with no runtime knob and no fw_cfg override.
- A user-session splash can only cover from logon onwards, never earlier.

**The splash was built anyway, and then removed.** Measured against a real
handoff, the firmware-plus-Windows-boot phase is 31s and logon-to-game is 24s, so
a logon-triggered video covers the back half of the wait and none of the ugly
part. It also never ran once: WPF throws `Cannot show Window when ShowActivated
is false and WindowState is set to Maximized`, and the splash set both — it
needed `ShowActivated=false` so it would not steal focus from the shell. The
exception surfaced only as a one-second gap in its own log.

**What actually works is subtraction, not covering.** The play profile has no
emulated display, so the only device OVMF can draw on is the passed-through GPU,
and the only way it knows how is the GOP driver in that card's PCI option ROM.
`<rom bar='off'/>` on the hostdev takes the ROM away, and the firmware has no
graphics console at all — the logo is not hidden, it is never drawn. This sidesteps
the BGRT problem entirely: there is no firmware logo to become a BGRT.

The obvious worry — that Windows needs the option ROM to bring the card up — did
not materialise. On a real launch the guest reported `NVIDIA GeForce RTX 4090 |
status=OK | 3840x2160`, with the driver initialising the card entirely on its own.
The measured side effect was in the other direction: **agent-ready dropped from 31s
to 23s**, because OVMF no longer spends the time standing up a graphics console for
the sole purpose of drawing a logo on it. Removing the logo made the boot shorter as
well as blacker. The cost is
a genuinely headless firmware phase — no boot menu, no setup screen, no error
text — which is why it is a config key (`XSYNC_HIDE_FIRMWARE_LOGO`) and not a
hardcoded decision.

## XInput hands a background process nothing while a game has focus

This is the one that cost the most, and every other controller theory in this
file was downstream of it.

Measured on this machine with a pad connected and Oblivion running, polling
`XInputGetStateEx` from the watcher:

```
pkt=4      btn=0x0000  lt=0 rt=0 lx=0 ly=0
pkt=366    btn=0x0000  lt=0 rt=0 lx=0 ly=0
pkt=1168   btn=0x0000  lt=0 rt=0 lx=0 ly=0
pkt=2434   btn=0x0000  lt=0 rt=0 lx=0 ly=0
```

`dwPacketNumber` climbing by ~27 a second says the device is live and streaming.
Every field being exactly zero -- buttons, both triggers, **and both thumbsticks**
-- says the data is synthetic. A real controller does not read dead-zero on the
sticks. Windows is handing a background process rest values by design, which is
documented for the XInput-on-GameInput path: *"the wrapper will return gamepad
input only when the game is in focus. When the game is not in focus, any gamepad
state returned is set to neutral or 'rest' values, as if the user isn't touching
the gamepad."*

So no chord read through XInput can ever work from the watcher. Not L3+R3, not
View+Menu, not Guide. Days went into the overlay, the Xbox full screen
experience, focus stealing and window styles, and none of those were ever the
problem -- the input simply never arrived.

**Raw Input with `RIDEV_INPUTSINK` is the fix.** It is the documented mechanism
for receiving device input when you are *not* the foreground window. It needs a
real `HWND` and a message pump, so the agent runs a message-only window
(`HWND_MESSAGE`) on its own STA thread and decodes button usages with
`HidP_GetUsages`. Proven on hardware before being wired in: 391 HID reports
received and buttons `9,10` decoded while the game held the foreground. L3 and R3
are HID buttons 9 and 10; View and Menu are 7 and 8.

The heartbeat now logs both paths on one line, so the disagreement is visible:

```
xinput: [0] rc=0 pkt=317 btn=0x0000 ... | rawpad: 34 report(s), pressed -
exit chord pressed - quitting
```

Two smaller lessons rode along. The delegate passed to `CreateWindowEx` must be
held in a managed field -- without a reference the GC collects it, the window
procedure becomes a dangling pointer, and the thread dies silently on the first
report. And the confirmation overlay was removed entirely: it was guarding
against an accidental press that needs two deliberate thumbs, at the cost of a
window that had to draw over a fullscreen game and read a second round of the
very input that was not arriving.

## Not every Game Pass title lands in C:\XboxGames

'Sunset Overdrive' was installed, all 28 GB of it, and invisible to every part of
this project. The enumerator walks `C:\XboxGames` looking for
`Content\MicrosoftGame.config`, and that title has neither: it is a UWP-era game,
so the Store put it in `C:\Program Files\WindowsApps` as `Microsoft.Sunflower`
with entry point `SunsetGame.GameView`, no `MicrosoftGame.config`, and no
`GameLaunchHelper.exe` wrapper. It is not in the GamingServices package
repository either, which was the obvious second place to look. All three of the
sources we had were the wrong ones.

There is no flag in the manifest that says "this is a game", so the discriminator
is size. Measured against a real library:

| package | size | what it is |
|---|---|---|
| Microsoft.ForteBaseGame | 149 GB | Forza Horizon 6 |
| BethesdaSoftworks.ProjectAltar | 121 GB | Oblivion Remastered |
| Microsoft.Sunflower | 28 GB | Sunset Overdrive |
| Xbox360BackwardCompatibil...Conker | 4.9 GB | Conker |
| Microsoft.Windows.Photos | 878 MB | inbox app |
| Microsoft.ScreenSketch | 533 MB | inbox app |
| Microsoft.Paint | 417 MB | inbox app |
| Microsoft.GamingApp | 360 MB | the Xbox app itself |

An order of magnitude separates the two groups, so a 1 GB floor plus "not
System-signed" catches every game and no inbox app. It is crude, and it will miss
a sub-gigabyte indie title — that is the direction to fail in, because a missing
shortcut is an annoyance and Paint appearing in Steam is nonsense. The floor is
`XSYNC_MIN_GAME_BYTES` if it ever needs moving.

Worth noting what this cost to find: the game list was correct, the capture was
running on schedule and writing `games.json` every three minutes, the sync ran
cleanly and reported "0 added" — every component behaved exactly as designed, and
the title still never appeared. Nothing was broken; the search space was.

## Asking SteamGridDB for one exact size finds nothing

'Oblivion Remastered' had no wide capsule in Steam while the art was plainly
visible on SteamGridDB. The query pinned `dimensions=460x215`; every wide grid
for that title is uploaded at `920x430`, so it matched none of them and the code
did a bare `continue` with no warning. Both capsule queries now ask for the 1x
and 2x sizes, and an empty result says which asset is missing instead of staying
silent.

It could never repair itself either. The sync tested `<appid>p.png` alone and
treated the portrait's presence as proof the whole set had landed -- so a title
that got its portrait and nothing else was skipped by every subsequent sync,
permanently. It now checks all five slots and fetches only the missing ones,
which also makes a repair run cheap enough to do every time.

The aggregate log line hid it: `artwork for '...': 4/5 images` reads like success.
A count is not a status.

## A pad that is off and a pad that is idle read identically

`XInputGetState` returns `ERROR_DEVICE_NOT_CONNECTED` (1167) for an empty slot,
but the helper wrapping it returned `0` for that *and* for "connected, nothing
pressed" — and the watcher only logged non-zero button words. So a controller
that was off, asleep, or never enumerated in the guest produced exactly the same
log as one sitting idle on the sofa: nothing at all.

Every report of "I pressed the chord and nothing happened" was consistent with
both readings, which is why none of them could be settled from the log, and why
several hours went into theories about the Xbox shell swallowing input. The
watcher now reports controller count at init and logs every connect/disconnect
transition, so the question is answerable in one line.

Worth knowing what the pad depends on here: it reaches the guest over a
**Bluetooth radio that sits on the passed-through USB controller**, so it must be
paired to *Windows*, not to the host. The Xbox dongle is not part of that path at
all when it is unplugged.

## The exit prompt needed a route that does not involve the controller

The confirmation prompt could only be summoned by a controller chord and only
answered by controller buttons — so the single case where a user most needs to
quit, the pad not working, was the exact case with no way out. The wireless
keyboard is on the same passed-through USB controller as the Bluetooth radio, so
it is present whenever the pad should be.

`Ctrl+Alt+Q` now opens the prompt and `Enter`/`Esc` answer it. `GetAsyncKeyState`
reads physical key state regardless of focus, so a background watcher sees it
behind a fullscreen game.

## Testing the exit prompt required a television

`Show-ExitOverlay` was reachable only by pressing a chord during a real session on
the TV, so checking it meant booting the play profile, launching a game, and taking
over the only display in the house. It was therefore tested about as often as that
is convenient, and shipped broken three times running: an unreachable type that
made it flash and vanish, a leaked return value that read every answer as "quit",
and a docking order that hid the instructions from the one screen whose only job is
to show them.

`-Action overlay` renders it on demand with no game and no chord, which means it can
be screenshotted from the maint profile and checked by a machine.

## Auto-hide is worse than a taskbar

A revealed auto-hide taskbar is drawn **topmost**, so it renders over a
borderless-fullscreen game — the Start button and clock appeared on top of a
game's title screen. A normal taskbar is an ordinary window that a fullscreen
game covers completely, and is only visible during the few seconds of black
desktop before the game appears. Auto-hide is off by default for this reason.

Note also that `HKCU:` under `guest-exec` is Local System's hive, not the user's,
so reading per-user state that way reports it as missing entirely. Read via
`HKEY_USERS\<sid>`.

## Everything the host drives runs as SYSTEM, and SYSTEM has its own everything

The host talks to the guest over qemu-guest-agent, which runs as
`NT AUTHORITY\SYSTEM` in session 0. That single fact broke four separate
features, each in a way that logged success or blamed the wrong component:

| Symptom | Real cause |
|---|---|
| "Xbox app is not installed" on a VM running Game Pass titles | `Get-AppxPackage` without `-AllUsers` asks whether the app is installed *for SYSTEM* — false on every machine |
| `GamingHomeApp` set, then unset after reboot | `HKCU:` as SYSTEM is `HKU\S-1-5-18`, not the user's hive |
| Taskbar auto-hide "not applied" | Same: reading `HKCU:` under guest-exec reads Local System's hive |
| Screenshot came back 0 bytes | Session 0 cannot capture the interactive desktop |

None of these fail loudly. The API call succeeds, writes somewhere real, and
returns. The value is simply invisible to the person using the machine.

Two rules follow. Anything **per-user** must resolve the interactive account
explicitly — `LastLoggedOnUserSID` under `LogonUI` works even when nobody is
logged in right now, which matters because maintenance runs against a guest
nobody is sitting at. Anything that needs to **see or draw on the desktop** must
go through the user session (`guest.sh run-user`), not guest-exec.

## An answering agent is not a usable desktop

`guest.sh wait` returns when qemu-guest-agent replies. The agent is up long
before Windows finishes autologon — about twelve seconds earlier on this
machine — and a launch fired in that window fails:

    launching game: forza-horizon-6
    guest stderr: no interactive user is logged on
    launch request failed - leaving the guest at the Xbox app

The launch failure is only a warning, so the session proceeded to RUNNING and
started the watchdog. Every host-side signal reported a healthy handoff. The
user was left staring at the Xbox app with the game never started.

Poll for `explorer.exe` before launching, not for a logon event: its absence is
what actually breaks the launch, so it cannot report ready while launching would
still fail.

## "I could not tell" is not the same answer as "no"

Three separate places collapsed an error into a confident negative:

- `vm.sh` mapped any virsh failure to `undefined`, which `vm_gone` treats as
  gone. A libvirtd restart would therefore grant permission to unbind the GPU
  from under a live QEMU — the one outcome the file's own comments forbid.
- `guest.sh` swallowed stderr, so a polkit authorisation failure and a dead
  guest both surfaced as "unreachable".
- `xsync-doctor` read the same failure as "domain not defined yet" and silently
  skipped the play-profile check — the check that stops a launch bringing up a
  GPU-less VM.

The shape is identical every time: a query fails, and the failure is folded into
the falsy branch of a boolean the caller then acts on. Where acting on a wrong
answer is expensive, the unknown state has to be represented and propagated —
`vm.sh` now returns `unknown`, which no caller treats as safe.

## Features that ship broken look exactly like features that work

Several things in this project were written, documented, configured, committed,
and had never once executed:

- `xsync-maintain.service`/`.timer` existed in the tree but `xsync-setup` never
  installed them, so no timer was registered on any machine.
- `Install-Agent` copied itself over its own installed path, which throws, so
  `xsync-splash` had never been registered.
- `guest_push` passed the whole payload as an argv entry, capping a push at
  roughly 1.5 MiB — fine for every script, fatal for the one asset the boot
  splash existed to deliver.
- The splash itself threw on its first line of real work on every boot it ever
  ran, and reported success, because the exception was raised inside a scheduled
  task whose exit code nobody read.

Each looked healthy from the outside: the file was present, the config key was
set, the code path existed. What was missing was any check that the thing had
actually *happened*. A test that exercises the mechanism is worth more than any
amount of reading the code that implements it.

## Three kernel bugchecks in one day, cause not established

The guest bugchecked `0x0000001E` (`KMODE_EXCEPTION_NOT_HANDLED`, first parameter
`0xC0000005`) three times on 2026-07-27: at 09:37, 11:28 and 19:04. This is
recorded because it is unresolved, not because it is understood.

What is known:

- The 19:04 crash happened **37 seconds into a play-profile boot** with the GPU
  attached, and broke a handoff: the agent never answered, the session gave up
  after 120s, and the host recovered correctly.
- There are **no `nvlddmkm` events** in the log. That is weak evidence either
  way — a crash during driver initialisation is precisely the case that leaves
  no driver log entry, because the crash is the driver.
- Windows Error Reporting produced **no fault bucket** (`Fault bucket , type 0`),
  so it did not resolve a faulting module either.
- The component store is healthy and the filesystem is clean, so this is not
  the servicing corruption seen earlier.
- The immediately preceding handoff had shut the VM down only 37 seconds before,
  which makes insufficient GPU reset time between consecutive handoffs a
  plausible but **unconfirmed** hypothesis.

Naming the faulting driver needs a kernel debugger against
`C:\Windows\Minidump\*.dmp`; `guest.sh pull` now exists to get those dumps to the
host, which it previously could not do at all.

The one change made in response is raising `XSYNC_BOOT_TIMEOUT` from 120s to
300s. A healthy guest answers in 22-24s, so 120s looked generous — but a guest
recovering from a dirty shutdown took over 100s and still lost the race. The
timeout was sized against the good case and had no margin for the bad one.
