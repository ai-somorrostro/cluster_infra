#!/usr/bin/env python3
"""mig_lxd.py - MIG + LXD reconciler. Runs INSIDE a GPU VM as root.

Reads a TOML file that describes the desired state (how each GPU is carved with
MIG, which LXD containers exist, which MIG slice each one gets and which users
it has), compares it with what is in the VM and makes it real.

  mig_lxd.py state                       JSON with GPUs, resources and containers
  mig_lxd.py plan   CONFIG [--prune]     validate + resource checks + diff (no changes)
  mig_lxd.py apply  CONFIG [--prune]     plan, then apply it (idempotent)
  mig_lxd.py boot                        at boot: recreate MIG layouts, rebind and start containers
  mig_lxd.py passwd CONTAINER USER       new temporary password (forced change on login)
  mig_lxd.py layouts                     full MIG layouts of an A800/A100 40GB
  mig_lxd.py expand CONFIG               CONFIG with [lab].users_file read in (no root needed)

Exit codes: 0 OK, 1 error, 3 the config does not pass the checks, 4 a VM restart is needed (MIG mode).
Only the Python standard library is used. Output is ASCII only (qemu-guest-agent).
"""

from __future__ import annotations

import argparse
import datetime as dt
import itertools
import json
import os
import re
import secrets
import shlex
import shutil
import string
import subprocess
import sys
import time
import tomllib
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

INSTALL_DIR = "/opt/mig-lxd"
CONFIG_PATH = "/etc/mig-lxd/config.toml"
ARCHIVE_DIR = "/var/lib/mig-lxd/archive"
UNIT_PATH = "/etc/systemd/system/mig-lxd-boot.service"
POOL = "miglxd"
PROFILE = "miglxd"
BRIDGE = "lxdbr0"
KEY = "user.miglxd."  # prefix of the LXD config keys this tool owns
GIB = 1024**3

# ─── MIG geometry of an A800 / A100 40GB ────────────────────────────────────
# profile -> (compute slices, memory slots, allowed placement starts)
# Confirmed with `nvidia-smi mig -lgipp` on an A800 40GB Active (driver 580).
PROFILES: dict[str, tuple[int, int, tuple[int, ...]]] = {
    "1g.5gb": (1, 1, (0, 1, 2, 3, 4, 5, 6)),
    "1g.10gb": (1, 2, (0, 2, 4, 6)),
    "2g.10gb": (2, 2, (0, 2, 4)),
    "3g.20gb": (3, 4, (0, 4)),
    "4g.20gb": (4, 4, (0,)),
    "7g.40gb": (7, 8, (0,)),
}
PROFILE_GB = {"1g.5gb": 5, "1g.10gb": 10, "2g.10gb": 10, "3g.20gb": 20, "4g.20gb": 20, "7g.40gb": 40}
COMPUTE_SLICES = 7
MEMORY_SLOTS = 8

DEFAULTS = {
    "cpu": 8,
    "memory": "32GB",
    "disk": "100GB",
    "image": "ubuntu:24.04",
    "software": ["python", "uv"],
}

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,30}$")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,61}[a-z0-9]$")


class ConfigError(Exception):
    pass


class RebootRequired(Exception):
    """A MIG mode change is pending: it is applied when the VM restarts (Proxmox resets the GPU)."""


# ─── Small helpers ───────────────────────────────────────────────────────────


def log(msg: str = "") -> None:
    print(msg, flush=True)


def run(cmd: list[str], check: bool = True, input_text: str | None = None, timeout: int = 900) -> str:
    """Runs a command and returns stdout. Raises with stderr on failure."""
    p = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"{shlex.join(cmd)} -> rc {p.returncode}: {(p.stderr or p.stdout).strip()[-800:]}")
    return p.stdout


def ok(cmd: list[str]) -> bool:
    return subprocess.run(cmd, capture_output=True).returncode == 0


def parse_size(v: str | int, what: str) -> int:
    """'32GB' / '32GiB' / '1TB' / '512MB' -> bytes. GB means GiB (powers of 1024)."""
    if isinstance(v, int):
        return v * GIB
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([KMGT])i?B?\s*", str(v), re.I)
    if not m:
        raise ConfigError(f"{what}: invalid size '{v}' (use e.g. 32GB)")
    return int(float(m.group(1)) * 1024 ** "KMGT".index(m.group(2).upper()) * 1024)


def fmt_gb(b: float) -> str:
    return f"{b / GIB:.0f}GB"


def lxd_size(b: int) -> str:
    return f"{b // (1024**2)}MiB"


# ─── Layouts ─────────────────────────────────────────────────────────────────


def parse_layout(text: str) -> list[str] | None:
    """'3x2g.10gb,1g.5gb' -> ['2g.10gb','2g.10gb','2g.10gb','1g.5gb']; 'whole' -> None."""
    text = text.strip().lower()
    if text in ("whole", "none", "off"):
        return None
    out: list[str] = []
    for part in filter(None, (p.strip() for p in text.split(","))):
        m = re.fullmatch(r"(?:(\d+)\s*x\s*)?(\S+)", part)
        n, prof = int(m.group(1) or 1), m.group(2)
        if prof not in PROFILES:
            raise ConfigError(f"Unknown MIG profile '{prof}' (valid: {', '.join(PROFILES)})")
        out += [prof] * n
    if not out:
        raise ConfigError(f"Empty layout '{text}'")
    return out


def pack(profiles: list[str]) -> list[tuple[str, int]] | None:
    """Finds placements for the profiles (largest first). Returns [(profile, start)] or None."""
    if sum(PROFILES[p][0] for p in profiles) > COMPUTE_SLICES:
        return None
    order = sorted(profiles, key=lambda p: (-PROFILES[p][1], -PROFILES[p][0], p))
    used = [False] * MEMORY_SLOTS
    result: list[tuple[str, int]] = []

    def place(i: int) -> bool:
        if i == len(order):
            return True
        p = order[i]
        _, size, starts = PROFILES[p]
        for s in starts:
            if s + size <= MEMORY_SLOTS and not any(used[s : s + size]):
                used[s : s + size] = [True] * size
                result.append((p, s))
                if place(i + 1):
                    return True
                result.pop()
                used[s : s + size] = [False] * size
        return False

    return sorted(result, key=lambda x: x[1]) if place(0) else None


def is_full(profiles: list[str]) -> bool:
    """Full = it fits and not even one more 1g.5gb (the smallest profile) would fit."""
    return pack(profiles) is not None and pack(profiles + ["1g.5gb"]) is None


def layout_str(profiles: list[str] | None) -> str:
    if profiles is None:
        return "whole"
    counts: dict[str, int] = {}
    for p in sorted(profiles, key=lambda p: (-PROFILES[p][1], p)):
        counts[p] = counts.get(p, 0) + 1
    return ",".join(f"{n}x{p}" if n > 1 else p for p, n in counts.items())


def full_layouts() -> list[dict]:
    """Every full layout (multiset of profiles), with what it gives."""
    names = list(PROFILES)
    seen: set[tuple[str, ...]] = set()
    out = []
    for n in range(1, 8):
        for combo in itertools.combinations_with_replacement(names, n):
            if combo in seen or not is_full(list(combo)):
                continue
            seen.add(combo)
            idle = COMPUTE_SLICES - sum(PROFILES[p][0] for p in combo)
            out.append(
                {
                    "layout": layout_str(list(combo)),
                    "instances": len(combo),
                    "idle_compute": idle,
                    "desc": " + ".join(
                        f"{n}x{PROFILE_GB[p]}GB ({PROFILES[p][0]}/7)" for p, n in _count(combo).items()
                    ),
                }
            )
    out.sort(key=lambda x: (x["idle_compute"] > 0, -x["instances"], x["layout"]))
    return out


def _count(items) -> dict[str, int]:
    c: dict[str, int] = {}
    for i in sorted(items, key=lambda p: (-PROFILES[p][1], p)):
        c[i] = c.get(i, 0) + 1
    return c


# ─── Config ──────────────────────────────────────────────────────────────────


