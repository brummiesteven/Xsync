#!/usr/bin/env python3
"""
xsync — Steam library sync.

Turns the guest's installed-game list into non-Steam shortcuts, with artwork.

Runs during the SYNC_LIBRARY phase of a handoff, i.e. after the VM has shut down
but before the Steam session is restarted. That window matters: Steam reads
shortcuts.vdf at startup and rewrites it on exit, so this is the only point at
which the file can be modified without Steam clobbering the changes.

Only entries xsync created are ever touched; shortcuts the user added by hand are
read, preserved, and written back untouched.

  library.py sync           update shortcuts from the captured game list
  library.py list           show what xsync currently has in Steam
  library.py artwork <id>   re-fetch artwork for one game
"""

from __future__ import annotations

import json
import os
import re
import shutil
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from pathlib import Path

# --------------------------------------------------------------------- config


# Artwork is fetched from the network and written as root. A Steam grid image
# has no business being larger than this; anything bigger is a mistake or a
# hostile response, and resp.read() with no cap would take it either way.
MAX_ARTWORK_BYTES = 32 * 1024 * 1024


def load_config(path: Path) -> dict:
    """Parse the shell-style config. Only KEY=value lines; quotes stripped."""
    cfg: dict[str, str] = {}
    if not path.is_file():
        raise SystemExit(f"xsync: config not found: {path}")
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        cfg[key.strip()] = val.strip().strip('"').strip("'")
    return cfg


ROOT = Path(os.environ.get("XSYNC_ROOT", Path(__file__).resolve().parents[2]))
CFG = load_config(Path(os.environ.get("XSYNC_CONF", ROOT / "config" / "xsync.conf")))

STEAM_ROOT = Path(CFG.get("XSYNC_STEAM_ROOT", ""))
LAUNCHER = str(Path(CFG.get("XSYNC_VM_STORAGE_DIR", "/var/lib/xsync")) / "app" / "host" / "bin" / "xsync-launch")
SGDB_KEY = CFG.get("XSYNC_SGDB_API_KEY", "").strip()
GAMES_JSON = Path(CFG.get("XSYNC_VM_STORAGE_DIR", "/var/lib/xsync")) / "games.json"

# Marks shortcuts as ours, so hand-made entries are never disturbed.
XSYNC_TAG = "xsync"

# Must match XSYNC_MAINTENANCE_ID in host/bin/xsync-common.sh -- xsync-session
# dispatches on it to run maintenance instead of launching a game.
MAINTENANCE_ID = CFG.get("XSYNC_MAINTENANCE_ID", "xsync-maintenance")
MAINTENANCE_NAME = CFG.get("XSYNC_MAINTENANCE_NAME", "xsync: Guest Maintenance")

# SteamGridDB has artwork for games and nothing for xsync's own entries, so
# these get locally generated tiles instead of a bare grey box.
ARTWORK_TOOL = ROOT / "tools" / "xsync-make-artwork"


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [INFO] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [WARN] {msg}", file=sys.stderr)


# ----------------------------------------------------------------- binary vdf
#
# shortcuts.vdf is Valve's binary VDF:
#   0x00 <key\0> ...nested... 0x08     map
#   0x01 <key\0> <value\0>             string
#   0x02 <key\0> <int32 LE>            int
#   0x08                               end of map


def _read_cstr(buf: bytes, i: int) -> tuple[str, int]:
    end = buf.index(b"\x00", i)
    return buf[i:end].decode("utf-8", "replace"), end + 1


