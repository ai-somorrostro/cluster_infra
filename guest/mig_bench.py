#!/usr/bin/env python3
"""mig_bench.py — runs one workload in many MIG + LXD containers at once and measures it.

Runs inside the GPU VM as root (vm/vm_mig_bench.sh uploads it); 'check' and 'report'
also run locally. Stdlib only.

The workload (for example a course repo with Jupyter notebooks) is prepared ONCE in the
VM under /opt/mig-bench/<name>: git checkout, extra files uploaded from the local machine,
setup commands (uv sync...) and an optional warm-up run on a free MIG slice that downloads
every model and leaves a full cache behind. That directory is mounted read-only in the
containers, so 20 containers do not install 20 environments. Each run copies the tree to
/root/mig-bench/<name>/work in every container (never into the users' /home), starts the
items in all containers at the same moment and samples, every few seconds:

  - VRAM used by each MIG slice (nvidia-smi -q -x)
  - temperature, power, SM clock and throttle reasons of each GPU
  - RAM of each container (cgroup memory.current) and its OOM kills
  - CPU, load and free RAM of the VM

Results: /var/lib/mig-bench/<name>/results/<time>-<scenario>.json, plus a report.

Commands:
  check CONFIG                     validate the config (no root needed)
  prepare CONFIG                   checkout + setup + warm-up (idempotent)
  run CONFIG --scenario S [--containers a,b|all] [--gpu N] [--count N] [--interval SEC]
  clean CONFIG                     remove mounts, work dirs and /opt/mig-bench/<name>
  report RESULT.json [...]         print a report (the 1-container run is the baseline)

Exit codes: 0 ok, 1 error, 2 usage, 3 invalid config.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import threading
import time
import tomllib
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

KEY = "user.miglxd."  # LXD config keys owned by mig_lxd.py (containers it manages)
BASE = Path("/opt/mig-bench")
STATE_BASE = Path("/var/lib/mig-bench")
UV_CACHE = Path("/var/cache/mig-bench/uv")
GIB = 1024**3
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
# nvidia-smi clocks_event_reasons bits; 0x1 (idle) and 0x2 (application clocks) are normal
THROTTLE_BITS = {
    0x4: "sw_power_cap",
    0x8: "hw_slowdown",
    0x20: "sync_boost",
    0x40: "sw_thermal",
    0x80: "hw_thermal",
    0x100: "hw_power_brake",
}

# Runs inside the container (system python3): errors and slowest cell of an executed notebook
NB_PARSE = r"""
import datetime, json, sys
def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
try:
    nb = json.load(open(sys.argv[1]))
except Exception as e:
    print(json.dumps({"missing": str(e)[:200]})); sys.exit(0)
errs, slow, n = [], (0.0, None), 0
for c in nb.get("cells", []):
    if c.get("cell_type") != "code":
        continue
    n += 1
    for o in c.get("outputs", []):
        if o.get("output_type") == "error":
            ev = (o.get("evalue") or "").strip().splitlines()
            errs.append({"cell": n, "ename": o.get("ename", ""), "evalue": ev[0][:300] if ev else ""})
    ex = c.get("metadata", {}).get("execution", {})
    a, b = ex.get("iopub.execute_input"), ex.get("shell.execute_reply")
    if a and b:
        d = (ts(b) - ts(a)).total_seconds()
        if d > slow[0]:
            slow = (d, n)
