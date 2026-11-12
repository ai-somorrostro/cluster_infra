#!/usr/bin/env python3
"""Renders the cluster inventory collected by vm_inventory.sh as Markdown.

Usage: vm_inventory.py WORK_DIR CLUSTER_NAME [OUT_FILE]

WORK_DIR holds the raw API answers (resources.json, nodes.json, node/, pci/, storage/,
cfg/, ip/, guest/). Without OUT_FILE the block is printed. With OUT_FILE only the part
between the markers is replaced; a new file gets a skeleton.

The rendered text is in Spanish because it goes to the team's (Spanish) Obsidian vault.
"""
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

START, END = "<!-- inventory:start -->", "<!-- inventory:end -->"
SECRET = re.compile(r"(?i)(pass(word|wd)?|pwd|token|secret|api[-_ ]?key|clave|contrase(ñ|n)a)\s*[:=]")
VIRTUAL_IF = re.compile(r"^(lo|docker\d*|br-|veth|lxdbr|virbr|cni|flannel|cali|vxlan|tun|wg)")
DISK_KEY = re.compile(r"^(scsi|virtio|sata|ide)\d+$")

SKELETON = f"""# Inventario

Qué hay en cada máquina del cluster. La parte entre las marcas la genera `vm/vm_inventory.sh` \
del [[Repositorio cluster_infra]] y **se reescribe entera cada vez**. Para apuntar qué corre en \
una VM o LXC, escríbelo en sus **Notes** de Proxmox (*Summary → Notes*) y vuelve a lanzar el \
script: aparece en «Qué hay dentro». Las líneas con contraseñas o tokens no se copian.

{START}
{END}

## Notas a mano

"""


def load(path: Path):
    try:
        return json.loads(path.read_text() or "null")
    except (OSError, ValueError):
        return None


def gib(b) -> str:
    if b is None or b == "":
        return "-"
    b = float(b)
    if b >= 1024**4:
        return f"{b / 1024**4:.1f} TB"
    return f"{b / 1024**3:.0f} GB" if b >= 10 * 1024**3 else f"{b / 1024**3:.1f} GB"


def lxd_size(v: str) -> str:
    """LXD sizes ('9216MiB', '50GB', '16GiB') as GB."""
    m = re.fullmatch(r"([0-9.]+)\s*([KMGT]?)(i?B)?", v or "")
    if not m:
        return v or ""
    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(2)]
    if m.group(3) == "B":  # decimal units
        mult = {"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[m.group(2)]
    return gib(float(m.group(1)) * mult)


def docker_name(n: str) -> str:
    """Swarm task names ('core_grafana.1.<id>', 'core_agent.<node id>.<id>') -> service name."""
    return re.sub(r"\.([0-9]+|[a-z0-9]{25})\.[a-z0-9]{25}$", "", n)


def cell(s) -> str:
    return str(s).replace("|", "\\|").replace("\n", " ") if s not in (None, "") else "-"


def table(head: list[str], rows: list[list]) -> list[str]:
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(cell(c) for c in r) + " |" for r in rows]
    return out


def redact(text: str) -> list[str]:
    lines, hidden = [], 0
    for ln in (text or "").strip().splitlines():
        if SECRET.search(ln):
            hidden += 1
        else:
            lines.append(ln)
    if hidden:
        lines.append(f"*({hidden} línea(s) con credenciales sin copiar: están en las Notes de Proxmox)*")
    return lines


def pci_names(pci) -> dict[str, str]:
    """'0000:c1:00' -> 'RTX A6000' (text in brackets of the device name when there is one)."""
    names = {}
    for p in pci or []:
        name = p.get("device_name") or p.get("device", "")
        m = re.search(r"\[([^\]]+)\]", name)
        names.setdefault(p["id"].rsplit(".", 1)[0], m.group(1) if m else name)
    return names


def gpus(cfg: dict, names: dict[str, str]) -> str:
    out = []
    for k in sorted(k for k in cfg if re.fullmatch(r"hostpci\d+", k)):
        dev = cfg[k].split(",")[0]
        if dev.startswith("mapping="):
            out.append(dev.split("=", 1)[1])
            continue
        dev = dev if dev.count(":") == 2 else "0000:" + dev
        short = dev.split(":", 1)[1]
        out.append(f"{names.get(dev.split('.')[0], 'PCI')} ({short})")
    return ", ".join(out)


