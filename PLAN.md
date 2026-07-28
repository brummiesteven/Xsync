# xsync — Architecture & Implementation Plan

> Play Xbox Game Pass titles on Linux as if they were native Steam games.

xsync makes Xbox Game Pass games installed in a Windows 11 VM appear automatically
in Steam's library — complete with artwork — and launch from Steam Big Picture with
a controller, at full native GPU performance. When you quit, the VM shuts down so it
costs nothing while you're not using it.

---

## 1. The core problem

A VFIO passthrough VM and the host Steam session **cannot use the same GPU at the
same time**. One GPU, one owner. On the reference machine the TV is wired to the
RTX 4090, which forces a choice:

| | Keep Steam alive | Keep native perf |
|---|---|---|
| Host session lives on iGPU | ✅ Steam overlay works | ❌ native games display through iGPU |
| Host session torn down | ❌ no Steam overlay | ✅ native games untouched |

**xsync chooses the second (`handoff` mode).** Native Steam gaming — the primary use
of the machine — stays byte-for-byte unchanged at 4K120 HDR on the 4090, and Xbox
games get the *entire* 4090 with zero streaming latency because the VM drives the
TV directly.

The cost is that Steam is not running during an Xbox game, so Steam's overlay
"Exit Game" is unavailable. xsync replaces it with an in-guest Guide-button overlay
plus automatic exit detection (§6).

A `moonlight` mode (host session on iGPU, VM streams to it, Steam overlay preserved)
is a documented future backend. The codebase keeps the display path pluggable, but
`handoff` is what v1 implements and tests.

---

## 2. Reference hardware

Development and testing target. xsync is **Bazzite/SteamOS-first and opinionated**.

| | |
|---|---|
| Host | Bazzite `bazzite-deck-nvidia-43` (Fedora 43 Kinoite, rpm-ostree, read-only root) |
| CPU | Ryzen 9 7950X — CCD0 = `0-7,16-23`, CCD1 = `8-15,24-31` (separate L3 per CCD) |
| RAM | 30 GiB + 15 GiB zram |
| GPU | RTX 4090 — `01:00.0` (VGA) + `01:00.1` (HDMI audio), **alone in IOMMU group 12** |
| iGPU | AMD Raphael `0c:00.0` — present, outputs unplugged, unused by xsync in handoff mode |
| Display | Single 4K TV on the 4090's `HDMI-A-2`. Audio rides the same cable. |
| Session | `gamescope-session-plus@steam.service` (user unit), started by SDDM autologin |
| Input | Xbox controller on the `045e:02e6` dongle; the whole USB controller `0a:00.0` is passed to the VM, so the controller follows it |
| Recovery | sshd on the LAN, no firewall blocking — the out-of-band escape hatch |

The clean IOMMU group is what makes this viable — no ACS override patching needed.

---

## 3. Locked design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Display topology | **handoff** — TV stays on 4090 | Protects native gaming; best Xbox perf |
| Portability | Bazzite/SteamOS-first | Far less code, natural audience, upstreamable |
| Library sync | `shortcuts.vdf` on VM shutdown + Steam restart | Documented formats, no undocumented APIs |
| Windows licensing | Product key, unattended install | Fully automatable, no watermark |
| Controller → VM | Whole USB controller passed through | Per-device USB attach resets the dongle and races its address; see `docs/FINDINGS.md` |
| Exit | Guide long-press overlay + auto-detect | Closest replacement for the Steam overlay |
| VM size | 20 GiB RAM, 512 GiB sparse raw | Generous, host stays comfortable |
| Anti-cheat | **Not circumvented** | See §10 |

### Deviation to flag: CPU pinning

The sizing option said "12 cores". Having confirmed the CCD layout, I'm defaulting to
**8 cores / 16 threads pinned to CCD1** (`8-15,24-31`) instead, because 12 cores would
straddle both CCDs and cross-CCD L3 traffic causes exactly the frametime stutter this
project exists to avoid. Eight cores on one unified L3 is the standard VFIO gaming
recommendation and matches current-gen console core counts.

CCD0 stays free for the host, QEMU emulator threads and I/O threads — which also makes
the VM smoother. Set `vm.cpu_cores = 12` in config to override for CPU-bound titles.

---

## 4. Component map