@dataclass
class CtSpec:
    name: str
    gpu: int | None  # None only for [lab] containers before resolve_lab()
    profile: str | None  # None = whole GPU
    cpu: int
    memory: int
    disk: int
    image: str
    software: list[str]
    users: list[str]
    lab: bool = False  # generated from [lab]: GPU chosen by resolve_lab()


@dataclass
class Lab:
    profile: str
    gpus: list[int]


@dataclass
class Config:
    gpus: dict[int, list[str] | None]  # index -> profiles (None = whole)
    containers: list[CtSpec]
    storage_device: str
    ssh_port_base: int
    memory_reserve: int | None
    max_cpu_overcommit: float
    raw: str = ""
    lab: Lab | None = None


def lab_username(name: str) -> str:
    """Username from a people list: lowercase, '.' -> '_' (nombre.apellido -> nombre_apellido)."""
    return name.strip().lower().replace(".", "_")


def lab_container(prefix: str, user: str) -> str:
    return (prefix + user.replace("_", "-")).strip("-")[:63].rstrip("-")


def read_users_file(path: str) -> list[str]:
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        raise ConfigError(f"[lab].users_file: cannot read {path}: {e.strerror}") from e
    return [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("#")]


def expand_lab_users(d: dict, base_dir: str) -> dict:
    """Resolves [lab].users_file (relative to the config file) into [lab].users, normalised.
    The result is self-contained: it is what gets uploaded to the VM."""
    lab = d.get("lab")
    if not lab:
        return d
    users = [str(u) for u in lab.get("users", [])]
    if lab.get("users_file"):
        f = str(lab["users_file"])
        users += read_users_file(f if os.path.isabs(f) else os.path.join(base_dir, f))
    lab = {k: v for k, v in lab.items() if k != "users_file"}
    lab["users"] = [lab_username(u) for u in users]
    return {**d, "lab": lab}


def load_config(path: str) -> Config:
    raw = open(path, encoding="utf-8").read()
    try:
        d = tomllib.loads(raw)
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: {e}") from e
    d = expand_lab_users(d, os.path.dirname(os.path.abspath(path)))
    gpus: dict[int, list[str] | None] = {}
    for k, v in d.get("gpus", {}).items():
        if not str(k).isdigit():
            raise ConfigError(f"[gpus]: key '{k}' must be a GPU index (0, 1, ...)")
        gpus[int(k)] = parse_layout(str(v))
    df = {**DEFAULTS, **d.get("defaults", {})}
    cts = []
    for i, c in enumerate(d.get("containers", [])):
        where = f"containers[{i}]"
        if "name" not in c or "gpu" not in c:
            raise ConfigError(f"{where}: 'name' and 'gpu' are required")
        cts.append(
            CtSpec(
                name=str(c["name"]),
                gpu=int(c["gpu"]),
                profile=(str(c["profile"]).lower() if c.get("profile") else None),
                cpu=int(c.get("cpu", df["cpu"])),
                memory=parse_size(c.get("memory", df["memory"]), f"{where}.memory"),
                disk=parse_size(c.get("disk", df["disk"]), f"{where}.disk"),
                image=str(c.get("image", df["image"])),
                software=list(c.get("software", df["software"])),
                users=[str(u) for u in c.get("users", [])],
            )
        )
    lab = None
    if d.get("lab"):
        lb = d["lab"]
        if not lb.get("profile"):
            raise ConfigError("[lab]: 'profile' is required (e.g. \"1g.5gb\")")
        prof = str(lb["profile"]).lower()
        lab_gpus = [int(g) for g in lb.get("gpus", [])] or sorted(
            i for i, lay in gpus.items() if lay is not None and prof in lay
        )
        lab = Lab(profile=prof, gpus=lab_gpus)
        ldf = {**df, **{k: v for k, v in lb.items() if k in DEFAULTS}}
        prefix = str(lb.get("prefix", "lab-"))
        for u in lb.get("users", []):
            where = f"[lab] user '{u}'"
            cts.append(
                CtSpec(
                    name=lab_container(prefix, u),
                    gpu=None,
                    profile=prof,
                    cpu=int(ldf["cpu"]),
                    memory=parse_size(ldf["memory"], f"{where}.memory"),
                    disk=parse_size(ldf["disk"], f"{where}.disk"),
                    image=str(ldf["image"]),
                    software=list(ldf["software"]),
                    users=[u],
                    lab=True,
                )
            )
    reserve = d.get("memory_reserve")
    return Config(
        gpus=gpus,
        containers=cts,
        lab=lab,
        storage_device=str(d.get("storage_device", "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1")),
        ssh_port_base=int(d.get("ssh_port_base", 2201)),
        memory_reserve=parse_size(reserve, "memory_reserve") if reserve else None,
        max_cpu_overcommit=float(d.get("max_cpu_overcommit", 2.0)),
        raw=raw,
    )


# ─── Live state ──────────────────────────────────────────────────────────────


@dataclass
class GI:
    profile: str
    gi: int
    start: int
    size: int
    uuid: str = ""


@dataclass
class Gpu:
    index: int
    name: str
    pci: str  # LXD format 0000:01:00.0
    mig_capable: bool
    mig_current: bool
    mig_pending: bool
    gis: list[GI] = field(default_factory=list)

    @property
    def layout(self) -> list[str] | None:
        return sorted(g.profile for g in self.gis) if self.mig_current else None


def read_gpus() -> list[Gpu]:
    out = run(
        [
            "nvidia-smi",
            "--query-gpu=index,name,pci.bus_id,mig.mode.current,mig.mode.pending",
            "--format=csv,noheader",
        ]
    )
    gpus = []
    for line in out.strip().splitlines():
        idx, name, bus, cur, pend = (x.strip() for x in line.split(","))
        gpus.append(
            Gpu(
                index=int(idx),
                name=name,
                pci=bus[-12:].lower(),
                mig_capable=cur in ("Enabled", "Disabled"),
                mig_current=cur == "Enabled",
                mig_pending=pend == "Enabled",
            )
        )
    for g in gpus:
        if g.mig_current:
            g.gis = read_gis(g.index)
    return gpus


_GI_ROW = re.compile(r"^\|\s+(\d+)\s+MIG\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+):(\d+)\s+\|")


def read_gis(index: int) -> list[GI]:
    out = run(["nvidia-smi", "mig", "-i", str(index), "-lgi"], check=False)
    gis = []
    for line in out.splitlines():
        m = _GI_ROW.match(line)
        if m:
            gis.append(GI(profile=m.group(2), gi=int(m.group(4)), start=int(m.group(5)), size=int(m.group(6))))
    # MIG device UUIDs: `nvidia-smi -L` "Device N" <-> `-q -x` mig_device index N -> gpu_instance_id
    uuids: dict[int, str] = {}
    cur = None
    for line in run(["nvidia-smi", "-L"]).splitlines():
        m = re.match(r"GPU (\d+):", line)
        if m:
            cur = int(m.group(1))
            continue
        m = re.search(r"Device\s+(\d+): \(UUID: (MIG-[0-9a-f-]+)\)", line)
        if m and cur == index:
            uuids[int(m.group(1))] = m.group(2)
    root = ET.fromstring(run(["nvidia-smi", "-q", "-x", "-i", str(index)]))
    by_gi = {}
    for md in root.iter("mig_device"):
        try:
            by_gi[int(md.findtext("gpu_instance_id"))] = uuids.get(int(md.findtext("index")), "")
        except (TypeError, ValueError):
            pass
    for g in gis:
        g.uuid = by_gi.get(g.gi, "")
    return sorted(gis, key=lambda g: g.start)


def lxd_installed() -> bool:
    return ok(["snap", "list", "lxd"])


def lxc(*args: str, check: bool = True, timeout: int = 900) -> str:
    return run(["lxc", *args], check=check, timeout=timeout)


def lxc_json(*args: str):
    return json.loads(lxc(*args) or "null")


@dataclass
class CtState:
    name: str
    status: str
    managed: bool
    gpu: int | None
    profile: str | None
    slot: int | None
    cpu: int | None
    memory: int | None
    disk: int | None
    port: int | None
    users: list[str]
    software: list[str]
    provisioned: bool = True