def _read_map(buf: bytes, i: int) -> tuple[dict, int]:
    """
    Read one map, and insist on finding its terminator.

    Running off the end of the buffer used to be treated as a successful end of
    map, which turns a *truncated* file into a short-but-valid parse. That is
    the difference between an error and silent data loss: cmd_sync writes the
    result back as authoritative, so a shortcuts.vdf truncated by a power cut
    during Steam's own write comes back with the user's hand-made shortcuts
    permanently deleted, logged only as an ordinary "0 preserved".

    A zero-filled file is the same defect wearing a different hat: 0x00 is the
    begin-map tag and an empty key is legal, so N nul bytes parse as N/2 nested
    empty maps and yield [] with no exception at all.
    """
    out: dict = {}
    while i < len(buf):
        # Remember where the tag was. The error below used to report `i` after
        # _read_cstr had consumed both the tag AND the whole key, so it always
        # named the key's terminating NUL rather than the offending byte -- and
        # these two strings are the entire diagnostic surface for a corrupt file.
        tag_off = i
        tag = buf[i]
        i += 1
        if tag == 0x08:
            return out, i
        key, i = _read_cstr(buf, i)
        if tag == 0x00:
            val, i = _read_map(buf, i)
        elif tag == 0x01:
            val, i = _read_cstr(buf, i)
        elif tag == 0x02:
            val = struct.unpack_from("<i", buf, i)[0]
            i += 4
        else:
            raise ValueError(f"unknown VDF tag 0x{tag:02x} at offset {tag_off}")
        out[key] = val
    raise ValueError(f"truncated VDF: map beginning before offset {i} has no 0x08 terminator")


class ShortcutsUnreadable(Exception):
    """The file exists but could not be parsed."""


def read_shortcuts(path: Path) -> list[dict]:
    """
    Read shortcuts.vdf.

    Raises ShortcutsUnreadable if the file exists but cannot be parsed. That
    distinction is critical: silently treating an unparseable file as empty
    means the rewrite drops every non-Steam shortcut the user added by hand.
    Valve's binary VDF also has tags this reader does not implement (0x07,
    0x0A), so "I don't understand it" is a realistic outcome that must never be
    confused with "there is nothing here".
    """
    if not path.is_file() or path.stat().st_size == 0:
        return []
    try:
        root, _ = _read_map(path.read_bytes(), 0)
    except Exception as exc:  # noqa: BLE001
        raise ShortcutsUnreadable(f"{path}: {exc}") from exc
    # A non-empty file that yields no "shortcuts" key is not an empty library,
    # it is a file we failed to understand -- and treating the two alike is how
    # the rewrite deletes everything. Valve writes the key as "shortcuts"; match
    # case-insensitively so a differently-cased file is not mistaken for empty.
    key = next((k for k in root if k.lower() == "shortcuts"), None)
    if key is None:
        raise ShortcutsUnreadable(
            f"{path}: parsed, but contains no 'shortcuts' map — refusing to treat as empty"
        )
    shortcuts = root[key]
    if not isinstance(shortcuts, dict):
        raise ShortcutsUnreadable(f"{path}: 'shortcuts' is {type(shortcuts).__name__}, not a map")
    # Keys are stringified indices; order by them to keep the library stable.
    return [shortcuts[k] for k in sorted(shortcuts, key=lambda x: int(x) if x.isdigit() else 0)]


def _write_map(entries: dict) -> bytes:
    out = bytearray()
    for key, val in entries.items():
        kb = key.encode("utf-8") + b"\x00"
        if isinstance(val, dict):
            out += b"\x00" + kb + _write_map(val) + b"\x08"
        elif isinstance(val, bool):
            out += b"\x02" + kb + struct.pack("<i", int(val))
        elif isinstance(val, int):
            out += b"\x02" + kb + struct.pack("<i", val)
        else:
            out += b"\x01" + kb + str(val).encode("utf-8") + b"\x00"
    return bytes(out)


