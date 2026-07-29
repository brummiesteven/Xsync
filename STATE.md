# xsync — status

Read `PLAN.md` for the architecture and `docs/FINDINGS.md` for everything learned
during bring-up. Most of FINDINGS is non-obvious and expensive to rediscover.

Last updated: 2026-07-29.

---

## Read this first: what changed on 29 Jul

Launching had been broken since 28 Jul midday, and the library sync had never
worked unattended at all. Ten defects were found and fixed; all are written up in
full in `docs/FINDINGS.md`.

**Launching**

1. **`Get-AppxPackage -AllUsers` throws terminating.** The WindowsApps
   enumeration added on 28 Jul put an admin-only call into
   `Get-InstalledXboxGames`, and the launch path — the one path that must stay
   *unelevated*, because packaged apps refuse to start from an elevated process —
   called it. `-ErrorAction SilentlyContinue` does not suppress a terminating
   error, so the user-session task died in about two seconds.
2. **`ConvertFrom-Json` does not enumerate on Windows PowerShell 5.1.** The fix
   for (1) filtered the cached list with a `Where-Object` pipeline. 5.1 hands a
   JSON array to the pipeline as one `Object[]`, so the filter matched the whole
   array via member enumeration and returned *all four games*. Windows then
   silently activated the first AUMID in the string — the guest's event log shows
   Conker starting while the host waited for Forza. pwsh 7 enumerates, so this
   passed every test run on the host.
3. **DLC counted as games.** Installing Fallout 4 took the library from 5 entries
   to 11, each add-on carrying a fabricated `!App` AUMID that could never launch.
4. **`clock offset='localtime'` broke Store licensing.** Host `+04`, guest `+01`,
   so the guest's UTC ran three hours ahead. Sunset Overdrive failed to activate
   nine times; every other title had a cached licence and was unaffected.

**The library sync — it had never worked without being run by hand**

5. **`status` reported `playing:true` forever after a game exited**, because the
   end-of-game state has no `install_path` and fell through to "is the Xbox app
   running?", which it always is.
6. **The exit monitor slept through its own 180s grace** before its first poll.
7. **The final capture was gated on `seen`**, so a game that exited before the
   first poll was ignored even once (5) and (6) were fixed.
8. **A paused download read as "no download"**, so an install interrupted by the
   profile switch left no watcher running and was silently abandoned.

**Not leaving the user stranded**

9. **A guest that never reached a desktop left the TV black for up to 13 minutes.**
   `wait-user` timing out was only a warning and the session pressed on into a
   launch that could not work. It now **reboots the guest once and retries**, and
   only aborts and restores gaming mode if that also fails. The wait has its own
   tighter budget, `XSYNC_USER_TIMEOUT` (180s). Root cause diagnosed but not
   fixable from outside: across 37 boots, the two that stalled are the only two
   that logged **zero Winlogon events** — Windows starts, drivers load, and the
   logon never runs. About a 5% boot race; one retry takes it to ~0.25%.
10. **Nothing stopped the host suspending mid-handoff.** `xsync-session@` and
    `xsync-maintain` now hold a `block` inhibitor on `idle:sleep`. The host did
    suspend during testing, 29 minutes into an unattended guest operation.

**Diagnosis, which was the real reason this took a day**