def read_containers() -> list[CtState]:
    if not lxd_installed() or not ok(["lxc", "info"]):
        return []
    out = []
    for c in lxc_json("list", "--format", "json") or []:
        cfg = c.get("config", {})
        dev = c.get("devices", {}) or {}
        exp = c.get("expanded_devices", {}) or {}
        root = dev.get("root") or exp.get("root") or {}

        def num(k, conv=int):
            v = cfg.get(k)
            try:
                return conv(v) if v not in (None, "") else None
            except ValueError:
                return None

        mem = cfg.get("limits.memory")
        out.append(
            CtState(
                name=c["name"],
                status=c.get("status", "?"),
                managed=cfg.get(KEY + "managed") == "true",
                gpu=num(KEY + "gpu"),
                profile=cfg.get(KEY + "profile") or None,
                slot=num(KEY + "slot"),
                cpu=num("limits.cpu"),
                memory=parse_size(mem, "limits.memory") if mem else None,
                disk=parse_size(root["size"], "root size") if root.get("size") else None,
                port=num(KEY + "ssh_port"),
                users=[u for u in cfg.get(KEY + "users", "").split(",") if u],
                software=[s for s in cfg.get(KEY + "software", "").split(",") if s],
                provisioned=cfg.get(KEY + "provisioned") == "true",
            )
        )
    return out


def read_resources(cfg: Config | None) -> dict:
    mem_total = 0
    for line in open("/proc/meminfo"):
        if line.startswith("MemTotal:"):
            mem_total = int(line.split()[1]) * 1024
    pool_total = pool_used = None
    pool_exists = False
    if lxd_installed() and ok(["lxc", "storage", "show", POOL]):
        pool_exists = True
        r = json.loads(lxc("query", f"/1.0/storage-pools/{POOL}/resources"))
        pool_total, pool_used = r["space"]["total"], r["space"]["used"]
    dev = cfg.storage_device if cfg else "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1"
    dev_size = None
    if os.path.exists(dev):
        dev_size = int(run(["blockdev", "--getsize64", dev]).strip())
    return {
        "memory_total": mem_total,
        "cpus": os.cpu_count() or 1,
        "pool_exists": pool_exists,
        "pool_total": pool_total,
        "pool_used": pool_used,
        "storage_device": dev,
        "storage_device_size": dev_size,
    }


# ─── Validation and resource checks ──────────────────────────────────────────


def resolve_lab(cfg: Config, cts: list[CtState]) -> None:
    """Gives each [lab] container a GPU with a free slice of the lab profile.

    Existing containers keep their GPU, so adding or removing people does not move
    the others; new ones fill the GPUs in order (GPU 0 first)."""
    lab_specs = [c for c in cfg.containers if c.lab and c.gpu is None]
    if not lab_specs or cfg.lab is None:
        return
    prof = cfg.lab.profile
    free = {g: (cfg.gpus.get(g) or []).count(prof) for g in cfg.lab.gpus}
    for c in cfg.containers:
        if not c.lab and c.profile == prof and c.gpu in free:
            free[c.gpu] -= 1
    current = {c.name: c for c in cts if c.managed}
    pending = []
    for spec in lab_specs:
        cur = current.get(spec.name)
        if cur and cur.profile == prof and cur.gpu in free and free[cur.gpu] > 0:
            spec.gpu = cur.gpu
            free[cur.gpu] -= 1
        else:
            pending.append(spec)
    for spec in pending:
        g = next((g for g in cfg.lab.gpus if free[g] > 0), None)
        if g is None:
            total = sum((cfg.gpus.get(g) or []).count(prof) for g in cfg.lab.gpus)
            raise ConfigError(
                f"[lab]: {len(lab_specs)} people but only {total} '{prof}' slices on GPUs "
                f"{cfg.lab.gpus or '(none)'} (minus the [[containers]] using them); "
                f"no slice for: {', '.join(s.name for s in pending[pending.index(spec):])}"
            )
        spec.gpu = g
        free[g] -= 1



def validate(cfg: Config, gpus: list[Gpu], cts: list[CtState]) -> list[str]:
    errors = []
    by_index = {g.index: g for g in gpus}
    for idx, layout in cfg.gpus.items():
        g = by_index.get(idx)
        if g is None:
            errors.append(f"GPU {idx}: not visible to the driver (visible: {sorted(by_index)}); if it was there, restart the VM from Proxmox")
            continue
        if layout is not None:
            if not g.mig_capable:
                errors.append(f"GPU {idx} ({g.name}): does not support MIG")
            elif pack(layout) is None:
                errors.append(f"GPU {idx}: layout '{layout_str(layout)}' does not fit in the GPU")
            elif not is_full(layout):
                errors.append(
                    f"GPU {idx}: layout '{layout_str(layout)}' leaves part of the GPU unused; "
                    "use a full layout (see 'layouts')"
                )
    names = set()
    unmanaged = {c.name for c in cts if not c.managed}
    use: dict[tuple[int, str | None], list[str]] = {}
    for c in cfg.containers:
        if not NAME_RE.match(c.name):
            errors.append(f"Container '{c.name}': invalid name (a-z, 0-9, '-', 2-63 chars)")
        if c.name in names:
            errors.append(f"Container '{c.name}': duplicated")
        names.add(c.name)
        if c.name in unmanaged:
            errors.append(f"Container '{c.name}': already exists in LXD and is not managed by this tool")
        if c.gpu not in cfg.gpus:
            errors.append(f"Container '{c.name}': GPU {c.gpu} is not in [gpus]")
            continue
        layout = cfg.gpus[c.gpu]
        if layout is None and c.profile:
            errors.append(f"Container '{c.name}': GPU {c.gpu} is 'whole', remove 'profile'")
        if layout is not None and not c.profile:
            errors.append(f"Container '{c.name}': GPU {c.gpu} uses MIG, set 'profile' ({', '.join(sorted(set(layout)))})")
        use.setdefault((c.gpu, c.profile), []).append(c.name)
        if not c.users:
            errors.append(f"Container '{c.name}': no users")
        if len(set(c.users)) != len(c.users):
            errors.append(f"Container '{c.name}': repeated user")
        for u in c.users:
            if not USER_RE.match(u) or u in ("root", "ubuntu"):
                errors.append(f"Container '{c.name}': invalid user name '{u}' (a-z, 0-9, '_', '-', max 31)")
        if c.cpu < 1:
            errors.append(f"Container '{c.name}': cpu must be >= 1")
        for s in c.software:
            if s not in ("python", "uv") and not s.startswith(("apt:", "pip:")):
                errors.append(f"Container '{c.name}': unknown software '{s}' (python, uv, apt:PKG, pip:PKG)")
    for (gpu, prof), who in use.items():
        layout = cfg.gpus.get(gpu, "missing")
        if layout == "missing":
            continue
        if layout is None:
            if len(who) > 1:
                errors.append(f"GPU {gpu} is whole and can only have one container: {', '.join(who)}")
        elif prof:
            have = layout.count(prof)
            if have == 0:
                errors.append(f"GPU {gpu} has no '{prof}' instances (layout {layout_str(layout)}): {', '.join(who)}")
            elif len(who) > have:
                errors.append(f"GPU {gpu}: {len(who)} containers want '{prof}' but the layout has {have}: {', '.join(who)}")
    return errors