def write_shortcuts(path: Path, shortcuts: list[dict]) -> None:
    body = {str(i): s for i, s in enumerate(shortcuts)}
    blob = b"\x00" + b"shortcuts\x00" + _write_map(body) + b"\x08" + b"\x08"

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        # Never overwrite an existing backup. The backup exists to survive a bad
        # write; refreshing it on every sync means the second sync after a
        # corruption copies the already-broken file over the only good copy.
        backup = path.with_suffix(".vdf.xsync-bak")
        if not backup.exists():
            shutil.copy2(path, backup)

    # Write via a temp file so an interrupted sync can't leave a truncated
    # shortcuts.vdf, which Steam would silently treat as "no shortcuts".
    # fsync before the rename, and fsync the directory after it.
    #
    # os.replace is atomic with respect to other processes, but not with respect
    # to power loss: without the flush the rename can reach disk before the data
    # does, leaving a shortcuts.vdf that exists, is the right size, and is full
    # of zeroes. Steam would then start with an empty library. This file is the
    # user's own hand-made shortcuts as well as ours, so it is worth the two
    # extra syscalls.
    tmp = path.with_suffix(".vdf.tmp")
    with open(tmp, "wb") as fh:
        fh.write(blob)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    try:
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        pass


# ------------------------------------------------------------------- app ids


def shortcut_appid(exe: str, appname: str) -> int:
    """
    Steam's id for a non-Steam shortcut: crc32 of exe+name, high bit set.
    Artwork filenames are derived from this, so it must match exactly what
    Steam computes or the images won't be picked up.
    """
    crc = zlib.crc32(f"{exe}{appname}".encode()) & 0xFFFFFFFF
    return crc | 0x80000000


def signed32(n: int) -> int:
    return n - 0x100000000 if n >= 0x80000000 else n


# ------------------------------------------------------------------ steamgriddb


