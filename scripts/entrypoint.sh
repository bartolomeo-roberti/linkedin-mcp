#!/bin/bash
set -euo pipefail

# `--login` is the guided browser sign-in. The upstream supervisor starts Xvfb
# and then runs the server with the viewer flags; HEADLESS must be off so the
# browser has a display to draw on. Everything else stays the runner path: the
# gate owns :3000, the bridge listens on loopback, and the server speaks stdio.
if [[ ${1-} == --login ]]; then
    export HEADLESS=false
    # The upstream supervisor starts Xvfb at 1280x800 and the login window is
    # sized from this viewport. The window's chrome is about 8x131 px, so this
    # viewport leaves the outer window at roughly the virtual screen's size
    # instead of a 1050x780 default inside a much larger display.
    export VIEWPORT=1272x669
    # The login browser must not offer to store the LinkedIn password in the
    # profile volume. Merge both password-manager switches into an existing
    # Preferences file before the supervisor starts Chromium. The login rotates
    # the profile, so the image's setup.py patch carries this file into the
    # fresh profile; when the volume is empty, that patch creates it there.
    profile_preferences=/home/pwuser/.linkedin-mcp/profile/Default/Preferences
    if [[ -f $profile_preferences ]]; then
        python3 - "$profile_preferences" <<'PY'
import json
import os
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        preferences = json.load(stream)
    if not isinstance(preferences, dict):
        preferences = {}
except (OSError, ValueError):
    preferences = {}

preferences["credentials_enable_service"] = False
profile = preferences.get("profile")
if not isinstance(profile, dict):
    profile = {}
profile["password_manager_enabled"] = False
preferences["profile"] = profile

temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(preferences, stream, indent=2)
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
    fi
    exec tini -e 143 -- linkedin-mcp-entrypoint python -m linkedin_mcp_server "$@"
fi

exec python3 /opt/cerase/runner-gate.py -- /opt/bridge/bin/mcp-proxy \
    --port 3001 --host 127.0.0.1 --pass-environment -- \
    python -m linkedin_mcp_server "$@"