def disks(cfg: dict, kind: str) -> str:
    out = []
    for k, v in cfg.items():
        is_disk = (kind == "qemu" and DISK_KEY.match(k)) or (kind == "lxc" and (k == "rootfs" or re.fullmatch(r"mp\d+", k)))
        if not is_disk or "media=cdrom" in v or "cloudinit" in v:
            continue
        if v.startswith("/"):  # bind mount of a host path
            out.append(f"bind {v.split(',')[0]}")
            continue
        storage = v.split(":", 1)[0]
        size = re.search(r"size=([0-9.]+[KMGT]?)", v)
        out.append(f"{storage} {size.group(1) if size else '?'}")
    return ", ".join(sorted(out))


def ips(raw, kind: str) -> str:
    found = []
    if kind == "qemu" and isinstance(raw, dict):
        for i in raw.get("result", []):
            if VIRTUAL_IF.match(i.get("name", "")):
                continue
            found += [a["ip-address"] for a in i.get("ip-addresses", [])
                      if a.get("ip-address-type") == "ipv4" and not a["ip-address"].startswith("127.")]
    elif kind == "lxc" and isinstance(raw, list):
        for i in raw:
            if VIRTUAL_IF.match(i.get("name", "")):
                continue
            for a in (i.get("inet"), *(x.get("ip-address") for x in i.get("ip-addresses", []) if x.get("ip-address-type") == "inet")):
                if a and not a.startswith("127."):
                    found.append(a.split("/")[0])
    return ", ".join(dict.fromkeys(found))


def vcpu(cfg: dict, kind: str) -> str:
    if kind == "qemu":
        return str(int(cfg.get("cores", 1)) * int(cfg.get("sockets", 1)))
    return str(cfg.get("cores", "todas"))


def guest_data(path: Path):
    lxd, docker = [], []
    if path.exists():
        for ln in path.read_text().splitlines():
            kind, _, payload = ln.partition(" ")
            try:
                obj = json.loads(payload)
            except ValueError:
                continue
            (lxd if kind == "LXD" else docker if kind == "DOCKER" else []).append(obj)
    return lxd, docker