def sgdb(path: str) -> dict | None:
    if not SGDB_KEY:
        return None
    req = urllib.request.Request(
        f"https://www.steamgriddb.com/api/v2{path}",
        headers={"Authorization": f"Bearer {SGDB_KEY}", "User-Agent": "xsync"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        warn(f"SteamGridDB {path}: HTTP {exc.code}")
    except Exception as exc:  # noqa: BLE001
        warn(f"SteamGridDB {path}: {exc}")
    return None


ART_SUFFIXES = ("p.png", ".png", "_hero.png", "_logo.png", "_icon.png")


def artwork_missing(appid: int, grid_dir: Path) -> list[str]:
    """Which of Steam's five artwork slots this shortcut is still missing."""
    return [s for s in ART_SUFFIXES if not (grid_dir / f"{appid}{s}").is_file()]


def fetch_artwork(name: str, appid: int, grid_dir: Path, deadline: float | None = None) -> int:
    """
    Fetch grid/hero/logo/icon for a game. Returns how many images landed.

    `deadline` is a time.monotonic() value after which no further network call is
    started. Checking it only at the call site was not enough: one call into here
    issues a search, up to five metadata requests and up to five downloads, and
    urlopen's timeout is per socket operation rather than per transfer -- so a
    server dribbling one byte at a time stalls indefinitely without ever tripping
    it. The budget has to be enforced between requests, not just before the first.
    """
    if not SGDB_KEY:
        return 0

    def out_of_time() -> bool:
        return deadline is not None and time.monotonic() >= deadline

    if out_of_time():
        return 0
    found = sgdb(f"/search/autocomplete/{urllib.parse.quote(name)}")
    if not found or not found.get("data"):
        warn(f"no SteamGridDB match for '{name}'")
        return 0
    game_id = found["data"][0]["id"]

    grid_dir.mkdir(parents=True, exist_ok=True)
    # (endpoint, filename suffix, label) — suffixes are what Steam looks for.
    #
    # Both capsule queries ask for the 1x AND 2x dimensions. Asking for one exact
    # size is what left 'Oblivion Remastered' with no wide capsule: SteamGridDB
    # had plenty of grids for it, all uploaded at 920x430, and a query pinned to
    # 460x215 matched none of them. The art was visibly there on the site while
    # the fetch came back empty, which is the least debuggable kind of wrong.
    wanted = [
        (f"/grids/game/{game_id}?dimensions=600x900,1200x1800", "p.png", "portrait capsule"),
        (f"/grids/game/{game_id}?dimensions=460x215,920x430", ".png", "wide capsule"),
        (f"/heroes/game/{game_id}", "_hero.png", "hero"),
        (f"/logos/game/{game_id}", "_logo.png", "logo"),
        (f"/icons/game/{game_id}", "_icon.png", "icon"),
    ]

    count = 0
    for endpoint, suffix, label in wanted:
        # Already have it: don't spend a request re-downloading it. This is what
        # makes a repair run cheap enough to do on every sync.
        if (grid_dir / f"{appid}{suffix}").is_file():
            count += 1
            continue
        data = sgdb(endpoint)
        if not data or not data.get("data"):
            # Silence here is how a partial fetch became invisible. "4/5 images"
            # reads like success; it is not, and nothing said which one was gone.
            warn(f"SteamGridDB has no {label} for '{name}'")
            continue
        url = data["data"][0].get("url")
        if not url:
            continue
        dest = grid_dir / f"{appid}{suffix}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "xsync"})
            if out_of_time():
                warn(f"artwork budget expired part-way through '{name}' — leaving the rest")
                break
            with urllib.request.urlopen(req, timeout=30) as resp:
                # Cap the read. resp.read() with no argument will happily pull
                # whatever the far end sends into memory -- this runs as root on
                # a URL that came off the network, and a Steam grid image has no
                # business being larger than this.
                data = resp.read(MAX_ARTWORK_BYTES + 1)
                if len(data) > MAX_ARTWORK_BYTES:
                    warn(f"{label} for {name} exceeds {MAX_ARTWORK_BYTES // 1048576} MB — skipping")
                    continue
                ctype = resp.headers.get("Content-Type", "")
                if ctype and not ctype.startswith("image/"):
                    warn(f"{label} for {name} is {ctype}, not an image — skipping")
                    continue
                dest.write_bytes(data)
                # Match the grid directory's owner.
                #
                # `sync` drops to the Steam user before it runs, but the `artwork`
                # subcommand is reachable directly and gets run under sudo when
                # repairing a single title -- which leaves root-owned images in a
                # directory Steam owns. They still display, so nothing looks
                # broken, but Steam can never replace them: any artwork the user
                # later sets by hand fails to stick, silently.
                try:
                    st = grid_dir.stat()
                    if os.geteuid() == 0:
                        os.chown(dest, st.st_uid, st.st_gid)
                except Exception as exc:  # noqa: BLE001
                    warn(f"could not set ownership on {dest.name}: {exc}")
            count += 1
        except Exception as exc:  # noqa: BLE001
            warn(f"could not fetch {label} for {name}: {exc}")
    log(f"artwork for '{name}': {count}/{len(wanted)} images")
    return count


# ------------------------------------------------------------------- profiles


def steam_profiles() -> list[Path]:
    userdata = STEAM_ROOT / "userdata"
    if not userdata.is_dir():
        raise SystemExit(f"xsync: no Steam userdata at {userdata}")

    profiles = [p for p in userdata.iterdir() if p.is_dir() and p.name.isdigit()]
    if not profiles:
        raise SystemExit("xsync: no Steam profiles found")

    setting = CFG.get("XSYNC_STEAM_PROFILES", "auto").strip()
    if setting and setting != "auto":
        wanted = set(setting.split())
        chosen = [p for p in profiles if p.name in wanted]
        if not chosen:
            warn(f"none of the configured profiles {wanted} exist — falling back to auto")
        else:
            return chosen

    # "auto": the most recently touched profile. This box has two accounts, and
    # syncing into a dormant one would look like nothing happened.
    newest = max(profiles, key=lambda p: (p / "config").stat().st_mtime if (p / "config").is_dir() else 0)
    return [newest]


# ----------------------------------------------------------------------- sync


def generate_artwork(name: str, appid: int, grid_dir: Path) -> int:
    """
    Build artwork locally for xsync's own entries.

    SteamGridDB is a database of *games*; it has nothing for "run guest
    maintenance". Without this the entry sits in Big Picture as the one bare
    grey tile with a filename on it, in an otherwise finished-looking library.
    Generating it means no assets to ship and no network dependency.
    """
    if not ARTWORK_TOOL.is_file():
        warn(f"artwork generator not found at {ARTWORK_TOOL}")
        return 0

    import subprocess
    import tempfile

    grid_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        # The visible name carries the "xsync:" prefix; the tile reads better
        # with the prefix as the title and the rest as the subtitle.
        title, _, subtitle = name.partition(":")
        try:
            subprocess.run(
                ["bash", str(ARTWORK_TOOL), tmp, title.strip() or "xsync",
                 subtitle.strip() or "Maintenance"],
                check=True, capture_output=True, timeout=120,
            )
        except Exception as exc:  # noqa: BLE001
            warn(f"could not generate artwork for {name}: {exc}")
            return 0

        # Steam's naming: <appid>p.png portrait, <appid>.png wide,
        # <appid>_hero.png banner, <appid>_logo.png overlay, <appid>_icon.png.
        pairs = [
            ("portrait.png", f"{appid}p.png"),
            ("wide.png", f"{appid}.png"),
            ("hero.png", f"{appid}_hero.png"),
            ("logo.png", f"{appid}_logo.png"),
            ("icon.png", f"{appid}_icon.png"),
        ]
        count = 0
        for src, dst in pairs:
            s = Path(tmp) / src
            if s.is_file():
                shutil.copy2(s, grid_dir / dst)
                count += 1
    log(f"generated {count} artwork file(s) for {name}")
    return count


def make_shortcut(game: dict) -> dict:
    name = game["name"]
    exe = f'"{LAUNCHER}"'
    appid = shortcut_appid(exe, name)
    return {
        "appid": signed32(appid),
        "AppName": name,
        "Exe": exe,
        "StartDir": f'"{Path(LAUNCHER).parent}"',
        "icon": "",
        "ShortcutPath": "",
        "LaunchOptions": game["id"],
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
        "tags": {"0": XSYNC_TAG},
    }


def is_ours(sc: dict) -> bool:
    tags = sc.get("tags", {})
    if isinstance(tags, dict) and XSYNC_TAG in tags.values():
        return True
    # Older entries, or ones whose tags a user edited, still match on target.
    return "xsync-launch" in str(sc.get("Exe", ""))


def load_games() -> list[dict]:
    if not GAMES_JSON.is_file():
        warn(f"no game list at {GAMES_JSON} — nothing to sync")
        return []
    try:
        games = json.loads(GAMES_JSON.read_text())
    except Exception as exc:  # noqa: BLE001
        warn(f"unreadable game list: {exc}")
        return []
    return games if isinstance(games, list) else []


ARTWORK_BUDGET_SECONDS = int(os.environ.get("XSYNC_ARTWORK_BUDGET", "120"))


def cmd_sync() -> int:
    games = load_games()

    # Artwork fetching runs on a hard wall-clock budget.
    #
    # This loop executes between gpu.sh reclaim and session.sh start -- with the
    # TV black, the watchdog and exit monitor already stopped, and the unit's
    # TimeoutStartSec=infinity meaning systemd will not intervene. Per game it
    # issues one search plus up to five metadata calls and five downloads, every
    # failure swallowed. urlopen's timeout is per socket operation, not for the
    # whole transfer, so a server that dribbles bytes stalls it indefinitely: the
    # ceiling was not slow, it was unbounded. Fifteen new titles against a flaky
    # uplink left the user staring at a black screen with a dead gamepad and no
    # way back except SSH.
    #
    # Missing artwork is a cosmetic defect. Not getting the TV back is not.
    artwork_deadline = time.monotonic() + ARTWORK_BUDGET_SECONDS
    skipped_art = 0

    # The Xbox app is always present so there is somewhere to install games from,
    # even on a completely fresh setup with nothing in the library yet.
    #
    # Maintenance is present for a different reason: updating the guest's GPU
    # driver needs the card actually attached, so it needs a real handoff, and
    # there is otherwise no route at all from a gamepad in Big Picture to a
    # Windows installer. Making it a library entry is the only way the user can
    # trigger it without a keyboard.
    entries = [
        {"id": "xbox-app", "name": "Xbox"},
        {"id": MAINTENANCE_ID, "name": MAINTENANCE_NAME, "generated_art": True},
    ] + [
        {"id": g["id"], "name": g["name"]} for g in games if g.get("id") and g.get("name")
    ]

    total_new = 0
    for profile in steam_profiles():
        cfg_dir = profile / "config"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        vdf = cfg_dir / "shortcuts.vdf"
        grid = cfg_dir / "grid"

        try:
            existing = read_shortcuts(vdf)
        except ShortcutsUnreadable as exc:
            # Bail out rather than rewrite. Losing the user's own non-Steam
            # shortcuts is far worse than xsync's entries being out of date.
            warn(f"refusing to rewrite an unparseable shortcuts.vdf: {exc}")
            warn("skipping this profile; fix or remove the file to re-enable syncing")
            continue

        preserved = [s for s in existing if not is_ours(s)]
        previous = {s.get("AppName") for s in existing if is_ours(s)}

        ours = [make_shortcut(e) for e in entries]
        write_shortcuts(vdf, preserved + ours)

        added = [e for e in entries if e["name"] not in previous]
        removed = previous - {e["name"] for e in entries}
        log(
            f"profile {profile.name}: {len(ours)} xsync shortcut(s), "
            f"{len(preserved)} preserved, {len(added)} added, {len(removed)} removed"
        )
        total_new += len(added)

        for entry in entries:
            appid = shortcut_appid(f'"{LAUNCHER}"', entry["name"])
            # Only fetch what's missing, so a sync after every session stays cheap.
            #
            # This used to test the portrait alone and treat it as proof that the
            # whole set had landed. A title that got its portrait and nothing else
            # was therefore never retried -- the gap was permanent, and the only
            # symptom was a game that looked wrong in the library forever.
            if artwork_missing(appid, grid):
                if entry.get("generated_art"):
                    generate_artwork(entry["name"], appid, grid)
                elif time.monotonic() < artwork_deadline:
                    fetch_artwork(entry["name"], appid, grid, artwork_deadline)
                else:
                    skipped_art += 1

    if skipped_art:
        warn(
            f"skipped artwork for {skipped_art} title(s): the {ARTWORK_BUDGET_SECONDS}s budget "
            f"expired. They will be retried next sync; the TV comes back now."
        )
    if total_new:
        log(f"{total_new} new game(s) will appear in Steam on next start")
    return 0


def cmd_list() -> int:
    for profile in steam_profiles():
        vdf = profile / "config" / "shortcuts.vdf"
        # `sync` handles an unreadable file gracefully and refuses to rewrite it.
        # `list` used to throw a raw traceback on that exact same state, which
        # is the state you are most likely to be running `list` to investigate.
        try:
            entries = read_shortcuts(vdf)
        except ShortcutsUnreadable as exc:
            print(f"profile {profile.name}: shortcuts.vdf is unreadable ({exc})")
            continue
        ours = [s for s in entries if is_ours(s)]
        print(f"profile {profile.name}: {len(ours)} xsync shortcut(s)")
        for s in ours:
            print(f"  {s.get('AppName'):40} -> {s.get('LaunchOptions')}")
    return 0


def cmd_artwork(game_id: str) -> int:
    games = {g["id"]: g["name"] for g in load_games()}
    games["xbox-app"] = "Xbox"
    if game_id not in games:
        print(f"unknown game id: {game_id}", file=sys.stderr)
        return 1
    name = games[game_id]
    for profile in steam_profiles():
        grid = profile / "config" / "grid"
        fetch_artwork(name, shortcut_appid(f'"{LAUNCHER}"', name), grid)
    return 0


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "sync"
    if cmd == "sync":
        return cmd_sync()
    if cmd == "list":
        return cmd_list()
    if cmd == "artwork":
        if len(argv) < 3:
            print("usage: library.py artwork <game-id>", file=sys.stderr)
            return 64
        return cmd_artwork(argv[2])
    print(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