print(json.dumps({"cells": n, "errors": errs, "slowest_cell": slow[1], "slowest_s": round(slow[0], 1)}))
"""


class ConfigError(Exception):
    pass


def log(msg: str = "") -> None:
    print(msg, flush=True)


def now() -> str:
    return time.strftime("%H:%M:%S")


def run(cmd: list[str], check: bool = True, timeout: int = 900, **kw) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    if check and p.returncode != 0:
        raise RuntimeError(f"{shlex.join(cmd)} -> rc {p.returncode}: {(p.stderr or p.stdout).strip()[-800:]}")
    return p.stdout


def fmt_s(s: float | None) -> str:
    if s is None:
        return "-"
    s = int(round(s))
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s" if s >= 60 else f"{s}s"


def fmt_gib(b: float | None) -> str:
    return "-" if b is None else f"{b / GIB:.2f}"


# ─── Config ──────────────────────────────────────────────────────────────────


@dataclass
class Scenario:
    name: str
    source: str  # "source" (git tree + uploaded files) or "warmup" (tree after the warm-up run)
    description: str = ""
    env: dict[str, str] = field(default_factory=dict)  # added to [env] for this scenario


@dataclass
class Bench:
    vm: int | None
    name: str
    git: str
    ref: str
    files: list[str]
    setup: list[str]
    warmup: bool
    env: dict[str, str]
    offline_env: dict[str, str]
    items: list[str]
    command: str
    output: str
    timeout: int
    container_setup: list[str]
    errors: list[tuple[str, re.Pattern]]
    metric: str = ""  # regex with one number group, read from the last output line of each item
    scenarios: dict[str, Scenario] = field(default_factory=dict)

    @property
    def shared(self) -> Path:
        return BASE / self.name

    @property
    def src(self) -> Path:
        return self.shared / "src"

    @property
    def warm(self) -> Path:
        return self.shared / "warm"

    @property
    def state(self) -> Path:
        return STATE_BASE / self.name

    @property
    def work(self) -> str:
        return f"/root/mig-bench/{self.name}/work"

    @property
    def device(self) -> str:
        return f"bench-{self.name}"


def _strs(v, what: str) -> list[str]:
    if v is None:
        return []
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise ConfigError(f"{what} must be a list of strings")
    return v


def _env(v, what: str) -> dict[str, str]:
    if v is None:
        return {}
    if not isinstance(v, dict):
        raise ConfigError(f"{what} must be a table KEY = \"value\"")
    out = {}
    for k, x in v.items():
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
            raise ConfigError(f"{what}: invalid variable name '{k}'")
        out[k] = str(x)
    return out


def load_config(path: str) -> Bench:
    try:
        with open(path, "rb") as f:
            d = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise ConfigError(f"{path}: {e}") from e
    name = d.get("name", "")
    if not NAME_RE.fullmatch(str(name)):
        raise ConfigError("name: required, lowercase letters, digits and '-' (max 31)")
    src = d.get("source") or {}
    if src.get("git") and not src.get("ref"):
        raise ConfigError("[source]: 'ref' (commit, tag or branch) is required with 'git'")
    files = src.get("files") or {}
    if not src.get("git") and not files:
        raise ConfigError("[source]: give 'git' + 'ref', [source.files], or both")
    if not isinstance(files, dict):
        raise ConfigError("[source.files] must be a table \"dest/in/tree\" = \"local path\"")
    for dest in files:
        p = Path(dest)
        if p.is_absolute() or ".." in p.parts or not dest:
            raise ConfigError(f"[source.files]: '{dest}' must be a relative path inside the tree")
        if p.name == ".env" or p.name.startswith(".env."):
            raise ConfigError(f"[source.files]: refusing to upload '{dest}' (secrets stay on your machine)")
    setup = d.get("setup") or {}
    r = d.get("run") or {}
    items = _strs(r.get("items"), "[run].items")
    if not items:
        raise ConfigError("[run].items: at least one item (for example a notebook)")
    command = r.get("command", "")
    if not command:
        raise ConfigError("[run].command is required ({item} is replaced by each item)")
    if r.get("metric"):
        try:
            if re.compile(str(r["metric"])).groups != 1:
                raise ConfigError("[run].metric must have exactly one (group) with the number")
        except re.error as e:
            raise ConfigError(f"[run].metric: invalid regex: {e}") from e
    errors = []
    for k, pat in (d.get("errors") or {}).items():
        try:
            errors.append((k, re.compile(str(pat))))
        except re.error as e:
            raise ConfigError(f"[errors].{k}: invalid regex: {e}") from e
    scen = {}
    for k, s in (d.get("scenarios") or {}).items():
        if not NAME_RE.fullmatch(k):
            raise ConfigError(f"[scenarios.{k}]: invalid name")
        source = (s or {}).get("from", "source")
        if source not in ("source", "warmup"):
            raise ConfigError(f"[scenarios.{k}].from: 'source' or 'warmup'")
        scen[k] = Scenario(k, source, str((s or {}).get("description", "")), _env((s or {}).get("env"), f"[scenarios.{k}].env"))
    if not scen:
        scen["default"] = Scenario("default", "source")
    warmup = bool(setup.get("warmup", True))
    if not warmup and any(s.source == "warmup" for s in scen.values()):
        raise ConfigError("a scenario uses from = \"warmup\" but [setup].warmup = false")
    vm = d.get("vm")
    return Bench(
        vm=int(vm) if vm is not None else None,
        name=name,
        git=str(src.get("git", "")),
        ref=str(src.get("ref", "")),
        files=list(files),
        setup=_strs(setup.get("commands"), "[setup].commands"),
        warmup=warmup,
        env=_env(d.get("env"), "[env]"),
        offline_env=_env(r.get("offline_env"), "[run].offline_env"),
        items=items,
        command=command,
        output=str(r.get("output", "")),
        timeout=int(r.get("timeout", 3600)),
        container_setup=_strs(r.get("container_setup"), "[run].container_setup"),
        errors=errors,
        scenarios=scen,
        metric=str(r.get("metric", "")),
    )


def subst(s: str, b: Bench, work: str = "", item: str = "") -> str:
    m = {"{shared}": str(b.shared), "{src}": str(b.src), "{work}": work, "{item}": item,
         "{item_name}": Path(item).name, "{name}": b.name}
    for k, v in m.items():
        s = s.replace(k, v)
    return s


def base_env(b: Bench, work: str) -> dict[str, str]:
    env = {
        "PATH": f"{BASE}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root",
        "LANG": "C.UTF-8",
    }
    env.update({k: subst(v, b, work) for k, v in b.env.items()})
    return env


# ─── GPU / LXD state ─────────────────────────────────────────────────────────


def mig_uuids() -> dict[str, tuple[int, int]]:
    """MIG UUID -> (GPU index, MIG device index), from nvidia-smi -L."""
    res, gpu = {}, -1
    for line in run(["nvidia-smi", "-L"]).splitlines():
        m = re.match(r"GPU (\d+):", line)
        if m:
            gpu = int(m.group(1))
            continue
        m = re.search(r"MIG \S+\s+Device\s+(\d+): \(UUID: (MIG-[0-9a-fA-F-]+)\)", line)
        if m:
            res[m.group(2)] = (gpu, int(m.group(1)))
    return res


def containers() -> list[dict]:
    out = []
    for c in json.loads(run(["lxc", "list", "--format", "json"])):
        cfg = c.get("config", {})
        dev = c.get("expanded_devices", {}) or {}
        uuid = next((v.get("mig.uuid") for v in dev.values() if v.get("type") == "gpu" and v.get("mig.uuid")), None)
        out.append({
            "name": c["name"],
            "running": c.get("status") == "Running",
            "managed": cfg.get(KEY + "managed") == "true",
            "mig_uuid": uuid,
            "devices": list((c.get("devices") or {}).keys()),
            "memory_limit": cfg.get("limits.memory"),
        })
    return out


def cgroup(name: str) -> Path:
    return Path(f"/sys/fs/cgroup/lxc.payload.{name}")


def read_int(p: Path) -> int | None:
    try:
        return int(p.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def mem_stat(name: str, key: str) -> int | None:
    try:
        for line in (cgroup(name) / "memory.stat").read_text().splitlines():
            k, v = line.split()
            if k == key:
                return int(v)
    except (OSError, ValueError):
        pass
    return None


def oom_kills(name: str) -> int:
    try:
        for line in (cgroup(name) / "memory.events").read_text().splitlines():
            k, v = line.split()
            if k == "oom_kill":
                return int(v)
    except (OSError, ValueError):
        pass
    return 0


# ─── Sampler ─────────────────────────────────────────────────────────────────


class Sampler(threading.Thread):
    """Samples GPUs, MIG slices, containers and the VM until stop() is called."""

    def __init__(self, cts: list[str], interval: float, gpu: bool = True):
        super().__init__(daemon=True)
        self.cts, self.interval, self.gpu_on = cts, interval, gpu
        self.stop_ev = threading.Event()
        self.t0 = time.time()
        self.series: list[dict] = []
        self.gpu: dict[int, dict] = {}
        self.mig_peak: dict[str, int] = {}  # "gpu:idx" -> MiB
        self.mig_total: dict[str, int] = {}
        self.ct_peak: dict[str, int] = {c: 0 for c in cts}  # memory.current: includes page cache
        self.ct_anon: dict[str, int] = {c: 0 for c in cts}  # anon memory: what the processes really use
        self.cpu_prev = self._cpu()
        self.errors = 0

    @staticmethod
    def _cpu() -> tuple[int, int]:
        v = [int(x) for x in open("/proc/stat").readline().split()[1:]]
        idle = v[3] + v[4]
        return sum(v), idle

    def sample(self) -> None:
        t = round(time.time() - self.t0, 1)
        s: dict = {"t": t, "gpus": []}
        try:
            if not self.gpu_on:
                raise LookupError  # --no-gpu-sampling: only containers and the VM
            q = run(["nvidia-smi", "--query-gpu=index,temperature.gpu,power.draw,clocks.sm,clocks_event_reasons.active",
                     "--format=csv,noheader,nounits"], timeout=30)
            for line in q.strip().splitlines():
                i, temp, pw, clk, reasons = [x.strip() for x in line.split(",")]
                i = int(i)
                temp = float(temp) if temp not in ("", "N/A") else None
                pw = float(pw) if pw not in ("", "N/A", "[N/A]") else None
                clk = float(clk) if clk not in ("", "N/A") else None
                bits = int(reasons, 16) if reasons.startswith("0x") else 0
                g = self.gpu.setdefault(i, {"temp_max": 0, "power_max": 0, "power_sum": 0.0, "n": 0,
                                            "clock_min_busy": None, "throttle": 0})
                if temp is not None:
                    g["temp_max"] = max(g["temp_max"], temp)
                if pw is not None:
                    g["power_max"] = max(g["power_max"], pw)
                    g["power_sum"] += pw
                    g["n"] += 1
                if clk is not None and not bits & 0x1:
                    g["clock_min_busy"] = clk if g["clock_min_busy"] is None else min(g["clock_min_busy"], clk)
                g["throttle"] |= bits & ~0x3
                s["gpus"].append([i, temp, pw, clk])
            root = ET.fromstring(run(["nvidia-smi", "-q", "-x"], timeout=60))
            used_total = 0
            for gi, g in enumerate(root.findall("gpu")):
                for md in g.findall("mig_devices/mig_device"):
                    key = f"{gi}:{int(md.findtext('index'))}"
                    used = int((md.findtext("fb_memory_usage/used") or "0").split()[0])
                    total = int((md.findtext("fb_memory_usage/total") or "0").split()[0])
                    self.mig_peak[key] = max(self.mig_peak.get(key, 0), used)
                    self.mig_total[key] = total
                    used_total += used
            s["mig_used_mib"] = used_total
        except LookupError:
            pass
        except Exception:
            self.errors += 1
        mem_sum = anon_sum = 0
        for c in self.cts:
            v = read_int(cgroup(c) / "memory.current")
            if v is not None:
                self.ct_peak[c] = max(self.ct_peak[c], v)
                mem_sum += v
            a = mem_stat(c, "anon")
            if a is not None:
                self.ct_anon[c] = max(self.ct_anon[c], a)
                anon_sum += a
        s["ct_mem"] = mem_sum
        s["ct_anon"] = anon_sum
        tot, idle = self._cpu()
        dt, di = tot - self.cpu_prev[0], idle - self.cpu_prev[1]
        self.cpu_prev = (tot, idle)
        s["cpu"] = round(100 * (1 - di / dt), 1) if dt > 0 else 0.0
        s["load1"] = float(open("/proc/loadavg").read().split()[0])
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"):
                s["mem_avail"] = int(line.split()[1]) * 1024
        self.series.append(s)

    def run(self) -> None:
        while not self.stop_ev.is_set():
            start = time.time()
            self.sample()
            self.stop_ev.wait(max(0.5, self.interval - (time.time() - start)))

    def stop(self) -> None:
        self.stop_ev.set()
        self.join(timeout=120)


def downsample(series: list[dict], n: int = 400) -> list[dict]:
    if len(series) <= n:
        return series
    step = len(series) / n
    return [series[int(i * step)] for i in range(n)]


# ─── Running items ───────────────────────────────────────────────────────────


def classify(b: Bench, text: str) -> str:
    for k, pat in b.errors:
        if pat.search(text):
            return k
    return "other"


def item_result(b: Bench, item: str, rc: int, secs: float, stderr: str, parsed: dict | None,
                stdout: str = "") -> dict:
    r = {"item": item, "rc": rc, "seconds": round(secs, 1), "errors": [], "status": "ok"}
    last = [x for x in stdout.strip().splitlines() if x.strip()]
    if last:
        r["note"] = last[-1][:300]
    if parsed and "missing" not in parsed:
        r["cells"] = parsed.get("cells")
        r["slowest_cell"] = parsed.get("slowest_cell")
        r["slowest_s"] = parsed.get("slowest_s")
        for e in parsed.get("errors", []):
            e["class"] = classify(b, f"{e['ename']}: {e['evalue']}")
            r["errors"].append(e)
    if rc != 0:
        tail = ([x for x in stderr.strip().splitlines() if x.strip()] + last[-2:])[-6:]
        r["stderr_tail"] = tail
        r["errors"].append({"cell": None, "ename": "rc", "evalue": tail[-1][:300] if tail else f"rc {rc}",
                            "class": classify(b, "\n".join(tail)) if tail else "failed"})
        r["status"] = "failed"
    elif r["errors"]:
        r["status"] = "errors"
    return r


def run_item_host(b: Bench, work: Path, item: str, env: dict[str, str]) -> dict:
    cmd = subst(b.command, b, str(work), item)
    t = time.time()
    try:
        p = subprocess.run(["sh", "-c", cmd], cwd=work, env=env, capture_output=True, text=True, timeout=b.timeout)
        rc, err, so = p.returncode, p.stderr, p.stdout
    except subprocess.TimeoutExpired:
        rc, err, so = 124, f"timeout after {b.timeout}s", ""
    secs = time.time() - t
    parsed = None
    out = subst(b.output, b, str(work), item) if b.output else ""
    if out.endswith(".ipynb"):
        p = subprocess.run([sys.executable, "-c", NB_PARSE, out], capture_output=True, text=True)
        parsed = json.loads(p.stdout or "{}")
    return item_result(b, item, rc, secs, err, parsed, so)


def lxc_exec(ct: str, script: str, env: dict[str, str] | None = None, cwd: str | None = None,
             timeout: int = 1800) -> subprocess.CompletedProcess:
    cmd = ["lxc", "exec", ct]
    for k, v in (env or {}).items():
        cmd += ["--env", f"{k}={v}"]
    if cwd:
        cmd += ["--cwd", cwd]
    cmd += ["--", "sh", "-c", script]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timeout after {timeout}s")


def run_item_ct(b: Bench, ct: str, item: str, env: dict[str, str]) -> dict:
    cmd = subst(b.command, b, b.work, item)
    t = time.time()
    p = lxc_exec(ct, cmd, env, b.work, timeout=b.timeout + 60)
    secs = time.time() - t
    parsed = None
    out = subst(b.output, b, b.work, item) if b.output else ""
    if out.endswith(".ipynb"):
        q = lxc_exec(ct, f"python3 -c {shlex.quote(NB_PARSE)} {shlex.quote(out)}", timeout=120)
        try:
            parsed = json.loads(q.stdout or "{}")
        except json.JSONDecodeError:
            parsed = None
    return item_result(b, item, p.returncode, secs, p.stderr, parsed, p.stdout)


def short(r: dict) -> str:
    if r["status"] == "ok":
        return "ok"
    classes = sorted({e["class"] for e in r["errors"]})
    return f"{r['status']} ({', '.join(classes)})"


# ─── Commands ────────────────────────────────────────────────────────────────


def need_root() -> None:
    if os.geteuid() != 0:
        sys.exit("must run as root inside the VM")


def sh_stream(cmd: str, cwd: Path, env: dict[str, str], timeout: int = 7200) -> int:
    log(f"  $ {cmd}")
    p = subprocess.Popen(["sh", "-c", cmd], cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True)
    t = time.time()
    assert p.stdout
    for line in p.stdout:
        log("    " + line.rstrip()[:300])
        if time.time() - t > timeout:
            p.kill()
            return 124
    return p.wait()


def copy_tree(src: Path, dst: Path) -> None:
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True)
    run(["sh", "-c", f"tar -C {shlex.quote(str(src))} --exclude=./.venv --exclude=./out -cf - . | "
                     f"tar -C {shlex.quote(str(dst))} -xf -"])


def cmd_prepare(b: Bench) -> int:
    need_root()
    b.shared.mkdir(parents=True, exist_ok=True)
    (b.state / "results").mkdir(parents=True, exist_ok=True)
    env = base_env(b, str(b.src))
    env.update({"UV_CACHE_DIR": str(UV_CACHE), "UV_PYTHON_DOWNLOADS": "never"})
    log(f"[{now()}] prepare '{b.name}' in {b.shared}")

    uv = BASE / "bin" / "uv"
    if not uv.exists():
        log(f"[{now()}] installing uv in {uv.parent}")
        rc = sh_stream("curl -LsSf https://astral.sh/uv/install.sh | sh", BASE,
                       {**env, "UV_INSTALL_DIR": str(uv.parent), "UV_NO_MODIFY_PATH": "1"})
        if rc != 0:
            log("ERROR: could not install uv")
            return 1

    if b.git:
        if not (b.src / ".git").exists():
            shutil.rmtree(b.src, ignore_errors=True)
            log(f"[{now()}] git clone {b.git}")
            run(["git", "clone", "-q", b.git, str(b.src)], timeout=1800)
        try:
            run(["git", "-C", str(b.src), "checkout", "-q", "--force", b.ref])
        except RuntimeError:
            run(["git", "-C", str(b.src), "fetch", "-q", "--all", "--tags"], timeout=1800)
            run(["git", "-C", str(b.src), "checkout", "-q", "--force", b.ref])
        # Back to the exact tree of ref: drops old outputs, keeps the environment
        run(["git", "-C", str(b.src), "clean", "-fdxq", "-e", ".venv"])
        head = run(["git", "-C", str(b.src), "log", "-1", "--format=%h %s"]).strip()
        log(f"[{now()}] source at {head}")
    else:
        b.src.mkdir(parents=True, exist_ok=True)

    files = b.state / "files"
    for dest in b.files:
        f = files / dest
        if not f.is_file():
            log(f"ERROR: {dest} was not uploaded to {f}")
            return 1
        target = b.src / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, target)
        log(f"[{now()}] added {dest} ({f.stat().st_size // 1024} KB)")

    for c in b.setup:
        rc = sh_stream(subst(c, b, str(b.src)), b.src, env)
        if rc != 0:
            log(f"ERROR: setup command failed (rc {rc})")
            return 1

    results = []
    if b.warmup:
        used = {c["mig_uuid"] for c in containers() if c["mig_uuid"]}
        free = [u for u, (g, i) in sorted(mig_uuids().items(), key=lambda x: x[1]) if u not in used]
        if not free:
            log("ERROR: warm-up needs a MIG slice no container uses (or set [setup].warmup = false)")
            return 1
        g, i = mig_uuids()[free[0]]
        log(f"[{now()}] warm-up on the free MIG slice GPU {g} device {i} (online: downloads the models)")
        copy_tree(b.src, b.warm)
        wenv = base_env(b, str(b.warm))
        wenv["CUDA_VISIBLE_DEVICES"] = free[0]
        (b.warm / "out").mkdir(exist_ok=True)
        for item in b.items:
            r = run_item_host(b, b.warm, item, wenv)
            results.append(r)
            log(f"[{now()}]   {item:<34} {fmt_s(r['seconds']):>7}  {short(r)}")
            for e in r["errors"]:
                log(f"      cell {e['cell']}: [{e['class']}] {e['ename']}: {e['evalue'][:160]}")
    run(["chmod", "-R", "a+rX", str(b.shared)])
    sizes = run(["du", "-sh", str(b.shared), str(b.src / ".venv")], check=False).strip().replace("\n", ", ")
    log(f"[{now()}] ready: {sizes}")
    if results:
        res = {"bench": b.name, "scenario": "warmup", "started": time.strftime("%Y-%m-%d %H:%M"),
               "containers": {"(vm)": {"items": results}}, "items": b.items}
        out = b.state / "results" / f"{time.strftime('%Y%m%d-%H%M%S')}-warmup.json"
        out.write_text(json.dumps(res, indent=1))
        log(f"RESULT {out}")
    return 0


def select_containers(args, b: Bench) -> list[dict]:
    cts = [c for c in containers() if c["managed"]]
    if args.containers and args.containers != "all":
        want = [x.strip() for x in args.containers.split(",") if x.strip()]
        names = {c["name"] for c in cts}
        missing = [w for w in want if w not in names]
        if missing:
            raise ConfigError(f"not managed containers: {', '.join(missing)}")
        cts = [c for c in cts if c["name"] in want]
    uuids = mig_uuids()
    for c in cts:
        c["slot"] = uuids.get(c["mig_uuid"] or "")
    if args.gpu is not None:
        cts = [c for c in cts if c["slot"] and c["slot"][0] == args.gpu]
    stopped = [c["name"] for c in cts if not c["running"]]
    if stopped:
        log(f"WARNING: skipping stopped containers: {', '.join(stopped)}")
    cts = [c for c in cts if c["running"]]
    cts.sort(key=lambda c: (c["slot"] or (99, 99), c["name"]))
    if args.count:
        cts = cts[: args.count]
    if not cts:
        raise ConfigError("no running managed container selected")
    return cts


def cmd_run(b: Bench, args) -> int:
    need_root()
    sc = b.scenarios.get(args.scenario)
    if not sc:
        raise ConfigError(f"unknown scenario '{args.scenario}' (have: {', '.join(b.scenarios)})")
    origin = b.warm if sc.source == "warmup" else b.src
    if not (b.src / ".venv").exists() or not origin.exists():
        log(f"ERROR: '{b.name}' is not prepared ({origin} missing): run prepare first")
        return 1
    cts = select_containers(args, b)
    names = [c["name"] for c in cts]
    log(f"[{now()}] scenario '{sc.name}' ({sc.description or sc.source}) in {len(cts)} containers")

    for c in cts:
        if b.device not in c["devices"]:
            run(["lxc", "config", "device", "add", c["name"], b.device, "disk", f"source={b.shared}",
                 f"path={b.shared}", "readonly=true"])
    copy = (f"rm -rf {b.work} && mkdir -p {b.work}/out && tar -C {origin} --exclude=./.venv --exclude=./out "
            f"-cf - . | tar -C {b.work} --no-same-owner -xf -")
    for extra in b.container_setup:
        copy += " && " + extra

    def prep(ct: str) -> tuple[str, int, str]:
        p = lxc_exec(ct, copy, timeout=1800)
        return ct, p.returncode, (p.stderr or p.stdout).strip()[-300:]

    with cf.ThreadPoolExecutor(max_workers=len(cts)) as ex:
        bad = [r for r in ex.map(prep, names) if r[1] != 0]
    if bad:
        for ct, rc, err in bad:
            log(f"ERROR: {ct}: work dir copy failed (rc {rc}): {err}")
        return 1
    log(f"[{now()}] work dirs ready ({b.work}); starting all at once")

    env = base_env(b, b.work)
    env.update(b.offline_env)
    env.update({k: subst(v, b, b.work) for k, v in sc.env.items()})
    oom0 = {c: oom_kills(c) for c in names}
    sampler = Sampler(names, args.interval, gpu=not args.no_gpu_sampling)
    sampler.start()
    barrier = threading.Barrier(len(names))
    started = time.strftime("%Y-%m-%d %H:%M")
    t0 = time.time()
    lock = threading.Lock()

    def worker(ct: str) -> tuple[str, list[dict]]:
        barrier.wait()
        if args.stagger:  # container k starts k * stagger seconds after the first one
            time.sleep(names.index(ct) * args.stagger)
        res = []
        for item in b.items:
            r = run_item_ct(b, ct, item, env)
            res.append(r)
            with lock:
                log(f"[{now()}] {ct:<26} {item:<34} {fmt_s(r['seconds']):>7}  {short(r)}")
        return ct, res

    with cf.ThreadPoolExecutor(max_workers=len(names)) as ex:
        per = dict(ex.map(worker, names))
    wall = time.time() - t0
    sampler.stop()

    cres = {}
    for c in cts:
        n = c["name"]
        slot = c["slot"]
        key = f"{slot[0]}:{slot[1]}" if slot else None
        cres[n] = {
            "items": per[n],
            "slot": key,
            "vram_peak_mib": sampler.mig_peak.get(key) if key else None,
            "vram_total_mib": sampler.mig_total.get(key) if key else None,
            "ram_peak": sampler.ct_peak.get(n),
            "ram_anon_peak": sampler.ct_anon.get(n),
            "ram_limit": c["memory_limit"],
            "oom_kills": oom_kills(n) - oom0[n],
        }
    gpus = {}
    for i, g in sorted(sampler.gpu.items()):
        gpus[str(i)] = {
            "temp_max": g["temp_max"], "power_max": g["power_max"],
            "power_avg": round(g["power_sum"] / g["n"], 1) if g["n"] else None,
            "clock_min_busy": g["clock_min_busy"],
            "throttle": [v for k, v in THROTTLE_BITS.items() if g["throttle"] & k],
        }
    res = {
        "bench": b.name, "scenario": sc.name, "description": sc.description, "from": sc.source, "env": sc.env,
        "started": started, "wall_seconds": round(wall, 1), "items": b.items,
        "containers": cres, "gpus": gpus, "sampler_errors": sampler.errors,
        "interval": args.interval, "series": downsample(sampler.series), "metric": b.metric,
    }
    (b.state / "results").mkdir(parents=True, exist_ok=True)
    out = b.state / "results" / f"{time.strftime('%Y%m%d-%H%M%S')}-{sc.name}-{len(names)}ct.json"
    out.write_text(json.dumps(res))
    log("")
    report([res])
    log(f"RESULT {out}")
    return 0


def cmd_clean(b: Bench) -> int:
    need_root()
    for c in containers():
        if b.device in c["devices"]:
            if c["running"]:
                lxc_exec(c["name"], f"rm -rf /root/mig-bench/{b.name} && rmdir /root/mig-bench 2>/dev/null; true")
            run(["lxc", "config", "device", "remove", c["name"], b.device], check=False)
            log(f"[{now()}] {c['name']}: mount and work dir removed")
    shutil.rmtree(b.shared, ignore_errors=True)
    shutil.rmtree(b.state / "files", ignore_errors=True)
    log(f"[{now()}] removed {b.shared}")
    if BASE.exists() and not [p for p in BASE.iterdir() if p.name != "bin"]:
        shutil.rmtree(BASE, ignore_errors=True)
        shutil.rmtree(UV_CACHE.parent, ignore_errors=True)
        log(f"[{now()}] removed {BASE} and the uv cache (no benchmark left)")
    log(f"Results kept in {b.state / 'results'}")
    return 0


# ─── Report ──────────────────────────────────────────────────────────────────


def report(results: list[dict]) -> None:
    """Prints each result; a 1-container run of the same scenario is used as baseline."""
    base: dict[str, dict[str, float]] = {}
    for r in results:
        if len(r["containers"]) == 1:
            ct = next(iter(r["containers"].values()))
            base[r["scenario"]] = {i["item"]: i["seconds"] for i in ct["items"] if i["status"] != "failed"}
    for r in results:
        cts = r["containers"]
        bl = base.get(r["scenario"], {}) if len(cts) > 1 else {}
        log(f"== {r['bench']} · scenario '{r['scenario']}' · {len(cts)} container(s) · {r['started']}"
            + (f" · wall {fmt_s(r.get('wall_seconds'))}" if r.get("wall_seconds") else ""))
        if r.get("description"):
            log(f"   {r['description']}")
        rows = [["Item", "OK", "min", "median", "max"] + (["solo", "x solo"] if bl else []) + ["Errors"]]
        if r.get("metric"):
            rows[0].insert(5, "metric min/med/max")
        for item in r["items"]:
            its = [i for c in cts.values() for i in c["items"] if i["item"] == item]
            secs = [i["seconds"] for i in its if i["status"] != "failed"]
            classes: dict[str, int] = {}
            for i in its:
                for e in i["errors"]:
                    classes[e["class"]] = classes.get(e["class"], 0) + 1
            med = statistics.median(secs) if secs else None
            row = [item, f"{sum(i['status'] == 'ok' for i in its)}/{len(its)}",
                   fmt_s(min(secs) if secs else None), fmt_s(med), fmt_s(max(secs) if secs else None)]
            if bl:
                s = bl.get(item)
                row += [fmt_s(s), f"{med / s:.1f}x" if s and med else "-"]
            row.append(", ".join(f"{k} {v}" for k, v in sorted(classes.items())) or "-")
            if r.get("metric"):
                vals = []
                for i in its:
                    m = re.search(r["metric"], i.get("note", ""))
                    if m:
                        vals.append(float(m.group(1)))
                row.insert(5, f"{min(vals):g}/{statistics.median(vals):g}/{max(vals):g}" if vals else "-")
            rows.append(row)
        w = [max(len(x[i]) for x in rows) for i in range(len(rows[0]))]
        for x in rows:
            log("   " + "  ".join(v.ljust(w[i]) for i, v in enumerate(x)).rstrip())
        errs = [(n, i["item"], e) for n, c in cts.items() for i in c["items"] for e in i["errors"]]
        if errs:
            seen: dict[tuple, list[str]] = {}
            for n, item, e in errs:
                seen.setdefault((item, e["cell"], e["class"], e["ename"], e["evalue"][:120]), []).append(n)
            log("   Errors (item, cell, class: message -> containers):")
            for (item, cell, cl, en, ev), ns in list(seen.items())[:15]:
                who = ", ".join(ns[:3]) + (f" +{len(ns) - 3}" if len(ns) > 3 else "")
                log(f"     {item} cell {cell} [{cl}] {en}: {ev}  -> {who}")
        if "gpus" not in r:
            log("")
            continue
        vram = [(c["vram_peak_mib"], c["vram_total_mib"], n) for n, c in cts.items() if c.get("vram_peak_mib") is not None]
        ram = [(c["ram_peak"], n, c.get("ram_limit")) for n, c in cts.items() if c.get("ram_peak")]
        anon = [(c["ram_anon_peak"], n) for n, c in cts.items() if c.get("ram_anon_peak")]
        ooms = sum(c.get("oom_kills", 0) for c in cts.values())
        if vram:
            mx = max(vram)
            log(f"   VRAM peak per slice: median {statistics.median(v[0] for v in vram) / 1024:.2f} GiB, "
                f"max {mx[0] / 1024:.2f} of {mx[1] / 1024:.2f} GiB ({mx[2]})")
        if ram:
            mx = max(ram)
            if anon:
                ma = max(anon)
                log(f"   RAM used by the processes (anon) per container: median "
                    f"{fmt_gib(statistics.median(v[0] for v in anon))} GiB, max {fmt_gib(ma[0])} GiB ({ma[1]})")
            log(f"   RAM incl. page cache (memory.current): median {fmt_gib(statistics.median(v[0] for v in ram))} GiB, "
                f"max {fmt_gib(mx[0])} GiB of {mx[2]} ({mx[1]}); OOM kills: {ooms}")
        for i, g in r["gpus"].items():
            log(f"   GPU {i}: temp max {g['temp_max']:.0f} C, power avg/max {g['power_avg'] or 0:.0f}/{g['power_max']:.0f} W, "
                f"SM clock min (busy) {g['clock_min_busy'] or '-'} MHz, throttle: {', '.join(g['throttle']) or 'none'}")
        s = r.get("series") or []
        if s:
            cpu = [x["cpu"] for x in s]
            log(f"   VM: CPU avg {statistics.mean(cpu):.0f}% max {max(cpu):.0f}%, load max {max(x['load1'] for x in s):.1f}, "
                f"RAM available min {fmt_gib(min(x.get('mem_avail', 0) for x in s))} GiB")
        if r.get("sampler_errors"):
            log(f"   (sampler errors: {r['sampler_errors']})")
        log("")


def main() -> int:
    ap = argparse.ArgumentParser(prog="mig_bench.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("check", "prepare", "clean"):
        sub.add_parser(c).add_argument("config")
    p = sub.add_parser("run")
    p.add_argument("config")
    p.add_argument("--scenario", required=True)
    p.add_argument("--containers", default="all", help="comma-separated names, or all")
    p.add_argument("--gpu", type=int, help="only containers on this GPU")
    p.add_argument("--count", type=int, help="only the first N (ordered by GPU and slice)")
    p.add_argument("--interval", type=float, default=3.0, help="sampling interval in seconds")
    p.add_argument("--stagger", type=float, default=0, help="seconds between container starts (0: all at once)")
    p.add_argument("--no-gpu-sampling", action="store_true", help="do not run nvidia-smi during the run")
    p = sub.add_parser("report")
    p.add_argument("results", nargs="+")
    args = ap.parse_args()
    try:
        if args.cmd == "report":
            report([json.loads(Path(f).read_text()) for f in args.results])
            return 0
        b = load_config(args.config)
        if args.cmd == "check":
            log(f"OK: '{b.name}', {len(b.items)} items, scenarios: "
                + ", ".join(f"{s.name} (from {s.source})" for s in b.scenarios.values()))
            return 0
        if args.cmd == "prepare":
            return cmd_prepare(b)
        if args.cmd == "run":
            return cmd_run(b, args)
        if args.cmd == "clean":
            return cmd_clean(b)
    except ConfigError as e:
        log(f"Config error: {e}")
        return 3
    except RuntimeError as e:
        log(f"ERROR: {e}")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