def resource_check(cfg: Config, cts: list[CtState], res: dict, prune: bool) -> tuple[list[list[str]], list[str], list[str]]:
    """Returns (table rows, errors, warnings)."""
    errors: list[str] = []
    warns: list[str] = []
    wanted = {c.name for c in cfg.containers}
    extra = [c for c in cts if c.name not in wanted and not (prune and c.managed)]
    for c in extra:
        if c.memory is None:
            warns.append(f"Container '{c.name}' (not in the config) has no memory limit: it can use any RAM")
    mem_total = res["memory_total"]
    reserve = cfg.memory_reserve or max(8 * GIB, mem_total // 10)
    mem_req = sum(c.memory for c in cfg.containers) + sum(c.memory or 0 for c in extra)
    mem_free = mem_total - reserve - mem_req

    if res["pool_exists"]:
        disk_total, disk_src = res["pool_total"], f"pool {POOL}"
    else:
        disk_total, disk_src = res["storage_device_size"], res["storage_device"]
    overhead = 2 * GIB  # image + container base per container
    disk_req = sum(c.disk + overhead for c in cfg.containers) + sum((c.disk or 0) + overhead for c in extra)
    disk_reserve = int((disk_total or 0) * 0.05)

    cpus = res["cpus"]
    cpu_req = sum(c.cpu for c in cfg.containers) + sum(c.cpu or 0 for c in extra)

    rows = [["Resource", "VM total", "Reserved", "Requested", "Free after", "Status"]]
    st = "OK" if mem_free >= 0 else "FAIL"
    rows.append(["RAM", fmt_gb(mem_total), fmt_gb(reserve), fmt_gb(mem_req), fmt_gb(mem_free), st])
    if st == "FAIL":
        errors.append(
            f"RAM: the containers ask {fmt_gb(mem_req)} but only {fmt_gb(mem_total - reserve)} are available "
            f"(VM {fmt_gb(mem_total)} - reserve {fmt_gb(reserve)}). Lower 'memory' or give the VM more RAM in Proxmox."
        )
    if disk_total is None:
        rows.append(["Disk", "-", "-", fmt_gb(disk_req), "-", "FAIL"])
        errors.append(f"Disk: storage device {res['storage_device']} not found (add a disk to the VM for the LXD pool)")
    else:
        disk_free = disk_total - disk_reserve - disk_req
        st = "OK" if disk_free >= 0 else "FAIL"
        rows.append(["Disk", fmt_gb(disk_total), fmt_gb(disk_reserve), fmt_gb(disk_req), fmt_gb(disk_free), st])
        if st == "FAIL":
            errors.append(
                f"Disk: the containers ask {fmt_gb(disk_req)} (quotas + {fmt_gb(overhead)} each) but {disk_src} has "
                f"{fmt_gb(disk_total - disk_reserve)} usable. Lower 'disk' or grow the disk in Proxmox."
            )
    ratio = cpu_req / cpus
    if ratio <= 1:
        st = "OK"
    elif ratio <= cfg.max_cpu_overcommit:
        st = f"WARN {ratio:.2f}x"
        warns.append(f"CPU: {cpu_req} vCPUs requested on {cpus}: they will share CPU (slower, no crash)")
    else:
        st = "FAIL"
        errors.append(f"CPU: {cpu_req} vCPUs requested on {cpus} (> max_cpu_overcommit {cfg.max_cpu_overcommit}x)")
    rows.append(["CPU", str(cpus), "-", str(cpu_req), str(cpus - cpu_req), st])
    return rows, errors, warns


def print_table(rows: list[list[str]], indent: str = "  ") -> None:
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for r in rows:
        log(indent + "  ".join(c.ljust(w[i]) for i, c in enumerate(r)).rstrip())


# ─── Plan ────────────────────────────────────────────────────────────────────


@dataclass
class Plan:
    gpu_changes: dict[int, str] = field(default_factory=dict)  # index -> description
    gpu_targets: dict[int, list[tuple[str, int]] | None] = field(default_factory=dict)
    creates: list[CtSpec] = field(default_factory=list)
    updates: dict[str, list[str]] = field(default_factory=dict)
    rebinds: dict[str, tuple[int, str | None, int | None]] = field(default_factory=dict)
    add_users: dict[str, list[str]] = field(default_factory=dict)
    add_software: dict[str, list[str]] = field(default_factory=dict)
    deletes: list[str] = field(default_factory=list)
    stops: set[str] = field(default_factory=set)
    notes: list[str] = field(default_factory=list)
    setup_needed: list[str] = field(default_factory=list)

    def empty(self) -> bool:
        return not (
            self.gpu_changes or self.creates or self.updates or self.rebinds or self.add_users
            or self.add_software or self.deletes or self.setup_needed
        )


MODESET_CONF = "/etc/modprobe.d/nvidia-graphics-drivers-kms.conf"
OLD_MODESET_CONF = "/etc/modprobe.d/mig-lxd-nvidia.conf"  # earlier name, overridden by /lib
MODESET_TEXT = "# mig-lxd: compute-only VM, no KMS (it keeps the GPUs open). Replaces the /lib/modprobe.d file.\noptions nvidia-drm modeset=0\n"


def modeset_missing() -> bool:
    try:
        return open(MODESET_CONF, encoding="utf-8").read() != MODESET_TEXT
    except OSError:
        return True


def setup_status(cfg: Config) -> list[str]:
    need = []
    if not lxd_installed():
        need.append("install LXD (snap 5.21/stable)")
    if not os.path.exists(UNIT_PATH):
        need.append("install mig-lxd-boot.service (restores MIG and containers at boot)")
    if modeset_missing():
        need.append(f"disable nvidia-drm modeset (compute-only VM): {MODESET_CONF}")
    if not os.path.exists("/etc/systemd/system/nvidia-persistenced.service.d/mig-lxd.conf"):
        need.append("enable NVIDIA persistence mode (keeps the passthrough GPUs initialised)")
    if not os.path.exists("/etc/apt/apt.conf.d/51mig-lxd-hold"):
        need.append("hold kernel + NVIDIA packages (no automatic upgrades)")
    if not lxd_installed() or not ok(["lxc", "storage", "show", POOL]):
        need.append(f"create btrfs storage pool '{POOL}' on {cfg.storage_device}")
    if not lxd_installed() or not ok(["lxc", "profile", "show", PROFILE]):
        need.append(f"create LXD profile '{PROFILE}' (NVIDIA runtime, hard memory limits)")
    if firewall_missing(cfg):
        need.append(f"open UFW for the LXD bridge and SSH ports {cfg.ssh_port_base}-{cfg.ssh_port_base + 99}")
    try:
        installed = open(CONFIG_PATH, encoding="utf-8").read()
    except OSError:
        installed = None
    if installed != cfg.raw:
        need.append(f"install this config as {CONFIG_PATH}")
    return need


def make_plan(cfg: Config, gpus: list[Gpu], cts: list[CtState], prune: bool) -> Plan:
    plan = Plan(setup_needed=setup_status(cfg))
    by_index = {g.index: g for g in gpus}
    current = {c.name: c for c in cts}

    # GPUs
    for idx, layout in sorted(cfg.gpus.items()):
        g = by_index[idx]
        target = pack(layout) if layout else None
        plan.gpu_targets[idx] = target
        if layout is None:
            if g.mig_current or g.mig_pending:
                plan.gpu_changes[idx] = f"MIG on ({layout_str(g.layout)}) -> whole GPU (MIG off: VM restart)"
        elif not g.mig_current:
            plan.gpu_changes[idx] = f"whole GPU -> MIG {layout_str(layout)} (MIG on: VM restart)"
        elif sorted((gi.profile, gi.start) for gi in g.gis) != sorted(target):
            plan.gpu_changes[idx] = f"MIG {layout_str(g.layout) if g.gis else 'empty'} -> {layout_str(layout)}"
    for c in cts:
        if c.managed and c.gpu in plan.gpu_changes and c.status == "Running":
            plan.stops.add(c.name)

    # Slot assignment (same algorithm as apply)
    assign = assign_slots(cfg, cts, set(plan.gpu_changes))
    for spec in cfg.containers:
        cur = current.get(spec.name)
        slot = assign.get(spec.name)
        if cur is None or (cur.managed and not cur.provisioned):
            if cur is not None:
                plan.notes.append(f"{spec.name}: creation did not finish last time, it is recreated")
            plan.creates.append(spec)
            continue
        changes = []
        if cur.cpu != spec.cpu:
            changes.append(f"cpu {cur.cpu} -> {spec.cpu}")
        if cur.memory != spec.memory:
            changes.append(f"memory {fmt_gb(cur.memory or 0)} -> {fmt_gb(spec.memory)}")
        if cur.disk != spec.disk:
            if cur.disk and spec.disk < cur.disk:
                plan.notes.append(f"{spec.name}: disk {fmt_gb(cur.disk)} -> {fmt_gb(spec.disk)} (shrink: fails if the data does not fit)")
            changes.append(f"disk {fmt_gb(cur.disk or 0)} -> {fmt_gb(spec.disk)}")
        if changes:
            plan.updates[spec.name] = changes
        if (cur.gpu, cur.profile, cur.slot) != (spec.gpu, spec.profile, slot) or spec.gpu in plan.gpu_changes:
            plan.rebinds[spec.name] = (spec.gpu, spec.profile, slot)
            if cur.status == "Running":
                plan.stops.add(spec.name)
        new_users = [u for u in spec.users if u not in cur.users]
        if new_users:
            plan.add_users[spec.name] = new_users
        gone = [u for u in cur.users if u not in spec.users]
        if gone:
            plan.notes.append(f"{spec.name}: users {', '.join(gone)} are no longer in the config (not deleted)")
        new_sw = [s for s in spec.software if s not in cur.software]
        if new_sw:
            plan.add_software[spec.name] = new_sw
    wanted = {c.name for c in cfg.containers}
    for c in cts:
        if c.managed and c.name not in wanted:
            if prune:
                plan.deletes.append(c.name)
            else:
                plan.notes.append(f"{c.name}: not in the config (kept; use --prune to delete it)")
                if c.gpu in plan.gpu_changes:
                    plan.notes.append(f"{c.name}: its GPU {c.gpu} changes layout, it will be left without GPU")
    return plan


def assign_slots(cfg: Config, cts: list[CtState], changed_gpus: set[int]) -> dict[str, int | None]:
    """Container -> placement start of its MIG slice (None = whole GPU). Keeps current slots when possible."""
    current = {c.name: c for c in cts}
    out: dict[str, int | None] = {}
    free: dict[int, dict[str, list[int]]] = {}
    for idx, layout in cfg.gpus.items():
        if layout is None:
            continue
        free[idx] = {}
        for prof, start in pack(layout):
            free[idx].setdefault(prof, []).append(start)
    pending = []
    for spec in cfg.containers:
        if cfg.gpus.get(spec.gpu) is None:
            out[spec.name] = None
            continue
        cur = current.get(spec.name)
        starts = free.get(spec.gpu, {}).get(spec.profile, [])
        if cur and cur.gpu == spec.gpu and cur.profile == spec.profile and cur.slot in starts:
            starts.remove(cur.slot)
            out[spec.name] = cur.slot
        else:
            pending.append(spec)
    for spec in pending:
        starts = free.get(spec.gpu, {}).get(spec.profile, [])
        out[spec.name] = starts.pop(0) if starts else None
    return out


def print_plan(cfg: Config, plan: Plan, gpus: list[Gpu], cts: list[CtState]) -> None:
    by_index = {g.index: g for g in gpus}
    log("GPUs:")
    for idx in sorted(cfg.gpus):
        g = by_index[idx]
        mark = "~" if idx in plan.gpu_changes else "="
        desc = plan.gpu_changes.get(idx) or f"{layout_str(cfg.gpus[idx])} (no change)"
        log(f"  {mark} GPU {idx} {g.pci}  {desc}")
    for g in gpus:
        if g.index not in cfg.gpus:
            log(f"  = GPU {g.index} {g.pci}  not in the config (left as is: {layout_str(g.layout)})")
    if plan.setup_needed:
        log("Setup:")
        for s in plan.setup_needed:
            log(f"  + {s}")
    assign = assign_slots(cfg, cts, set(plan.gpu_changes))
    log("Containers:")
    for spec in plan.creates:
        log(f"  + {spec.name:<16} {slice_desc(spec, assign.get(spec.name))}  {spec.cpu} CPU / {fmt_gb(spec.memory)} / {fmt_gb(spec.disk)}  users: {', '.join(spec.users)}")
    for name, ch in plan.updates.items():
        log(f"  ~ {name:<16} {', '.join(ch)}")
    spec_by = {c.name: c for c in cfg.containers}
    for name, (gpu, prof, slot) in plan.rebinds.items():
        log(f"  ~ {name:<16} GPU -> {slice_desc(spec_by[name], slot)}")
    for name, users in plan.add_users.items():
        log(f"  + users {', '.join(users)} @ {name}")
    for name, sw in plan.add_software.items():
        log(f"  + software {', '.join(sw)} @ {name}")
    for name in plan.deletes:
        log(f"  - {name:<16} (deleted; /home archived to {ARCHIVE_DIR} first)")
    if plan.stops:
        log(f"Stopped during apply: {', '.join(sorted(plan.stops))}")
    for n in plan.notes:
        log(f"  ! {n}")
    if plan.empty():
        log("  No changes.")


def slice_desc(spec: CtSpec, slot: int | None) -> str:
    if spec.profile is None:
        return f"GPU {spec.gpu} whole"
    return f"GPU {spec.gpu} {spec.profile}@{slot}"


# ─── Apply: base setup ───────────────────────────────────────────────────────


def setup_base(cfg: Config, config_path: str) -> None:
    os.makedirs(INSTALL_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    me = os.path.realpath(__file__)
    if me != os.path.join(INSTALL_DIR, "mig_lxd.py"):
        shutil.copy(me, os.path.join(INSTALL_DIR, "mig_lxd.py"))
    if os.path.realpath(config_path) != CONFIG_PATH:
        shutil.copy(config_path, CONFIG_PATH)
    os.chmod(CONFIG_PATH, 0o600)

    # Package hold: a kernel upgrade without its NVIDIA module leaves the VM without GPUs
    hold = [
        p
        for p in run(["dpkg-query", "-W", "-f", "${Package} ${Status}\n"]).splitlines()
        if p.endswith("install ok installed")
        and re.match(r"(linux-(generic|image-generic|headers-generic|modules-nvidia-\S+-generic)|nvidia-driver-\S+) ", p)
    ]
    pkgs = [p.split()[0] for p in hold]
    if pkgs:
        run(["apt-mark", "hold", *pkgs])
    with open("/etc/apt/apt.conf.d/51mig-lxd-hold", "w") as f:
        f.write(
            "// mig-lxd: no automatic kernel / NVIDIA upgrades (managed by hand)\n"
            'Unattended-Upgrade::Package-Blacklist { "linux-"; "nvidia-"; "libnvidia-"; };\n'
        )
    # nvidia-drm modeset keeps the GPUs open: not needed in a compute-only VM.
    # Same name as the driver package's file in /lib/modprobe.d, so this one replaces it
    # (a different name would be read too, and its modeset=1 would win).
    if modeset_missing():
        with open(MODESET_CONF, "w") as f:
            f.write(MODESET_TEXT)
        if os.path.exists(OLD_MODESET_CONF):
            os.remove(OLD_MODESET_CONF)
        run(["update-initramfs", "-u"], check=False, timeout=600)
        log("  nvidia-drm modeset=0 takes effect at the next VM restart")
    # Persistence mode: without it the driver tears the GPUs down when the last process
    # exits, and re-initialising a passthrough GPU can fail ("WPR2 already up").
    dropin = "/etc/systemd/system/nvidia-persistenced.service.d/mig-lxd.conf"
    if not os.path.exists(dropin):
        os.makedirs(os.path.dirname(dropin), exist_ok=True)
        with open(dropin, "w") as f:
            f.write("[Service]\nExecStart=\nExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --persistence-mode --verbose\n")
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "restart", "nvidia-persistenced"], check=False)
    run(["nvidia-smi", "-pm", "1"], check=False)

    # LXD
    if not lxd_installed():
        log("  installing LXD snap")
        run(["snap", "install", "lxd", "--channel=5.21/stable"], timeout=1800)
    run(["snap", "start", "lxd"], check=False)
    run(["lxd", "waitready", "--timeout=120"])
    if not ok(["lxc", "storage", "show", POOL]):
        dev = os.path.realpath(cfg.storage_device)
        sig = run(["lsblk", "-no", "FSTYPE,TYPE", dev]).split()
        if not os.path.exists(dev):
            raise RuntimeError(f"Storage device {cfg.storage_device} does not exist")
        if any(s not in ("disk",) for s in sig) or run(["lsblk", "-no", "NAME", dev]).count("\n") > 1:
            raise RuntimeError(f"{dev} is not empty (filesystem or partitions): refusing to use it for the LXD pool")
        log(f"  creating btrfs pool {POOL} on {dev}")
        lxc("storage", "create", POOL, "btrfs", f"source={cfg.storage_device}")
    if not ok(["lxc", "network", "show", BRIDGE]):
        lxc("network", "create", BRIDGE, "ipv4.address=auto", "ipv4.nat=true", "ipv6.address=none")
    if not ok(["lxc", "profile", "show", PROFILE]):
        lxc("profile", "create", PROFILE)
    profile_yaml = f"""config:
  boot.autostart: "false"
  nvidia.runtime: "true"
  nvidia.driver.capabilities: compute,utility
  limits.memory.enforce: hard
  limits.memory.swap: "false"
  security.nesting: "false"
description: mig-lxd containers (managed by mig_lxd.py)
devices:
  eth0:
    name: eth0
    network: {BRIDGE}
    type: nic
  root:
    path: /
    pool: {POOL}
    type: disk
"""
    run(["lxc", "profile", "edit", PROFILE], input_text=profile_yaml)
    firewall_rules(cfg)

    unit = f"""[Unit]
Description=mig-lxd: recreate MIG layouts and start the GPU containers
After=nvidia-persistenced.service snap.lxd.daemon.unix.socket network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 {INSTALL_DIR}/mig_lxd.py boot
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
"""
    with open(UNIT_PATH, "w") as f:
        f.write(unit)
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "mig-lxd-boot.service"])


