# Proxmox MCP server (ProxmoxMCP-Plus)

Configuration of the [ProxmoxMCP-Plus](https://github.com/RekklesNA/ProxmoxMCP-Plus) MCP server, used to manage the Azeroth Proxmox VE cluster from Claude Code.

This folder only holds configuration. The server itself is the `proxmox-mcp-plus` package, which `uvx` downloads and runs.

## Summary

| Item | Value |
| --- | --- |
| Package | [`proxmox-mcp-plus`](https://pypi.org/project/proxmox-mcp-plus/) (PyPI) |
| Transport | `stdio`: Claude Code starts the process with the session, no long-running server |
| Client | Claude Code, **user** scope (available in every project) |
| Proxmox | `https://192.168.136.238:8006` (kalimdor) |
| Cluster | `kalimdor`, `eastkingdoms`, `northrend` |
| Authentication | API token `root@pam!mcp-token`, *Privilege Separation* disabled (same rights as `root@pam`) |
| TLS | Verified (`verify_ssl: true`) against the cluster CA (`pve-root-ca.pem`) |
| Shell commands | Disabled (`command_policy.mode: deny_all`, no `ssh` section) |

```
Claude Code ──(stdio)──> uvx proxmox-mcp-plus ──(HTTPS :8006 + API token)──> Proxmox VE
```

The MCP uses its **own token** (`mcp-token`), separate from the `root@pam!infra` token in the repo `.env` that the scripts use. Each one can be revoked without breaking the other.

## Files

```
mcp/proxmox/
├── README.md               # this document
├── config.example.json     # template without secrets (committed)
├── config.json             # real config with the token secret (NOT committed)
├── pve-root-ca.pem         # root CA of the Proxmox cluster (public, committed)
├── proxmox_mcp.log         # server log (generated, not committed)
└── proxmox-jobs.sqlite3*   # state of async jobs (generated, not committed)
```

`config.json`, `*.log` and `*.sqlite3*` are in the root `.gitignore`, and `make secrets` fails if `config.json` is ever tracked. **The repo is public**: never commit the real `config.json`.

---

## Setup from scratch

### 0. Requirements

- [`uv`](https://docs.astral.sh/uv/): `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Claude Code (`claude` CLI)
- `openssl` (only to check the certificate)
- Network access to port `8006` of the Proxmox node

Check that the package starts. Without a config it must fail with `Proxmox host must be provided`, which is expected:

```bash
uvx proxmox-mcp-plus </dev/null
```

### 1. Create the API token in Proxmox

In the Proxmox web UI: **Datacenter → Permissions → API Tokens → Add**

- **User:** `root@pam`
- **Token ID:** `mcp-token`
- Copy the **Secret** (it is shown only once)

Our token has *Privilege Separation* **disabled** (untick it when creating the token, or edit it later), so it has the same rights as `root@pam`. Keep that in mind: through the MCP, Claude can create, stop and delete VMs.

If you leave *Privilege Separation* enabled (the default), give the token permissions instead:
**Datacenter → Permissions → Add → API Token Permission**

- **Path:** `/`
- **API Token:** `root@pam!mcp-token`
- **Role:** `PVEAuditor` (read-only) or `Administrator` (full management)
- **Propagate:** yes

> Without this step the MCP connects, but nodes show uptime 0, CPU N/A and 0 B of memory.

Check the token from the machine that runs Claude Code:

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  -H 'Authorization: PVEAPIToken=root@pam!mcp-token=<SECRET>' \
  https://192.168.136.238:8006/api2/json/version
# 200
```

### 2. Get the Proxmox CA

Proxmox uses a certificate signed by its own CA (`PVE Cluster Manager CA`). Instead of disabling TLS, we trust that CA.

`pve-root-ca.pem` in this folder is already that CA. It is the same for the whole cluster and expires in 2036. To fetch it again, in a node shell (**node → Shell**):

```bash
cat /etc/pve/pve-root-ca.pem
```

Check it:

```bash
cd mcp/proxmox
openssl s_client -connect 192.168.136.238:8006 \
  -CAfile pve-root-ca.pem -verify_ip 192.168.136.238 </dev/null 2>/dev/null \
  | grep "Verify return code"
# Verify return code: 0 (ok)
```

> Do not use the node certificate (the one `openssl s_client` prints): Python needs the root CA and fails with `unable to get local issuer certificate`.
>
> ProxmoxMCP-Plus refuses `verify_ssl: false` unless `security.dev_mode: true` is set. We do not use it.

### 3. Create `config.json`

Generate it from the template. `<MCP_DIR>` becomes the **absolute** path of this folder:

```bash
cd mcp/proxmox
sed "s|<MCP_DIR>|$(pwd)|g" config.example.json > config.json
chmod 600 config.json
nano config.json   # paste the secret into auth.token_value
```

Notes:

- `token_name` is only the ID (`mcp-token`), not `root@pam!mcp-token`.
- `host` has no `https://` and no port.
- `logging.file` and `jobs.sqlite_path` must be absolute: Claude Code starts the process from whatever directory it is in, so a relative path would end up anywhere.

### 4. Register the MCP in Claude Code

From this folder:

```bash
cd mcp/proxmox
claude mcp remove proxmox -s user 2>/dev/null   # drop a previous registration, if any
claude mcp add proxmox -s user \
  -e PROXMOX_MCP_CONFIG="$(pwd)/config.json" \
  -e REQUESTS_CA_BUNDLE="$(pwd)/pve-root-ca.pem" \
  -- uvx proxmox-mcp-plus
```

- `-s user`: the registration goes to `~/.claude.json` and the MCP is available in every project.
- `PROXMOX_MCP_CONFIG`: path to `config.json`.
- `REQUESTS_CA_BUNDLE`: makes Python trust the Proxmox CA.

### 5. Check

```bash
claude mcp get proxmox
# Status: ✔ Connected
```

Restart Claude Code. `/mcp` shows the `proxmox` server with its tools (`get_nodes`, `get_vms`, `get_containers`, `get_storage`…). Try: *"list the nodes of my Proxmox"*.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Failed to connect` | Start it by hand to see the error: `PROXMOX_MCP_CONFIG=$(pwd)/config.json REQUESTS_CA_BUNDLE=$(pwd)/pve-root-ca.pem uvx proxmox-mcp-plus </dev/null` |
| `Proxmox host must be provided` | `PROXMOX_MCP_CONFIG` does not point to the right `config.json` |
| `Insecure TLS configuration blocked` | `verify_ssl` is `false`. Use `true` + `REQUESTS_CA_BUNDLE` |
| `CERTIFICATE_VERIFY_FAILED` / `unable to get local issuer certificate` | `REQUESTS_CA_BUNDLE` does not point to the root CA (`pve-root-ca.pem`) |
| `401 Unauthorized` | Wrong token (check `user`, `token_name`, `token_value`) |
| Nodes with uptime 0 / 0 B memory | The token has no permissions: see step 1 (*API Token Permission*) |
| `server/discover` warnings in the log | Harmless: a method this package version does not know |
| Changes to `config.json` do not apply | Restart Claude Code (or `/mcp` → reconnect) |

## Management

```bash
claude mcp list                    # list servers
claude mcp get proxmox             # status and configuration
claude mcp remove proxmox -s user  # remove
```

To extend it (command execution in LXC over SSH, tool filtering, HTTP/Docker mode) see the [project documentation](https://github.com/RekklesNA/ProxmoxMCP-Plus).