```
┌─ HOST (Linux) ──────────────────────────────────────────┐
│                                                          │
│  Steam Big Picture ── launches ──> xsync-launch <game>   │
│                                          │               │
│                                    (sudo systemctl start)│
│                                          v               │
│  xsync-session@<game>.service                            │
│    (system unit, survives the session teardown)          │
│    │                                                     │
│    ├─ session.sh   stop/start sddm + gamescope session   │
│    ├─ gpu.sh       nvidia <-> vfio-pci rebinding         │
│    ├─ vm.sh        virsh lifecycle                       │
│    ├─ watchdog     force-stops a VM that stops answering │
│    ├─ exit monitor host-side "the game has finished"     │
│    └─ library.py   shortcuts.vdf + SteamGridDB artwork   │
│                                                          │
│  xsync-recover.service      one-shot repair, ExecStopPost│
│  xsync-display-watch.service  restores gaming mode when  │
│                               the TV comes out of standby│
└──────────────────────────┬───────────────────────────────┘
                           │ virtio-serial / qemu-guest-agent
┌─ GUEST (Windows 11) ─────┴───────────────────────────────┐
│  xsync-agent (service)                                   │
│    ├─ enumerate C:\XboxGames -> game list -> host        │
│    ├─ launch requested game fullscreen                   │
│    ├─ watch game process -> exit -> shutdown             │
│    ├─ Guide long-press -> "Exit to Steam?" overlay       │
│    └─ heartbeat -> host watchdog                         │
└──────────────────────────────────────────────────────────┘
```

---

## 5. The handoff state machine

Owned by `host/bin/xsync-session`, run from `xsync-session@<game>.service`. It is a
**system** unit so it survives the destruction of the user session it is tearing down.

```
IDLE
 │  xsync-launch <game-id>  (run by Steam as the "game")
 v
PREPARE          validate: VM defined, GPU bound to nvidia, dongle present,
 │               requested game installed, no native game running
 v
STOP_SESSION     systemctl stop sddm
 │               (takes gamescope-session-plus@steam.service with it)
 v
RELEASE_GPU      kill residual GPU clients
 │               unload nvidia_drm, nvidia_modeset, nvidia_uvm, nvidia
 │               unbind 01:00.0 + 01:00.1 -> bind vfio-pci
 v
START_VM         virsh start xsync-win11  (GPU + dongle attached)
 │               VM drives the TV directly: native 4K HDR + HDMI audio
 v
RUNNING          guest agent launches the game, emits heartbeat
 │
 │  game exits  |  Guide-overlay quit  |  heartbeat lost >30s
 v
STOP_VM          graceful shutdown, escalate to virsh destroy after timeout
 │
 v
RECLAIM_GPU      unbind vfio-pci -> rebind nvidia, reload modules
 │
 v
SYNC_LIBRARY     diff game list, update shortcuts.vdf + fetch artwork
 │
 v
RESTORE_SESSION  systemctl start sddm  -> autologin -> Steam Big Picture
 │
 v
IDLE
```

**Every transition is wrapped.** Any failure, exception or timeout jumps straight to
`RECLAIM_GPU` → `RESTORE_SESSION`. The single worst outcome for this project is a
black TV with no way back, so the recovery path is the part that gets the most care:

- GPU rebind is idempotent and retried
- If rebind fails, the session is restored anyway (host falls back to iGPU/console)
- `xsync-recover.service` restores the session if `xsync-session` dies unexpectedly
  (wired up as `ExecStopPost=`, and runnable by hand)
- `xsync-display-watch.service` puts gaming mode back when the TV returns from
  standby, which the host cannot trigger itself because NVIDIA exposes no CEC adapter
- SSH from another machine on the LAN is the out-of-band escape hatch

---

## 6. Exit UX

Three layers, all active simultaneously:

1. **Natural quit** — quit via the game's own menu; the agent sees the process exit
   and shuts the VM down. This is the common path.
2. **Guide long-press** — hold the Xbox button 2s for a minimal controller-navigable
   `Exit to Steam? [A] Yes [B] No` overlay. Kills the game, shuts down.
3. **Host watchdog** — heartbeat lost or VM unresponsive >30s → force destroy, reclaim
   GPU, restore session. You can never be stranded.

---

## 7. Game discovery

Game Pass PC titles install to `C:\XboxGames\<Title>\Content\`, alongside a
`MicrosoftGame.config` giving the package family name, AUMID and display name.

The agent enumerates that directory (cross-checked against `Get-AppxPackage`) and
emits JSON:

```json
[{ "id": "halo-infinite", "name": "Halo Infinite",
   "aumid": "Microsoft.254428597CFE2_8wekyb3d8bbwe!App",
   "install_path": "C:\\XboxGames\\Halo Infinite" }]