def ufw_active() -> bool:
    return shutil.which("ufw") is not None and "Status: active" in run(["ufw", "status"], check=False)


def ufw_rules(cfg: Config) -> list[list[str]]:
    last = cfg.ssh_port_base + 99
    return [
        ["allow", "in", "on", BRIDGE, "comment", "mig-lxd: DHCP/DNS of the LXD bridge"],
        ["route", "allow", "in", "on", BRIDGE, "comment", "mig-lxd: containers to the network"],
        ["route", "allow", "out", "on", BRIDGE, "comment", "mig-lxd: replies to the containers"],
        ["allow", f"{cfg.ssh_port_base}:{last}/tcp", "comment", "mig-lxd: SSH of the containers"],
    ]


def firewall_rules(cfg: Config) -> None:
    """The LXD bridge needs DHCP/DNS (INPUT) and forwarding; UFW and Docker block both."""
    if ufw_active():
        for r in ufw_rules(cfg):
            run(["ufw", *r])
    docker_forward_rules()


def firewall_missing(cfg: Config) -> bool:
    if ufw_active():
        st = run(["ufw", "status"], check=False)
        if f"on {BRIDGE}" not in st or f"{cfg.ssh_port_base}:{cfg.ssh_port_base + 99}/tcp" not in st:
            return True
    return False


