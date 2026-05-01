#!/usr/bin/env bash
set -euo pipefail

curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh
chmod 755 /usr/local/bin/uv /usr/local/bin/uvx
