#!/bin/bash
set -euo pipefail

# `--login` is the guided browser sign-in. The upstream supervisor starts Xvfb
# and then runs the server with the viewer flags; HEADLESS must be off so the
# browser has a display to draw on. Everything else stays the runner path: the
# gate owns :3000, the bridge listens on loopback, and the server speaks stdio.
if [[ ${1-} == --login ]]; then
    export HEADLESS=false
    # Chromium keeps its crash database and caches under the XDG directories.
    # The console's root is read-only, so point them at the writable tmpfs; the
    # profile itself stays on the mounted /home/pwuser/.linkedin-mcp.
    export XDG_CONFIG_HOME=/tmp/cerase-xdg/config
    export XDG_CACHE_HOME=/tmp/cerase-xdg/cache
    export XDG_DATA_HOME=/tmp/cerase-xdg/data
    exec tini -e 143 -- linkedin-mcp-entrypoint python -m linkedin_mcp_server "$@"
fi

exec python3 /opt/cerase/runner-gate.py -- /opt/bridge/bin/mcp-proxy \
    --port 3001 --host 127.0.0.1 --pass-environment -- \
    python -m linkedin_mcp_server "$@"