def docker_forward_rules() -> None:
    """Docker sets FORWARD policy DROP, which cuts the LXD bridge off. Allow it in DOCKER-USER."""
    if not ok(["iptables", "-L", "DOCKER-USER", "-n"]):
        return
    for rule in (
        ["-i", BRIDGE, "-j", "ACCEPT"],
        ["-o", BRIDGE, "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"],
    ):
        if not ok(["iptables", "-C", "DOCKER-USER", *rule]):
            run(["iptables", "-I", "DOCKER-USER", *rule])


# ─── Apply: GPUs ─────────────────────────────────────────────────────────────


def set_mig_mode(idx: int, enable: bool) -> bool:
    """Sets the MIG mode. Returns True if it is already effective, False if it waits for a VM restart.

    The GPU is NEVER reset from inside the VM: with PCI passthrough an in-guest reset leaves
    the GSP firmware in a bad state ("WPR2 already up") and the GPU disappears until the VM
    is restarted. A Proxmox restart resets the device properly and applies the pending mode.
    """
    run(["nvidia-smi", "-i", str(idx), "-mig", "1" if enable else "0"], check=False)
    g = next(g for g in read_gpus() if g.index == idx)
    return g.mig_current == enable


def apply_layout(idx: int, target: list[tuple[str, int]]) -> None:
    run(["nvidia-smi", "mig", "-i", str(idx), "-dci"], check=False)
    run(["nvidia-smi", "mig", "-i", str(idx), "-dgi"], check=False)
    if read_gis(idx):
        raise RuntimeError(f"GPU {idx}: could not destroy the old MIG instances (in use?)")
    tuples = ",".join(f"{p}:{s}" for p, s in target)
    run(["nvidia-smi", "mig", "-i", str(idx), "-cgi", tuples, "-C"])
    got = sorted((g.profile, g.start) for g in read_gis(idx))
    if got != sorted(target):
        raise RuntimeError(f"GPU {idx}: created {got}, expected {sorted(target)}")


def ensure_gpus(cfg: Config, only: set[int] | None = None) -> None:
    """MIG mode + layout of every GPU in the config. Raises RebootRequired if a mode change is pending."""
    pending = []
    gpus = {g.index: g for g in read_gpus()}
    for idx, layout in sorted(cfg.gpus.items()):
        if only is not None and idx not in only:
            continue
        g = gpus.get(idx)
        if g is None:
            raise RuntimeError(f"GPU {idx} is not visible to the driver (nvidia-smi): restart the VM from Proxmox")
        if layout is None:
            if g.mig_current:
                run(["nvidia-smi", "mig", "-i", str(idx), "-dci"], check=False)
                run(["nvidia-smi", "mig", "-i", str(idx), "-dgi"], check=False)
                if not set_mig_mode(idx, False):
                    pending.append(idx)
            continue
        if not g.mig_current:
            if not set_mig_mode(idx, True):
                pending.append(idx)
            continue
        target = pack(layout)
        if sorted((gi.profile, gi.start) for gi in g.gis) != sorted(target):
            apply_layout(idx, target)
    if pending:
        raise RebootRequired(f"MIG mode change pending on GPU(s) {', '.join(map(str, pending))}")


# ─── Apply: containers ───────────────────────────────────────────────────────


def gpu_device_args(spec: CtSpec, slot: int | None, gpus: list[Gpu]) -> list[str]:
    g = next(g for g in gpus if g.index == spec.gpu)
    if spec.profile is None:
        return ["gputype=physical", f"pci={g.pci}"]
    gi = next((x for x in g.gis if x.start == slot and x.profile == spec.profile), None)
    if gi is None or not gi.uuid:
        raise RuntimeError(f"{spec.name}: MIG instance {spec.profile}@{slot} not found on GPU {spec.gpu}")
    return ["gputype=mig", f"pci={g.pci}", f"mig.uuid={gi.uuid}"]


def bind_gpu(name: str, spec: CtSpec, slot: int | None, gpus: list[Gpu]) -> None:
    lxc("config", "device", "remove", name, "gpu", check=False)
    lxc("config", "device", "add", name, "gpu", "gpu", *gpu_device_args(spec, slot, gpus))
    lxc("config", "set", name, f"{KEY}gpu={spec.gpu}", f"{KEY}profile={spec.profile or ''}", f"{KEY}slot={'' if slot is None else slot}")


def ct_exec(name: str, script: str, input_text: str | None = None, timeout: int = 1800) -> str:
    return run(["lxc", "exec", name, "--", "sh", "-c", script], input_text=input_text, timeout=timeout)


def wait_ready(name: str) -> None:
    for _ in range(90):
        if ok(["lxc", "exec", name, "--", "sh", "-c", "getent hosts archive.ubuntu.com >/dev/null"]):
            break
        time.sleep(2)
    else:
        raise RuntimeError(
            f"{name}: no network/DNS after 3 minutes (firewall in the VM? check 'ufw status' and "
            f"'iptables -S FORWARD'; the {BRIDGE} bridge needs DHCP, DNS and forwarding)"
        )
    run(["lxc", "exec", name, "--", "cloud-init", "status", "--wait"], check=False, timeout=900)


BASE_SCRIPT = r"""
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q openssh-server sudo ca-certificates curl
mkdir -p /etc/ssh/sshd_config.d /run/sshd
printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > /etc/ssh/sshd_config.d/01-password-auth.conf
sshd -t
systemctl enable --now ssh >/dev/null 2>&1 || true
systemctl restart ssh || systemctl restart sshd || true
"""