Launching now goes through `IApplicationActivationManager::ActivateApplication`
rather than `explorer.exe shell:appsFolder\`, which is fire-and-forget and reports
success no matter what; the log now carries an HRESULT and a pid. Failures inside
the guest's user session are spooled to a file and folded into the message the
host prints, instead of arriving as a bare `result 1`. And `agent.log` is now
writable by the interactive user — it was owned by Administrators, so the
unelevated launch path, the one that broke, could not log anything at all.

### Verified on hardware, 29 Jul

Real handoffs, GPU passed through, game process confirmed running in the guest:

| game | process seen | result |
|---|---|---|
| Forza Horizon 6 | `forzahorizon6` | pass |
| Oblivion Remastered | `OblivionRemastered-WinGDK-Shipping` | pass |
| Conker: Live and Reloaded | `EmuMenu` | pass |
| Sunset Overdrive | `Sunset` | pass, after the clock fix below |
| Fallout 4 | `Fallout4Launcher` | installed during testing; syncs to Steam |

Host teardown was clean after every run: `phase=IDLE`, GPU back on `nvidia`, VM
off, sddm active. `xsync-test run safe` 42/42, `xsync-doctor` 24 passed / 0 failed.

**15-minute idle soak** (Forza left untouched on its attract screen, sampled every
minute) — the case that previously ended in a mid-game shutdown:

```
forza=1  vm=running  phase=RUNNING  enumerations=1  final_captures=0
```

identical on all fifteen samples. The VM never stopped, nothing entered the
interactive session to steal focus (an unguarded periodic enumeration would have
fired at ~6.7 and ~13.5 minutes), and the one-shot final capture was not spent
during the launch window. Quitting then produced `final game list captured` ->
`SYNC_LIBRARY` -> `finished cleanly`, host back in 23s.

Also verified unelevated in the guest, against a Limited-token scheduled task —
the exact principal a launch uses:

| check | before | after |
|---|---|---|
| `Get-AppxPackage -AllUsers` | terminating `UnauthorizedAccessException` | guarded, not reached unelevated |
| agent `-Action enumerate` | died, rc 1 | rc 0, correct AUMIDs |
| `Resolve-GameById` | returned all 4 games | returns exactly 1, asserts on ambiguity |
| appending to `agent.log` | `Access is denied` | writable |
| a failing user-session script | host saw `result 1` | host sees the exception text |

### The library sync now works without being run by hand

It never had. Every entry in Steam had been put there by running the sync
manually. Three defects, written up in `docs/FINDINGS.md`:

1. `status` reported `playing:true` forever after a game exited — the end-of-game
   state has no `install_path`, so it fell through to "is the Xbox app running?",
   which it always is. The host never saw play stop.
2. The exit monitor slept through its own 180s grace before its first poll, so a
   short session was never observed at all.
3. The final capture was gated on `seen`, so a game that exited before the
   monitor's first poll was ignored even once (1) and (2) were fixed.

Verified end to end on 29 Jul. Fallout 4 was installed from inside the guest via
the Xbox app (48.96 GB, base game plus six add-ons) and reached Steam with no
manual step:

```
12:50:08  captured 5 installed game(s)
12:50:08  final game list captured          <- had never once fired before
12:50:09  pushed captured -> C:\ProgramData\xsync\captured
12:50:24  phase: SYNC_LIBRARY
```

`games.json` 4 -> 5 titles, `shortcuts.vdf` 6 -> 7 entries, Fallout 4 present.

### DLC are not games

Installing Fallout 4 took the library from 5 entries to **11**: Game Pass lays
each add-on down as its own `C:\XboxGames\Fallout 4- <name>` directory with its
own `Content\MicrosoftGame.config`, which is exactly the shape the enumerator
looks for. They also received fabricated `!App` AUMIDs that matched no app, so
all six were unlaunchable shortcuts. Now skipped on explicit markers
(`TargetDeviceFamilyForDLC`, `MainPackageDependency`, absent `ExecutableList`),
and a package with no `Applications` node no longer gets an invented AUMID.

### The host must not sleep during a handoff

Nothing prevented it. `xsync-session@` and `xsync-maintain` now wrap their
`ExecStart` in `systemd-inhibit --what=idle:sleep --mode=block`. On 29 Jul the
host suspended (`PM: suspend entry (deep)`) 29 minutes into an unattended guest
operation; it happened to be on the maint profile, so it cost only time. During a
play session it would have suspended with the GPU on vfio-pci, the VM holding it
and sddm stopped. Every other inhibitor on this machine (HandheldDaemon,
NetworkManager, UPower, libvirtd) is `delay`, which does not stop an idle suspend.

### Library removals sync too, and a paused download no longer vanishes

Round-tripped on hardware 29 Jul by uninstalling and reinstalling Conker
(4.85 GB) through the Xbox app:

| | games.json | Steam shortcuts |
|---|---|---|
| start | 5 | 7 |
| after uninstall | 4 | 6 — Conker removed |
| after reinstall | 5 | 7 — Conker restored |

Non-xsync shortcuts were preserved throughout. The removal path had never been
exercised before.

That test also exposed a real defect: `Test-DownloadActive` only measured bytes
moving *right now*, so an install interrupted by the profile switch read as "no
download" for the minutes Game Pass takes to re-queue it — and teardown then
started no download watcher. It now treats a GUID-named staging folder under
`C:\XboxGames` as a pending install. See `docs/FINDINGS.md`.

### Fixed: Sunset Overdrive (it was the guest clock)

It failed to activate with `0x80070BFF`, "a licensing operation is being
performed", nine times running, while Forza activated cleanly seconds later in
the same session. The cause was `<clock offset='localtime'/>`: with the host on
Asia/Muscat (+04) and the guest on Europe/London (+01), the guest's notion of UTC
was **three hours ahead**, and Store licence validation is time-sensitive. Every
other title already had a cached licence, which is why only one game appeared
broken.

Fixed with `<clock offset='utc'/>` plus `RealTimeIsUniversal=1` in the guest
(now set by `xsync-firstboot.ps1`). Verified across a cold boot: guest UTC
matches the host to the second, UK local time still displayed, and Sunset
launches first try. Full write-up in `docs/FINDINGS.md`.

### Xbox Full Screen Experience: NOT the cause, but it IS switched on

Investigated on suspicion and ruled out as the cause of the launch failures, with
sources, in `docs/FINDINGS.md`. FSE-inactive is the documented default state for
Game Pass titles on every non-handheld PC, and it is runtime-toggleable, so it
cannot be a launch prerequisite. Licensing was ruled out at the same time — all
four packages report `Status=Ok`, MSA signed in, clock correct, vTPM owned.

**But it is enabled on this guest, and the note further down claiming otherwise
was wrong.** The operator turned Xbox mode on **by hand**, in Settings — that, not
`xsync-fse.ps1`, is why it is on (see the "Not yet done" note below). Measured on
29 Jul:

```
IsGamingFullScreenExperienceActive() = True
HKLM\...\CurrentVersion\OEM\DeviceForm = 46          (gaming handheld)
GamingConfiguration\GamingHomeApp        = Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App
GamingConfiguration\StartupToGamingHome  = 1            (boots into Xbox mode)
```

`C:\ProgramData\xsync\fse.log` shows `xsync-fse.ps1` was run four times on
**27 Jul**, the last at 15:10:14 reporting success on build 26200.8875 (earlier
attempts failed on 26200.8037 with `NTSTATUS 0xC000000D`). Pressing Win in the
guest now raises the FSE task switcher, with `Ⓐ Select / ✕ Close` prompts and an
"Xbox mode / Windows desktop" toggle.

**Do not read that as the script having worked.** The operator enabled Xbox mode
manually in Settings, and the registry corroborates it: `StartupToGamingHome=1`
is set, and `xsync-fse.ps1` never writes that value — it comes from the Settings
toggle. The script plausibly contributed `DeviceForm=46` and the feature flags,
but **it is not established that it can enable FSE on its own**, and it still has
the defects listed under "Not yet done".

This is deliberate, and the exit path already accounts for it. Microsoft
documents that under FSE **Windows takes exclusive ownership of the Guide
button**, routing a short press to Game Bar — which is exactly why the exit chord
is **L3+R3** (`LTHUMB|RTHUMB`) read through Raw Input `RIDEV_INPUTSINK`, below
that routing layer. FSE does not bind L3+R3, and the operator reports it working.
Any Guide-button route is unavailable while FSE is on, by design.

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

**Xbox Full Screen Experience.** ~~Not applied.~~ **FSE is active** — see the
section at the top of this file for the measurements. This paragraph described
the intended state, not the actual one, and was wrong from 27 Jul onwards.

It was enabled **manually, through Settings**, not by this script. `fse.log` shows
the script ran on 27 Jul, but `StartupToGamingHome=1` is set and the script never
writes it, so at least the boot-to-Xbox behaviour came from the UI. Whether
`xsync-fse.ps1` alone is sufficient is **untested**, and three known defects make
that doubtful: `TaskSwitcherNexusInjectionEnabled` is written to a literal
`HKCU:` (which under guest-exec lands in `HKU\S-1-5-18`, the SYSTEM hive, not the
player's), `Set-BootStatusPending` is defined but never called, and there is no
region handling. Left here because the enable/disable procedure is still correct.
It rewrites feature flags and `DeviceForm`, needs a guest reboot, and re-binds the
Guide button to the FSE task switcher, which disables xsync's own Guide exit
overlay. `xsync-fse.ps1 -Disable` reverses it (asymmetrically — it does not clear
`ShowOnDesktopSwitcher`, the `SystemDialogResults` values, or
`TaskSwitcherNexusInjectionEnabled`). To enable:

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
