#!/usr/bin/env python3
"""gpu_stress.py — steady CUDA load for vm_mig_bench.sh (config/bench/gpu-stress.toml).

Runs fp16 and fp32 matrix products on the visible GPU (a MIG slice in a container) for
--seconds, allocating and freeing memory on the way, and checks the results against a
reference computed at the start: a wrong result means the GPU or the driver corrupted
data. Prints one summary line. Exit codes: 0 ok, 1 CUDA error, 2 wrong result.

--duty 0.7 keeps the GPU busy about 70% of the time (it sleeps after each batch for the
matching share), for a partial load such as a fan noise test. --seconds and --duty also
read GPU_STRESS_SECONDS and GPU_STRESS_DUTY, so a bench scenario can set them with env.
"""
import argparse
import os
import sys
import time

import torch


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=float(os.environ.get("GPU_STRESS_SECONDS", 60)))
    ap.add_argument("--duty", type=float, default=float(os.environ.get("GPU_STRESS_DUTY", 1.0)),
                    help="share of the time the GPU is busy, 0.05-1 (default 1: full load)")
    ap.add_argument("--size", type=int, default=4096)
    ap.add_argument("--mem-gib", type=float, default=2.0, help="extra memory allocated and freed in a loop")
    a = ap.parse_args()
    if not 0.05 <= a.duty <= 1:
        ap.error("--duty must be between 0.05 and 1")
    if not torch.cuda.is_available():
        print("FAIL no CUDA device")
        return 1
    dev = torch.device("cuda")
    name = torch.cuda.get_device_name(0)
    g = torch.Generator(device="cpu").manual_seed(1234)
    c32 = torch.randn(1024, 1024, generator=g)
    x16 = torch.randn(a.size, a.size, generator=g).to(dev, torch.float16)
    x32 = c32.to(dev)
    # Round trip host -> GPU -> host (DMA by the copy engine), and a GPU-only computation
    back = x32.cpu()
    on_gpu = torch.ones(1024, 1024, device=dev).sum().item()
    if not torch.equal(back, c32) or on_gpu != 1024 * 1024:
        zeros = int((back == 0).sum())
        print(f"WRONG RESULTS at start: copy back equal={torch.equal(back, c32)} ({zeros} zeros of {back.numel()}), "
              f"ones on GPU {on_gpu!r}/{1024 * 1024}")
        return 2
    ref16 = (x16 @ x16).float().sum().item()
    ref32 = (x32 @ x32).sum().item()
    torch.cuda.synchronize()
    # Reference on the CPU too: a wrong GPU reference would make every later check fail
    cpu32 = (x32.cpu() @ x32.cpu()).sum().item()
    if abs(cpu32 - ref32) > 1e-3 * max(1.0, abs(cpu32)):
        print(f"WRONG RESULTS at start: GPU fp32 reference {ref32!r} != CPU {cpu32!r}")
        return 2
    first_bad = ""
    n, bad, t0, idle = 0, 0, time.time(), 0.0
    chunk = int(a.mem_gib * 1024**3 / 4)
    try:
        while time.time() - t0 < a.seconds:
            t_batch = time.time()
            for _ in range(20):
                y = x16 @ x16
            buf = torch.empty(chunk, device=dev)
            buf.fill_(1.0)
            s = buf.sum().item()
            del buf
            r16 = y.float().sum().item()
            r32 = (x32 @ x32).sum().item()
            checks = {"fill": s == chunk, "fp16": abs(r16 - ref16) <= 1e-3 * max(1.0, abs(ref16)), "fp32": r32 == ref32}
            if not all(checks.values()):
                bad += 1
                if not first_bad:
                    first_bad = (f" (first at {time.time() - t0:.0f}s: {[k for k, v in checks.items() if not v]}; "
                                 f"fill {s:.0f}/{chunk}, fp16 {r16:.6g}/{ref16:.6g}, fp32 {r32!r}/{ref32!r})")
            n += 20
            if a.duty < 1:  # .item() above waited for the GPU, so this is the real busy time
                pause = (time.time() - t_batch) * (1 - a.duty) / a.duty
                time.sleep(pause)
                idle += pause
    except RuntimeError as e:  # CUDA errors (illegal instruction, OOM...) arrive as RuntimeError
        print(f"FAIL after {time.time() - t0:.1f}s, {n} matmuls: {type(e).__name__}: {str(e).splitlines()[0]}")
        return 1
    dt = time.time() - t0
    tflops = 2 * a.size**3 * n / dt / 1e12
    peak = torch.cuda.max_memory_allocated() / 1024**3
    status = "OK" if not bad else f"WRONG RESULTS in {bad} of {n // 20} checks{first_bad}"
    busy = f", busy {100 * (dt - idle) / dt:.0f}% of the time" if a.duty < 1 else ""
    print(f"{status} {name}: {n} matmuls in {dt:.0f}s, {tflops:.1f} TFLOPS fp16, peak {peak:.2f} GiB{busy}")
    return 0 if not bad else 2


if __name__ == "__main__":
    sys.exit(main())