def install_software(name: str, items: list[str]) -> None:
    apt = [s[4:] for s in items if s.startswith("apt:")]
    pip = [s[4:] for s in items if s.startswith("pip:")]
    if "python" in items:
        apt += ["python3", "python3-pip", "python3-venv", "python3-dev", "build-essential"]
    if apt:
        ct_exec(name, "DEBIAN_FRONTEND=noninteractive apt-get install -y -q " + " ".join(shlex.quote(a) for a in apt))
    if "uv" in items:
        ct_exec(name, "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh")
    if pip:
        ct_exec(name, "python3 -m pip install --break-system-packages " + " ".join(shlex.quote(p) for p in pip))


def gen_password() -> str:
    alphabet = string.ascii_letters + string.digits
    while True:
        p = "".join(secrets.choice(alphabet) for _ in range(14))
        if any(c.isdigit() for c in p) and any(c.isupper() for c in p) and any(c.islower() for c in p):
            return p


def add_users(name: str, users: list[str]) -> dict[str, str]:
    creds = {}
    for u in users:
        exists = ok(["lxc", "exec", name, "--", "id", u])
        if not exists:
            ct_exec(name, f"useradd -m -s /bin/bash -G sudo {shlex.quote(u)}")
            pw = gen_password()
            run(["lxc", "exec", name, "--", "chpasswd"], input_text=f"{u}:{pw}\n")
            ct_exec(name, f"passwd --expire {shlex.quote(u)} >/dev/null")
            creds[u] = pw
        else:
            ct_exec(name, f"usermod -aG sudo {shlex.quote(u)}")
    return creds


def next_port(cfg: Config, used: set[int]) -> int:
    p = cfg.ssh_port_base
    while p in used:
        p += 1
    used.add(p)
    return p


def vm_ip() -> str:
    out = run(["ip", "-4", "route", "get", "1.1.1.1"], check=False)
    m = re.search(r"src (\S+)", out)
    return m.group(1) if m else "VM-IP"


def apply(cfg: Config, config_path: str, prune: bool) -> int:
    gpus, cts = read_gpus(), read_containers()
    plan = make_plan(cfg, gpus, cts, prune)
    if plan.empty():
        log("No changes.")
        return 0
    creds: list[dict] = []

    log("== Base setup")
    setup_base(cfg, config_path)
    cts = read_containers()

    log("== Stopping containers whose GPU changes")
    for name in sorted(plan.stops):
        log(f"  stop {name}")
        lxc("stop", name, "--timeout", "60", check=False)
        if read_ct(name).status == "Running":
            lxc("stop", name, "--force")
    for name in plan.deletes:
        archive_and_delete(name)

    log("== GPUs")
    if plan.gpu_changes:
        # Unbind every container on a changing GPU first (their MIG UUIDs are about to disappear)
        for c in cts:
            if c.managed and c.gpu in plan.gpu_changes:
                if read_ct(c.name).status == "Running":
                    lxc("stop", c.name, "--force")
                lxc("config", "device", "remove", c.name, "gpu", check=False)
        ensure_gpus(cfg, set(plan.gpu_changes))
        for idx in plan.gpu_changes:
            log(f"  GPU {idx}: {layout_str(cfg.gpus[idx])} OK")
    gpus = read_gpus()
    cts = read_containers()
    assign = assign_slots(cfg, cts, set())
    used_ports = {c.port for c in cts if c.port}
    ip = vm_ip()
    current = {c.name: c for c in cts}

    log("== Containers")
    for spec in cfg.containers:
        cur = current.get(spec.name)
        slot = assign.get(spec.name)
        if cur is not None and cur.managed and not cur.provisioned:
            log(f"  - {spec.name}: half-created last time, deleting it")
            lxc("delete", spec.name, "--force")
            used_ports.discard(cur.port)
            cur = None
        if cur is None:
            log(f"  + {spec.name}: create ({slice_desc(spec, slot)})")
            port = next_port(cfg, used_ports)
            lxc(
                "init", spec.image, spec.name, "-p", "default", "-p", PROFILE,
                "-c", f"limits.cpu={spec.cpu}", "-c", f"limits.memory={lxd_size(spec.memory)}",
                "-c", f"{KEY}managed=true", "-c", f"{KEY}ssh_port={port}",
                "-d", f"root,size={lxd_size(spec.disk)}", timeout=1800,
            )
            lxc("config", "device", "add", spec.name, "ssh", "proxy", f"listen=tcp:0.0.0.0:{port}", "connect=tcp:127.0.0.1:22")
            bind_gpu(spec.name, spec, slot, gpus)
            lxc("start", spec.name)
            wait_ready(spec.name)
            ct_exec(spec.name, BASE_SCRIPT)
            install_software(spec.name, spec.software)
            lxc("config", "set", spec.name, f"{KEY}software={','.join(spec.software)}")
            new = add_users(spec.name, spec.users)
            lxc("config", "set", spec.name, f"{KEY}users={','.join(spec.users)}", f"{KEY}provisioned=true")
            creds += emit_creds(spec.name, new, port, ip)
            continue
        if spec.name in plan.updates:
            log(f"  ~ {spec.name}: {', '.join(plan.updates[spec.name])}")
            lxc("config", "set", spec.name, f"limits.cpu={spec.cpu}", f"limits.memory={lxd_size(spec.memory)}")
            if cur.disk != spec.disk:
                # containers are created with their own root device (-d root,size=...)
                lxc("config", "device", "set", spec.name, "root", f"size={lxd_size(spec.disk)}")
        if spec.name in plan.rebinds or spec.gpu in plan.gpu_changes:
            log(f"  ~ {spec.name}: bind {slice_desc(spec, slot)}")
            if read_ct(spec.name).status == "Running":
                lxc("stop", spec.name, "--force")
            bind_gpu(spec.name, spec, slot, gpus)
        if read_ct(spec.name).status != "Running":
            lxc("start", spec.name)
            wait_ready(spec.name)
        if spec.name in plan.add_software:
            log(f"  + {spec.name}: software {', '.join(plan.add_software[spec.name])}")
            install_software(spec.name, plan.add_software[spec.name])
            lxc("config", "set", spec.name, f"{KEY}software={','.join(sorted(set(cur.software + spec.software)))}")
        if spec.name in plan.add_users:
            log(f"  + {spec.name}: users {', '.join(plan.add_users[spec.name])}")
            new = add_users(spec.name, plan.add_users[spec.name])
            port = cur.port
            creds += emit_creds(spec.name, new, port, ip)
            lxc("config", "set", spec.name, f"{KEY}users={','.join(sorted(set(cur.users + spec.users)))}")

    # Containers kept on a changed GPU but not in the config are left stopped without GPU
    log("== Result")
    print_status(read_gpus(), read_containers(), ip)
    if creds:
        log("")
        log("New users (temporary password, they must change it on first login):")
        print_table([["Container", "User", "Password", "SSH"]] + [[c["container"], c["user"], c["password"], c["ssh"]] for c in creds])
    return 0


def emit_creds(container: str, new: dict[str, str], port: int | None, ip: str) -> list[dict]:
    """Prints the new credentials right away (machine-readable line for the wrapper), so a
    later failure in the same run does not lose them."""
    rows = [{"container": container, "user": u, "password": p, "ssh": f"ssh -p {port} {u}@{ip}"} for u, p in new.items()]
    if rows:
        log("MIGLXD_CREDENTIALS_JSON " + json.dumps(rows))
    return rows


def read_ct(name: str) -> CtState:
    return next(c for c in read_containers() if c.name == name)


