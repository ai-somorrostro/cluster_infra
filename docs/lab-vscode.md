# Working in a lab container from VS Code

Each person has an LXD container with **one MIG slice** (`1g.5gb`: 4.75 GiB of VRAM), 2 vCPU, 9 GB of RAM and 30 GB of disk, on the lab VM (see [mig.md](mig.md#lab-one-container-per-person)). The intended way to work is **VS Code Remote - SSH**: the editor runs on your laptop, and the code, the Python environment and the GPU live in the container.

## Connect

You get a **port**, a **user** and an **initial password** (the teacher runs `vm/vm_mig_lxd.sh status <vm>`). From outside the school network, connect the students' VPN first ([vpn.md](vpn.md)).

1. **First login from a terminal**, not from VS Code: the initial password must be changed, and VS Code does not handle that prompt.

   ```bash
   ssh -p <port> <user>@<VM IP>      # asks for the initial password, then a new one twice
   ```

2. **SSH key**, so VS Code does not ask for the password on every reconnect:

   ```bash
   ssh-keygen -t ed25519                         # only if you have no key yet
   ssh-copy-id -p <port> <user>@<VM IP>
   ```

   On Windows without `ssh-copy-id`, append `~/.ssh/id_ed25519.pub` to `~/.ssh/authorized_keys` in the container.

3. **`~/.ssh/config`** on your laptop:

   ```
   Host lab
       HostName <VM IP>
       Port <port>
       User <user>
   ```

4. In VS Code, install **Remote - SSH**, run *Remote-SSH: Connect to Host…*, and choose `lab`. Then install the **Python** and **Jupyter** extensions *in the remote* (the Extensions view shows "Install in SSH: lab").

## Project and environment

```bash
git clone <course repo> && cd <repo>
uv sync                       # creates .venv with the course's packages (torch with CUDA included)
nvidia-smi                    # shows only your slice
```

In a notebook, choose **Select Kernel → Python Environments → `.venv/bin/python`**.

## Limits of a 1g.5gb slice

- **One notebook with a running kernel at a time.** A course notebook can use up to ~4.2 of the 4.75 GiB. A kernel keeps its models in VRAM until it stops, even when you move on to another notebook, so two open kernels give `CUDA out of memory`.
  - Closing the notebook tab stops its kernel.
  - To free the VRAM without closing it, use **Restart** in the notebook toolbar.
  - `nvidia-smi` lists what is using your slice.
- An OOM only affects your own slice: MIG isolates the slices, so nobody else notices.
- **RAM: 9 GB for everything**, including the VS Code server and Pylance (about 0.5-1 GB). If the kernel dies with no error message, look at RAM with `free -h`.
- **CPU: 2 vCPU.** Pylance indexing a large `.venv` takes a few minutes the first time.
- `nvidia-smi --query-gpu=memory.total` prints `[Insufficient Permissions]` on a MIG slice. That is normal; CUDA works.

## For the teacher

- The 20 containers were load-tested with the week 2 notebooks all at once: 0 errors, VRAM peak 4.19 GiB per slice ([mig.md](mig.md#load-test-vmvm_mig_benchsh)).
  - That test runs every notebook with `nbconvert`, which stops its kernel when it finishes. Two kernels open at the same time were **not** tested.
- If the course ships an LLM answer cache whose keys contain document text, ship the **parsed document too** (for example Docling's `docling.json`). Parsing the PDF again on another machine gives slightly different text, so every cached call misses.
- Forgotten password: `vm/vm_mig_lxd.sh passwd CONFIG CONTAINER USER` gives a new temporary one, and the person logs in from a terminal again (step 1).