```

Launch is via the AUMID (`explorer.exe shell:appsFolder\<AUMID>`), which is what the
Xbox app itself uses.

**On first install only the Xbox app itself is exposed as a Steam entry**, so there is
somewhere to go to install games. Everything else appears as it is installed.

---

## 8. Steam integration

Steam reads `shortcuts.vdf` at startup and rewrites it on exit, so it can only be
safely modified while Steam is stopped. The handoff already stops Steam, which makes
this free: the library sync runs in the `SYNC_LIBRARY` step, between VM shutdown and
session restore.

- Shortcut target is `xsync-launch <game-id>`, so Steam re-entering the game re-enters
  the handoff.
- Artwork (grid / hero / logo / icon) is fetched from **SteamGridDB** into
  `userdata/<id>/config/grid/`. Requires a free API key in config.
- **Profile-aware**: a machine may have several Steam accounts under
  `userdata/`. `XSYNC_STEAM_PROFILES=auto` targets the most recently used; set it
  to a space-separated list of numeric IDs to sync specific ones.

---

## 9. Repository layout

```
xsync/
├── PLAN.md                    this document — architecture and rationale
├── STATE.md                   build status and current machine state
├── README.md  LICENSE
├── config/
│   ├── xsync.conf             all machine-specific values (git-ignored)
│   └── xsync.conf.example     template — copy and edit
├── host/
│   ├── bin/       xsync-launch, xsync-session, xsync-recover,
│   │              xsync-display-watch, gpu.sh, session.sh, vm.sh,
│   │              guest.sh, library.py, xsync-common.sh
│   ├── systemd/   xsync-session@.service, xsync-recover.service,
│   │              xsync-display-watch.service
│   └── libvirt/   xsync-win11.xml.tmpl  (renders install | maint | play)
├── guest/
│   ├── agent/     xsync-agent.ps1 (enumerate, launch, watch, overlay)
│   │              plus firstboot, debloat, provision, appearance,
│   │              display, gpu-driver, fse, screenshot
│   └── unattend/  autounattend.xml
├── tools/         xsync-setup, xsync-doctor, xsync-test,
│                  xsync-fetch-iso, xsync-make-unattend,
│                  xsync-install-windows
└── docs/          FINDINGS.md — the non-obvious things, learned the hard way
```

**There is no detection wizard.** Every machine-specific value — GPU PCI IDs,
IOMMU groups, the USB controller, Steam paths, user name and UID, RAM and CPU
topology — must be set by hand in `config/xsync.conf`, starting from
`config/xsync.conf.example`. `tools/xsync-doctor` checks most of them and tells
you what is wrong. Automating this is an open task, not a shipped feature.

---

## 10. Scope limits (stated honestly, up front)

- **Anti-cheat titles will not work.** EAC/BattlEye refuse to run in VMs by design.
  Defeating that is anti-cheat circumvention; xsync will not ship VM-masking and will
  not accept patches that add it. Single-player Game Pass titles — the bulk of the
  catalogue — are unaffected. There is no compatibility list yet.
- **Launch is not instant.** Cold-booting Windows costs roughly 25-40s before the game
  appears. VM save/restore can't help because VFIO state can't be serialised. Mitigated
  with fast startup disabled, autologin, and the agent launching the game the moment
  Windows is up. GPU hotplug into a pre-booted VM is a possible future optimisation.
- **A Windows licence is required.** xsync automates installation, not licensing.
- **Handoff mode has no Steam overlay during play.** By construction — see §1.

---

## 11. Build order

The order this was built in, and the order to repeat it in on new hardware.
Steps 1-5 leave the TV alone; only step 7 takes the display away.

1. Plan + repo scaffold
2. Host handoff state machine + GPU rebind + recovery — written and testable
   before anything destructive
3. Kernel args (`amd_iommu=on`, `iommu=pt`) + **reboot**
   *(deliberately NOT `vfio_pci.ids=` — the host must keep the GPU for native
   gaming; binding is dynamic)*
4. Windows 11 VM, unattended install, Xbox app — all on the `install` profile
   with a virtio GPU, so the TV is undisturbed
5. Guest agent
6. Library + artwork sync
7. Switch to the `play` profile, attach the GPU and the USB controller, then
   end-to-end testing and tuning ← *the TV blacks out from here on*

Use the `maint` profile for anything after that: it boots the installed guest
over VNC with no passthrough, so the guest can be serviced without taking the
display.