def render(work: Path, cluster: str) -> str:
    res = [r for r in load(work / "resources.json") or [] if r.get("type") in ("qemu", "lxc")]
    nodes = sorted(n["node"] for n in load(work / "nodes.json") or [] if n.get("status") == "online")
    cfgs = {r["vmid"]: load(work / "cfg" / f"{r['vmid']}.json") or {} for r in res}
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M")

    out = [f"> [!info] Generado por `vm/vm_inventory.sh` el **{now}** (cluster `{cluster}`). "
           "No edites entre las marcas: se reescribe.", "", "## Nodos", ""]
    rows = []
    for n in nodes:
        st = load(work / "node" / f"{n}.json") or {}
        mem = st.get("memory", {})
        running = [r for r in res if r["node"] == n and r.get("status") == "running"]
        rows.append([f"`{n}`", f"{st.get('cpuinfo', {}).get('cpus', '?')} hilos, {100 * st.get('cpu', 0):.0f}% en uso",
                     f"{gib(mem.get('used'))} / {gib(mem.get('total'))}",
                     gib(sum(r.get("maxmem", 0) for r in running)), len(running)])
    out += table(["Nodo", "CPU", "RAM usada / total", "RAM asignada a lo encendido", "Encendidas"], rows)

    out += ["", "## Almacenamiento", ""]
    rows, seen = [], set()
    for n in nodes:
        for s in load(work / "storage" / f"{n}.json") or []:
            if not s.get("active") or not s.get("total"):
                continue
            key = s["storage"] if s.get("shared") else f"{s['storage']}@{n}"
            if key in seen:
                continue
            seen.add(key)
            rows.append([f"`{s['storage']}`", "compartido" if s.get("shared") else n, s.get("type", ""),
                         f"{gib(s.get('used'))} / {gib(s['total'])}", f"{100 * s.get('used', 0) / s['total']:.0f}%"])
    out += table(["Storage", "Nodo", "Tipo", "Usado / total", "Uso"], rows)

    inside = []
    for n in nodes:
        names = pci_names(load(work / "pci" / f"{n}.json"))
        guests = sorted((r for r in res if r["node"] == n and not r.get("template")), key=lambda r: r["vmid"])
        out += ["", f"## {n}", ""]
        rows = []
        for r in guests:
            c, kind = cfgs[r["vmid"]], r["type"]
            name = c.get("name") or c.get("hostname") or r.get("name", "")
            rows.append([r["vmid"], f"**{name}**", "VM" if kind == "qemu" else "LXC",
                         "encendida" if r.get("status") == "running" else "apagada",
                         vcpu(c, kind), gib(int(c.get("memory", 0)) * 1024**2), disks(c, kind),
                         gpus(c, names), ips(load(work / "ip" / f"{r['vmid']}.json"), kind),
                         c.get("tags", "").replace(";", ", ")])
            desc = redact(c.get("description", ""))
            lxd, docker = guest_data(work / "guest" / f"{r['vmid']}.txt")
            if desc or lxd or docker:
                inside.append((r["vmid"], name, n, desc, lxd, docker))
        out += table(["ID", "Nombre", "Tipo", "Estado", "vCPU", "RAM", "Discos", "GPU", "IP", "Tags"], rows) if rows else ["*(nada)*"]

    out += ["", "## Qué hay dentro", ""]
    if not inside:
        out.append("*(ninguna VM o LXC tiene Notes, LXD ni Docker)*")
    for vmid, name, node, desc, lxd, docker in inside:
        out += [f"### {vmid} {name} ({node})", ""]
        if desc:
            out += desc + [""]
        if lxd:
            out += [f"**Contenedores LXD** ({len(lxd)}):", ""]
            out += table(["Contenedor", "Estado", "IP", "vCPU", "RAM", "Disco", "GPU", "Puertos", "Usuarios", "Descripción"],
                         [[f"`{x['name']}`", x["status"], ", ".join(x["ip"]), x["cpu"], lxd_size(x["memory"]), lxd_size(x["disk"]),
                           ", ".join(x["gpu"]), ", ".join(x["ports"]), ", ".join(x["users"]), x["description"]]
                          for x in sorted(lxd, key=lambda x: x["name"])]) + [""]
        if docker:
            up = [x for x in docker if x.get("State") == "running"]
            stopped = len(docker) - len(up)
            out += [f"**Docker**: {len(up)} en marcha" + (f", {stopped} parados (no se listan)" if stopped else "") + ":", ""]
            if up:
                out += table(["Contenedor", "Imagen", "Desde", "Puertos"],
                             [[f"`{docker_name(x.get('Names', ''))}`", x.get("Image", ""), x.get("RunningFor", ""), x.get("Ports", "")]
                              for x in sorted(up, key=lambda x: x.get("Names", ""))]) + [""]

    tmpl = sorted((r for r in res if r.get("template")), key=lambda r: r["vmid"])
    out += ["", "## Plantillas", ""]
    out += table(["ID", "Nombre", "Tipo", "Nodo", "Discos"],
                 [[r["vmid"], cfgs[r["vmid"]].get("name") or cfgs[r["vmid"]].get("hostname") or r.get("name", ""),
                   "VM" if r["type"] == "qemu" else "LXC", r["node"], disks(cfgs[r["vmid"]], r["type"])] for r in tmpl])
    return "\n".join(out).rstrip() + "\n"


def write(out_file: Path, block: str) -> None:
    text = out_file.read_text(encoding="utf-8") if out_file.exists() else SKELETON
    if START not in text or END not in text or text.index(START) > text.index(END):
        sys.exit(f"{out_file} exists but has no '{START}' ... '{END}' markers: not touching it")
    head, rest = text.split(START, 1)
    tail = rest.split(END, 1)[1]
    tmp = out_file.with_name(out_file.name + ".tmp")
    tmp.write_text(f"{head}{START}\n{block}{END}{tail}", encoding="utf-8")
    os.replace(tmp, out_file)


def main() -> None:
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    block = render(Path(sys.argv[1]), sys.argv[2])
    if len(sys.argv) == 4 and sys.argv[3]:
        write(Path(sys.argv[3]), block)
    else:
        sys.stdout.write(block)


if __name__ == "__main__":
    main()