def archive_and_delete(name: str) -> None:
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(ARCHIVE_DIR, f"{name}-home-{ts}.tar.gz")
    log(f"  - {name}: archiving /home to {dest}")
    if read_ct(name).status != "Running":
        lxc("start", name, check=False)
    with open(dest, "wb") as f:
        p = subprocess.run(["lxc", "exec", name, "--", "tar", "czf", "-", "-C", "/", "home"], stdout=f, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(f"{name}: could not archive /home ({p.stderr.decode(errors='replace')[-200:]}); not deleted")
    lxc("delete", name, "--force")


def print_status(gpus: list[Gpu], cts: list[CtState], ip: str | None = None) -> None:
    ip = ip or vm_ip()
    log("GPUs:")
    for g in gpus:
        log(f"  GPU {g.index} {g.pci} {g.name}: {'MIG ' + layout_str(g.layout) if g.mig_current else 'whole (MIG off)'}")
    rows = [["Container", "Status", "GPU slice", "CPU", "RAM", "Disk", "SSH", "Users"]]
    for c in sorted(cts, key=lambda c: c.name):
        if not c.managed:
            rows.append([c.name, c.status, "(not managed)", "", "", "", "", ""])
            continue
        sl = f"GPU {c.gpu} " + (f"{c.profile}@{c.slot}" if c.profile else "whole")
        rows.append([
            c.name, c.status, sl, str(c.cpu or "-"), fmt_gb(c.memory) if c.memory else "-",
            fmt_gb(c.disk) if c.disk else "-", f"{ip}:{c.port}" if c.port else "-", ",".join(c.users),
        ])
    log("Containers:")
    if len(rows) == 1:
        log("  (none)")
    else:
        print_table(rows)


# ─── Boot ────────────────────────────────────────────────────────────────────


def boot() -> int:
    cfg = load_config(CONFIG_PATH)
    firewall_rules(cfg)
    try:
        ensure_gpus(cfg)
    except RebootRequired as e:
        log(f"{e}: containers on those GPUs will not get their slice until the next restart")
    gpus = read_gpus()
    cts = read_containers()
    resolve_lab(cfg, cts)
    specs = {c.name: c for c in cfg.containers}
    rc = 0
    for c in cts:
        if not c.managed:
            continue
        spec = specs.get(c.name)
        if spec is None:
            log(f"{c.name}: not in {CONFIG_PATH}, not started")
            continue
        try:
            bind_gpu(c.name, spec, c.slot, gpus)
            if c.status != "Running":
                lxc("start", c.name)
            log(f"{c.name}: started ({slice_desc(spec, c.slot)})")
        except Exception as e:  # keep starting the others
            log(f"{c.name}: ERROR {e}")
            rc = 1
    return rc


# ─── CLI ─────────────────────────────────────────────────────────────────────


def _toml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    raise ConfigError(f"cannot write {type(v).__name__} values: {v!r}")


def dump_toml(d: dict) -> str:
    """Minimal TOML writer for the config subset: scalars, lists, tables, arrays of tables."""
    def key(k) -> str:
        return str(k) if re.match(r"^[A-Za-z0-9_-]+$", str(k)) else json.dumps(str(k))

    lines: list[str] = []
    for k, v in d.items():
        if not isinstance(v, dict) and not (isinstance(v, list) and v and all(isinstance(x, dict) for x in v)):
            lines.append(f"{key(k)} = {_toml_value(v)}")
    for k, v in d.items():
        if isinstance(v, dict):
            lines += ["", f"[{key(k)}]"] + [f"{key(kk)} = {_toml_value(vv)}" for kk, vv in v.items()]
        elif isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            for item in v:
                lines += ["", f"[[{key(k)}]]"] + [f"{key(kk)} = {_toml_value(vv)}" for kk, vv in item.items()]
    return "\n".join(lines) + "\n"


def cmd_expand(path: str) -> int:
    """Prints CONFIG with [lab].users_file read in: the self-contained file sent to the VM."""
    raw = open(path, encoding="utf-8").read()
    try:
        d = tomllib.loads(raw)
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: {e}") from e
    if not (d.get("lab") or {}).get("users_file"):
        sys.stdout.write(raw)
        return 0
    d = expand_lab_users(d, os.path.dirname(os.path.abspath(path)))
    sys.stdout.write(f"# Generated from {os.path.basename(path)} by mig_lxd.py expand ([lab].users_file read in)\n")
    sys.stdout.write(dump_toml(d))
    return 0



def cmd_state(_args) -> int:
    cfg = None
    if os.path.exists(CONFIG_PATH):
        try:
            cfg = load_config(CONFIG_PATH)
        except ConfigError:
            cfg = None
    gpus = read_gpus()
    data = {
        "gpus": [
            {
                "index": g.index, "name": g.name, "pci": g.pci, "mig_capable": g.mig_capable,
                "mig": g.mig_current, "layout": layout_str(g.layout) if g.mig_current else "whole",
                "instances": [{"profile": i.profile, "slot": i.start, "uuid": i.uuid} for i in g.gis],
            }
            for g in gpus
        ],
        "resources": read_resources(cfg),
        "containers": [c.__dict__ for c in read_containers()],
        "layouts": full_layouts(),
        "profiles": {p: {"compute": PROFILES[p][0], "gb": PROFILE_GB[p]} for p in PROFILES},
        "installed_config": cfg.raw if cfg else None,
        "vm_ip": vm_ip(),
    }
    print(json.dumps(data, indent=1))
    return 0


def check(cfg: Config, prune: bool) -> tuple[list[Gpu], list[CtState], Plan | None, int]:
    gpus, cts = read_gpus(), read_containers()
    resolve_lab(cfg, cts)
    errors = validate(cfg, gpus, cts)
    if errors:
        log("Config errors:")
        for e in errors:
            log(f"  x {e}")
        return gpus, cts, None, 3
    rows, rerr, rwarn = resource_check(cfg, cts, read_resources(cfg), prune)
    log("Resources:")
    print_table(rows)
    log("  GPU     MIG slices are exclusive: memory and compute guaranteed per container")
    for w in rwarn:
        log(f"  ! {w}")
    for e in rerr:
        log(f"  x {e}")
    plan = make_plan(cfg, gpus, cts, prune)
    log("")
    print_plan(cfg, plan, gpus, cts)
    return gpus, cts, plan, (3 if rerr else 0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("state")
    sub.add_parser("layouts")
    sub.add_parser("status")
    sub.add_parser("boot")
    sub.add_parser("expand").add_argument("config")
    for n in ("plan", "apply"):
        p = sub.add_parser(n)
        p.add_argument("config")
        p.add_argument("--prune", action="store_true")
    p = sub.add_parser("passwd")
    p.add_argument("container")
    p.add_argument("user")
    a = ap.parse_args()

    if a.cmd == "expand":
        try:
            return cmd_expand(a.config)
        except ConfigError as e:
            log(f"Config error: {e}")
            return 3

    if a.cmd == "layouts":
        print_table([["Layout", "Instances", "Gives", "Idle compute"]] + [
            [x["layout"], str(x["instances"]), x["desc"], f"{x['idle_compute']}/7" if x["idle_compute"] else "-"]
            for x in full_layouts()
        ])
        return 0
    if os.geteuid() != 0:
        log("Run it as root")
        return 1
    try:
        if a.cmd == "state":
            return cmd_state(a)
        if a.cmd == "status":
            print_status(read_gpus(), read_containers())
            return 0
        if a.cmd == "boot":
            return boot()
        if a.cmd == "passwd":
            c = read_ct(a.container)
            pw = gen_password()
            run(["lxc", "exec", a.container, "--", "chpasswd"], input_text=f"{a.user}:{pw}\n")
            ct_exec(a.container, f"passwd --expire {shlex.quote(a.user)} >/dev/null")
            log(f"{a.user}@{a.container}: new temporary password {pw} (ssh -p {c.port} {a.user}@{vm_ip()})")
            log("MIGLXD_CREDENTIALS_JSON " + json.dumps([{"container": a.container, "user": a.user, "password": pw, "ssh": f"ssh -p {c.port} {a.user}@{vm_ip()}"}]))
            return 0
        cfg = load_config(a.config)
        _, _, plan, rc = check(cfg, a.prune)
        if rc or a.cmd == "plan":
            return rc
        log("")
        return apply(cfg, a.config, a.prune)
    except RebootRequired as e:
        log(f"REBOOT REQUIRED: {e}. Restart the VM from Proxmox and run apply again.")
        log("MIGLXD_REBOOT_REQUIRED")
        return 4
    except ConfigError as e:
        log(f"Config error: {e}")
        return 3
    except (RuntimeError, subprocess.TimeoutExpired) as e:
        log(f"ERROR: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
