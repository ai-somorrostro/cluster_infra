#!/usr/bin/env python3
"""mig_wizard.py - interactive (whiptail) editor of a MIG + LXD config.

Called by vm/vm_mig_lxd.sh configure with the VM state (JSON from mig_lxd.py state).
Asks which GPUs to carve and how, which containers exist, the slice, limits and users
of each one, and writes the TOML. It never lets RAM or disk go over what the VM has.

  mig_wizard.py --state state.json --vm 106 [--vm-name GPU2] config/mig/gpu2.toml
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib

GIB = 1024**3
TITLE = "MIG + LXD configurator"
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,61}[a-z0-9]$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,30}$")


class Cancel(Exception):
    pass


# ─── whiptail ────────────────────────────────────────────────────────────────


def wt(*args: str, height: int = 20, width: int = 78, list_height: int | None = None) -> str:
    cmd = ["whiptail", "--title", TITLE, *args]
    # whiptail: --menu text h w list_h items...  /  --inputbox text h w init
    p = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise Cancel()
    return p.stderr.strip()


def menu(text: str, items: list[tuple[str, str]], default: str | None = None) -> str:
    args = ["--menu", text, "22", "86", str(min(len(items), 12))]
    if default:
        args = ["--default-item", default] + args
    for tag, desc in items:
        args += [tag, desc]
    return wt(*args)


def checklist(text: str, items: list[tuple[str, str, bool]]) -> list[str]:
    args = ["--checklist", text, "20", "86", str(min(len(items), 10))]
    for tag, desc, on in items:
        args += [tag, desc, "ON" if on else "OFF"]
    out = wt(*args)
    return [x.strip('"') for x in out.split()] if out else []


def inputbox(text: str, init: str = "") -> str:
    return wt("--inputbox", text, "12", "78", init)


def msg(text: str) -> None:
    subprocess.run(["whiptail", "--title", TITLE, "--msgbox", text, "20", "86"])


def yesno(text: str) -> bool:
    return subprocess.run(["whiptail", "--title", TITLE, "--yesno", text, "12", "78"]).returncode == 0


# ─── Sizes and layouts ───────────────────────────────────────────────────────


def parse_size(v) -> int:
    if isinstance(v, int):
        return v * GIB
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([KMGT])i?B?\s*", str(v), re.I)
    if not m:
        raise ValueError(f"invalid size '{v}' (use e.g. 32GB)")
    return int(float(m.group(1)) * 1024 ** "KMGT".index(m.group(2).upper()) * 1024)


def gb(b: float) -> str:
    return f"{b / GIB:.0f}GB"


def layout_profiles(text: str) -> list[str] | None:
    text = text.strip().lower()
    if text == "whole":
        return None
    out = []
    for part in filter(None, (p.strip() for p in text.split(","))):
        m = re.fullmatch(r"(?:(\d+)x)?(\S+)", part)
        out += [m.group(2)] * int(m.group(1) or 1)
    return out


# ─── Model ───────────────────────────────────────────────────────────────────


class Model:
    def __init__(self, state: dict, cfg: dict, vm: int):
        self.state = state
        self.vm = vm
        self.res = state["resources"]
        self.gpus: dict[int, str] = {int(k): str(v) for k, v in cfg.get("gpus", {}).items()}
        self.defaults = {"cpu": 4, "memory": "8GB", "disk": "50GB", "image": "ubuntu:24.04",
                         "software": ["python", "uv"], **cfg.get("defaults", {})}
        self.containers: list[dict] = [dict(c) for c in cfg.get("containers", [])]
        self.extra = {k: v for k, v in cfg.items() if k not in ("gpus", "defaults", "containers", "vm")}
        self.extra.setdefault("storage_device", self.res.get("storage_device"))

    # what each container asks for
    def ct(self, c: dict, key: str):
        return c.get(key, self.defaults[key])

    def budget(self, skip: str | None = None) -> dict:
        r = self.res
        reserve = parse_size(self.extra["memory_reserve"]) if self.extra.get("memory_reserve") else max(8 * GIB, r["memory_total"] // 10)
        mem_avail = r["memory_total"] - reserve
        disk_total = r["pool_total"] if r["pool_exists"] else (r["storage_device_size"] or 0)
        disk_avail = int(disk_total * 0.95)
        names = {c["name"] for c in self.containers}
        others = [c for c in self.state["containers"] if c["name"] not in names]
        mem_used = sum(parse_size(self.ct(c, "memory")) for c in self.containers if c["name"] != skip)
        mem_used += sum(c.get("memory") or 0 for c in others)
        disk_used = sum(parse_size(self.ct(c, "disk")) + 2 * GIB for c in self.containers if c["name"] != skip)
        disk_used += sum((c.get("disk") or 0) + 2 * GIB for c in others)
        cpu_used = sum(int(self.ct(c, "cpu")) for c in self.containers if c["name"] != skip)
        cpu_used += sum(c.get("cpu") or 0 for c in others)
        return {
            "mem_free": mem_avail - mem_used, "mem_avail": mem_avail,
            "disk_free": disk_avail - disk_used, "disk_avail": disk_avail,
            "cpu_free": r["cpus"] - cpu_used, "cpus": r["cpus"],
        }

    def budget_line(self, skip: str | None = None) -> str:
        b = self.budget(skip)
        return (f"Free: RAM {gb(b['mem_free'])} of {gb(b['mem_avail'])} | disk {gb(b['disk_free'])} "
                f"of {gb(b['disk_avail'])} | CPU {b['cpu_free']} of {b['cpus']}")

    def free_slices(self, skip: str | None = None) -> list[tuple[int, str | None, int]]:
        """(gpu, profile or None for whole, free count)."""
        out = []
        for idx, lay in sorted(self.gpus.items()):
            profs = layout_profiles(lay)
            taken = [c for c in self.containers if int(c["gpu"]) == idx and c["name"] != skip]
            if profs is None:
                out.append((idx, None, 0 if taken else 1))
                continue
            for p in sorted(set(profs), key=lambda p: (-profs.count(p), p)):
                used = sum(1 for c in taken if c.get("profile") == p)
                out.append((idx, p, profs.count(p) - used))
        return out

    def drop_invalid(self) -> list[str]:
        """Removes containers whose slice no longer exists after a layout change."""
        dropped = []
        for c in list(self.containers):
            lay = self.gpus.get(int(c["gpu"]))
            profs = layout_profiles(lay) if lay else "missing"
            if profs == "missing" or (profs is None and c.get("profile")) or (profs is not None and c.get("profile") not in profs):
                self.containers.remove(c)
                dropped.append(c["name"])
        # over-subscribed slices
        for idx, prof, free in self.free_slices():
            while free < 0:
                victim = [c for c in self.containers if int(c["gpu"]) == idx and c.get("profile") == prof][-1]
                self.containers.remove(victim)
                dropped.append(victim["name"])
                free += 1
        return dropped

    def to_toml(self) -> str:
        q = json.dumps
        lines = [
            "# Generated by vm/vm_mig_lxd.sh configure (you can edit it by hand). GB means GiB.",
            f"vm = {self.vm}",
        ]
        for k, v in self.extra.items():
            if v is None:
                continue
            lines.append(f"{k} = {q(v) if isinstance(v, str) else v}")
        lines += ["", "[gpus]"]
        for idx, lay in sorted(self.gpus.items()):
            lines.append(f"{idx} = {q(lay)}")
        lines += ["", "[defaults]"]
        for k in ("cpu", "memory", "disk", "image", "software"):
            v = self.defaults[k]
            lines.append(f"{k} = {q(v) if not isinstance(v, int) else v}")
        for c in self.containers:
            lines += ["", "[[containers]]"]
            for k in ("name", "gpu", "profile", "cpu", "memory", "disk", "image", "software", "users"):
                if k in c and c[k] not in (None, ""):
                    v = c[k]
                    lines.append(f"{k} = {v if isinstance(v, int) else q(v)}")
        return "\n".join(lines) + "\n"


# ─── Screens ─────────────────────────────────────────────────────────────────


def screen_gpus(m: Model) -> None:
    items = []
    for g in m.state["gpus"]:
        cur = f"now: {g['layout']}" if g["mig_capable"] else "no MIG support"
        items.append((str(g["index"]), f"{g['name']} {g['pci']} ({cur})", g["index"] in m.gpus))
    chosen = checklist("GPUs managed by this config (SPACE to select).\n"
                       "Unselected GPUs are left as they are.", items)
    new = {}
    layouts = m.state["layouts"]
    for idx in map(int, chosen):
        g = next(x for x in m.state["gpus"] if x["index"] == idx)
        opts = [("whole", "No MIG: one container gets the whole GPU (40GB, 7/7)")]
        if g["mig_capable"]:
            for lay in layouts:
                idle = f"  [idle compute {lay['idle_compute']}/7]" if lay["idle_compute"] else ""
                opts.append((lay["layout"], f"{lay['desc']}{idle}"))
        cur = m.gpus.get(idx, g["layout"])
        new[idx] = menu(f"GPU {idx} ({g['name']}): how is it carved?\n"
                        "Every MIG layout fills the GPU completely. Ng = N/7 of the compute.",
                        opts, default=cur if any(o[0] == cur for o in opts) else None)
    m.gpus = new
    dropped = m.drop_invalid()
    if dropped:
        msg("These containers no longer fit the new layout and were removed from the config:\n\n  "
            + "\n  ".join(dropped) + "\n\nAdd them again with another slice if needed.")


def screen_defaults(m: Model) -> None:
    while True:
        cpu = inputbox("Default vCPUs per container:", str(m.defaults["cpu"]))
        mem = inputbox("Default RAM per container (e.g. 8GB):", str(m.defaults["memory"]))
        disk = inputbox("Default disk per container (e.g. 50GB):", str(m.defaults["disk"]))
        sw = inputbox("Default software (python, uv, apt:PKG, pip:PKG), space separated:",
                      " ".join(m.defaults["software"]))
        try:
            m.defaults.update(cpu=int(cpu), memory=f"{parse_size(mem) // GIB}GB", disk=f"{parse_size(disk) // GIB}GB",
                              software=sw.split())
            return
        except ValueError as e:
            msg(f"Invalid value: {e}")


def ask_container(m: Model, c: dict | None) -> dict | None:
    c = dict(c or {})
    skip = c.get("name")
    while True:
        name = inputbox("Container name (a-z, 0-9, '-'):", c.get("name", ""))
        if not NAME_RE.match(name):
            msg("Invalid name: lowercase letters, digits and '-', 2-63 chars, starting with a letter.")
            continue
        if any(x["name"] == name for x in m.containers if x["name"] != skip):
            msg(f"'{name}' already exists in the config.")
            continue
        break
    slices = [s for s in m.free_slices(skip) if s[2] > 0]
    if not slices:
        msg("There are no free GPU slices. Change a GPU layout or remove a container.")
        return None
    items = []
    for idx, prof, free in slices:
        if prof is None:
            items.append((f"{idx}:whole", f"GPU {idx} whole (40GB, 7/7 compute)"))
        else:
            gbs = m.state["profiles"][prof]["gb"]
            comp = m.state["profiles"][prof]["compute"]
            items.append((f"{idx}:{prof}", f"GPU {idx} {prof}: {gbs}GB, {comp}/7 compute ({free} free)"))
    cur = f"{c['gpu']}:{c.get('profile') or 'whole'}" if "gpu" in c else None
    pick = menu(f"GPU slice for '{name}':", items, default=cur if any(i[0] == cur for i in items) else None)
    gidx, prof = pick.split(":")
    while True:
        b = m.budget(skip)
        cpu = inputbox(f"vCPUs for '{name}' (free: {b['cpu_free']} of {b['cpus']}):", str(c.get("cpu", m.defaults["cpu"])))
        mem = inputbox(f"RAM for '{name}' (free: {gb(b['mem_free'])}):", str(c.get("memory", m.defaults["memory"])))
        disk = inputbox(f"Disk for '{name}' (free: {gb(b['disk_free'])}):", str(c.get("disk", m.defaults["disk"])))
        try:
            cpu_i, mem_b, disk_b = int(cpu), parse_size(mem), parse_size(disk)
        except ValueError as e:
            msg(f"Invalid value: {e}")
            continue
        errs = []
        if mem_b > b["mem_free"]:
            errs.append(f"RAM: {gb(mem_b)} asked, {gb(b['mem_free'])} free in the VM")
        if disk_b + 2 * GIB > b["disk_free"]:
            errs.append(f"Disk: {gb(disk_b)} (+2GB base) asked, {gb(b['disk_free'])} free in the pool")
        if errs:
            msg("Not enough resources in the VM:\n\n  " + "\n  ".join(errs) + "\n\nLower the values or give the VM more RAM/disk in Proxmox.")
            continue
        if cpu_i > b["cpu_free"] and not yesno(f"{cpu_i} vCPUs leaves the VM over-committed ({b['cpu_free']} free).\n"
                                               "Containers will share CPU (slower, no crash). Continue?"):
            continue
        break
    while True:
        users = inputbox(f"Users of '{name}' (space separated):", " ".join(c.get("users", []))).split()
        bad = [u for u in users if not USER_RE.match(u) or u in ("root", "ubuntu")]
        if not users or bad or len(set(users)) != len(users):
            msg("Give at least one user; names a-z, 0-9, '_', '-', not root/ubuntu, no repeats." + (f"\nInvalid: {' '.join(bad)}" if bad else ""))
            continue
        break
    out = {"name": name, "gpu": int(gidx)}
    if prof != "whole":
        out["profile"] = prof
    for k, v, d in (("cpu", cpu_i, m.defaults["cpu"]), ("memory", f"{mem_b // GIB}GB", m.defaults["memory"]),
                    ("disk", f"{disk_b // GIB}GB", m.defaults["disk"])):
        if str(v) != str(d):
            out[k] = v
    for k in ("image", "software"):
        if k in c:
            out[k] = c[k]
    out["users"] = users
    return out


def screen_containers(m: Model) -> None:
    while True:
        items = [("add", "Add a container")]
        for c in m.containers:
            sl = f"GPU {c['gpu']} {c.get('profile') or 'whole'}"
            items.append((c["name"], f"{sl:<20} {m.ct(c, 'cpu')} CPU {m.ct(c, 'memory')} {m.ct(c, 'disk')}  {', '.join(c.get('users', []))}"))
        items.append(("done", "Save the config"))
        free = ", ".join(f"GPU{i} {p or 'whole'} x{n}" for i, p, n in m.free_slices() if n > 0) or "none"
        pick = menu(f"{m.budget_line()}\nFree slices: {free}", items, default="done" if m.containers else "add")
        if pick == "done":
            return
        if pick == "add":
            c = ask_container(m, None)
            if c:
                m.containers.append(c)
            continue
        c = next(x for x in m.containers if x["name"] == pick)
        act = menu(f"Container '{pick}'", [("edit", "Edit"), ("delete", "Remove from the config"), ("back", "Back")])
        if act == "edit":
            new = ask_container(m, c)
            if new:
                m.containers[m.containers.index(c)] = new
        elif act == "delete" and yesno(f"Remove '{pick}' from the config?\n\nThe container is only deleted in the VM "
                                       "with 'apply --prune' (its /home is archived first)."):
            m.containers.remove(c)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--vm", type=int, required=True)
    ap.add_argument("--vm-name", default="")
    ap.add_argument("config")
    a = ap.parse_args()
    if not sys.stdin.isatty():
        print("The wizard needs an interactive terminal", file=sys.stderr)
        return 1
    state = json.load(open(a.state))
    cfg = {}
    if os.path.exists(a.config):
        cfg = tomllib.load(open(a.config, "rb"))
    elif state.get("installed_config"):
        if yesno(f"{a.config} does not exist, but VM {a.vm} has a config installed.\nStart from it?"):
            cfg = tomllib.loads(state["installed_config"])
    m = Model(state, cfg, a.vm)
    try:
        msg(f"VM {a.vm} {a.vm_name}\n\n"
            f"RAM {gb(m.res['memory_total'])} | {m.res['cpus']} vCPUs | LXD disk "
            f"{gb(m.res['pool_total'] if m.res['pool_exists'] else (m.res['storage_device_size'] or 0))}\n"
            f"GPUs: {len(state['gpus'])} ({', '.join(g['name'] for g in state['gpus'])})\n\n"
            "Steps: 1) GPUs and their MIG layout  2) container defaults  3) containers and users.\n"
            "Nothing changes in the VM until you run 'apply'.")
        screen_gpus(m)
        if not m.gpus:
            msg("No GPU selected: nothing to configure.")
            return 1
        screen_defaults(m)
        screen_containers(m)
    except Cancel:
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(a.config)), exist_ok=True)
    with open(a.config, "w") as f:
        f.write(m.to_toml())
    os.chmod(a.config, 0o600)
    return 0


if __name__ == "__main__":
    sys.exit(main())
