# The LinkedIn connector, built on the upstream image.
#
# The base is stickerdaniel/linkedin-mcp-server, which already carries the
# server, its Python environment and the browser it drives. Pinned by digest
# because a tag on Docker Hub can be re-pushed; the digest is the `latest` tag
# as published on 2026-11-04. To move the version, change the tag and the digest
# together and keep the catalogue entry unchanged.
FROM docker.io/stickerdaniel/linkedin-mcp-server@sha256:8f6b618b9965eb3eb12dd27df861f019ab621a78b408a9b7cd4aaef62954ce97 AS runtime

LABEL org.opencontainers.image.source="https://github.com/bartolomeo-roberti/linkedin-mcp" \
      org.opencontainers.image.licenses="Apache-2.0"

USER root

# A separate environment for the bridge and the two scripts, so the upstream
# application environment at /app/.venv is not modified. mcp-proxy 0.12.0 asks
# for mcp>=1.17 but imports names the 2.x SDK removed, so the SDK is pinned
# beside it.
RUN /usr/local/bin/python3 -m venv /opt/bridge \
    && /opt/bridge/bin/pip install --no-cache-dir mcp-proxy==0.12.0 mcp==1.30.0

# The gate owns :3000 and passes only requests carrying this runner's token to
# the bridge on 127.0.0.1:3001. The liveness probe performs the MCP handshake
# and tools/list through the bridge.
COPY --chmod=755 scripts/runner-gate.py /opt/cerase/runner-gate.py
COPY --chmod=755 scripts/healthcheck.py /opt/cerase/healthcheck.py
COPY --chmod=755 scripts/entrypoint.sh /opt/cerase/entrypoint.sh

# The console serves the login viewer through its reverse proxy under a path
# prefix. The login page builds the WebSocket address from a root path, which
# cannot be reached behind that prefix; address it relative to the page
# instead. The build fails unless the pinned page is exactly the one this
# replacement expects.
RUN before=$(grep -cF '${location.host}/websockify?token=' /usr/share/novnc/login.html) \
    && [ "$before" -eq 1 ] \
    && sed -i "s|\${location\.host}/websockify?token=|\${location.host}\${location.pathname.replace(/[^/]*\$/, '')}websockify?token=|" /usr/share/novnc/login.html \
    && after=$(grep -cF "\${location.host}\${location.pathname.replace(/[^/]*\$/, '')}websockify?token=" /usr/share/novnc/login.html) \
    && [ "$after" -eq 1 ]

# The login viewer's virtual screen has to match the browser window, or noVNC
# scales a small window inside a much larger screen. The upstream supervisor
# hard-codes 1920x1080; 1280x800 is the size the login window is measured
# against. The build fails unless the pinned line is the one this replacement
# expects.
RUN file=/usr/local/bin/linkedin-mcp-entrypoint \
    && before=$(grep -cF -- '-screen 0 1920x1080x24' "$file") \
    && [ "$before" -eq 1 ] \
    && sed -i 's|-screen 0 1920x1080x24|-screen 0 1280x800x24|' "$file" \
    && after=$(grep -cF -- '-screen 0 1280x800x24' "$file") \
    && [ "$after" -eq 1 ]

# The pinned upstream launches a headed browser with no viewport, so VIEWPORT
# would not size the login window: the window would keep Chromium's default
# size inside the virtual screen. Use the configured viewport for a headed
# launch as well; a headless launch already does, and the runner is headless.
# The build fails unless the pinned line is the one this replacement expects.
RUN file=/app/.venv/lib/python3.13/site-packages/linkedin_mcp_server/core/browser.py \
    && before=$(grep -cF '        if self.headless:' "$file") \
    && [ "$before" -eq 1 ] \
    && sed -i 's|        if self.headless:|        if self.headless or self.viewport is not None:|' "$file" \
    && after=$(grep -cF '        if self.headless or self.viewport is not None:' "$file") \
    && [ "$after" -eq 1 ]

# A browser that cannot start is not a network fault. The pinned upstream maps
# every launch failure to NetworkError, which the server reports to the
# assistant as "Network error. Check your connection and try again." Report the
# browser-unavailable error instead. The build fails unless both pinned lines
# are the ones these replacements expect.
RUN file=/app/.venv/lib/python3.13/site-packages/linkedin_mcp_server/core/browser.py \
    && before_import=$(grep -cF '    BrowserDowngradeError,' "$file") \
    && [ "$before_import" -eq 1 ] \
    && sed -i 's|    BrowserDowngradeError,|    BrowserBinaryMissingError,\n    BrowserDowngradeError,|' "$file" \
    && after_import=$(grep -cF '    BrowserBinaryMissingError,' "$file") \
    && [ "$after_import" -eq 1 ] \
    && before_raise=$(grep -cF 'raise NetworkError(' "$file") \
    && [ "$before_raise" -eq 1 ] \
    && sed -i 's|raise NetworkError(|raise BrowserBinaryMissingError(|' "$file" \
    && after_raise=$(grep -cF 'raise BrowserBinaryMissingError(' "$file") \
    && [ "$after_raise" -eq 1 ] \
    && before_message=$(grep -cF 'raise BrowserBinaryMissingError(' "$file") \
    && [ "$before_message" -eq 1 ] \
    && sed -i '/raise BrowserBinaryMissingError(/,+1 s|f"Failed to start browser: |f"The browser could not start: |' "$file" \
    && after_message=$(grep -cF 'f"The browser could not start: ' "$file") \
    && [ "$after_message" -eq 1 ]

# The login rotates the profile before it opens the browser, so a Preferences
# file written before the supervisor starts is moved into quarantine with the
# old session. Carry that file into the fresh profile and merge the two
# password-manager switches there. The build fails unless every pinned anchor
# is present exactly once.
RUN python3 - <<'PY'
from pathlib import Path

path = Path("/app/.venv/lib/python3.13/site-packages/linkedin_mcp_server/setup.py")
source = path.read_text(encoding="utf-8")

import_marker = "import functools\n"
assert source.count(import_marker) == 1
source = source.replace(import_marker, import_marker + "import json\n", 1)

helper_marker = "async def _login_holding_the_profile(\n"
assert source.count(helper_marker) == 1
helper = '''def _carry_login_preferences(retired: Path | None, user_data_dir: Path) -> None:
    """Carry the retired profile's settings into the fresh login profile.

    The login rotates the profile, so a Preferences file written before the
    rotation moves into quarantine with the old session. Read it from the
    retired directory, merge the two switches that keep Chromium from offering
    to store the LinkedIn password, and write it into the fresh profile before
    the browser opens.
    """
    preferences: dict[str, Any] = {}
    if retired is not None:
        try:
            loaded = json.loads(
                (retired / user_data_dir.name / "Default" / "Preferences").read_text(
                    encoding="utf-8"
                )
            )
            if isinstance(loaded, dict):
                preferences = loaded
        except (OSError, ValueError):
            pass
    preferences["credentials_enable_service"] = False
    profile = preferences.get("profile")
    if not isinstance(profile, dict):
        profile = {}
    profile["password_manager_enabled"] = False
    preferences["profile"] = profile
    target = user_data_dir / "Default" / "Preferences"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(preferences), encoding="utf-8")
    target.chmod(0o600)


'''
source = source.replace(helper_marker, helper + helper_marker, 1)

call_marker = "    retired = await rotate_shielded(user_data_dir)\n"
assert source.count(call_marker) == 1
source = source.replace(
    call_marker,
    call_marker + "    _carry_login_preferences(retired, user_data_dir)\n",
    1,
)

path.write_text(source, encoding="utf-8")
PY

# The browser is already in the image at /opt/patchright, but upstream's first
# login writes an install marker into the profile root and runs the installer
# when it is missing. The console's root is read-only, so that installer cannot
# create its lock beside the browser and the login would never reach the
# viewer. This marker describes the pinned browser that is already present, and
# Docker seeds it into a fresh profile volume.
RUN printf '%s\n' \
        '{"browser_name":"chromium","installer_name":"patchright","version":3,"browsers_path":"/opt/patchright"}' \
        > /home/pwuser/.linkedin-mcp/browser-install.json \
    && chown pwuser:pwuser /home/pwuser/.linkedin-mcp/browser-install.json \
    && chmod 600 /home/pwuser/.linkedin-mcp/browser-install.json

# The upstream image runs as pwuser and keeps its server on PATH through
# /app/.venv/bin. The bridge is called by absolute path, so `python` below is
# still the upstream environment and not /opt/bridge.
USER pwuser
WORKDIR /home/pwuser

# A Cerase runner has no display. The upstream image defaults to a headed
# browser on Xvfb; with this entrypoint no X server is started, so the server
# must run headless.
ENV HEADLESS=true

# The image is pinned by digest and updated by the platform, so two PyPI checks
# could only add an update notice nobody can act on and a request to pypi.org
# that the egress refuses: the upstream's daily check of this package, and the
# FastMCP library's check of its own version when the server starts.
ENV LINKEDIN_MCP_CHECK_FOR_UPDATES=off \
    FASTMCP_CHECK_FOR_UPDATES=off

# Chromium keeps its crash database and caches under the XDG directories. The
# console's root is read-only, so point them at the writable tmpfs; the profile
# itself stays on the mounted /home/pwuser/.linkedin-mcp. ENV rather than an
# export in the entrypoint, so the login and runner paths and `docker exec` all
# see the same directories. Chromium creates them as it needs them.
ENV XDG_CONFIG_HOME=/tmp/cerase-xdg/config \
    XDG_CACHE_HOME=/tmp/cerase-xdg/cache \
    XDG_DATA_HOME=/tmp/cerase-xdg/data

EXPOSE 3000

ENV CERASE_HEALTHCHECK_URL=http://127.0.0.1:3001/mcp

HEALTHCHECK --interval=5m --start-interval=5s --timeout=10s --start-period=60s --retries=2 \
    CMD python3 /opt/cerase/runner-gate.py --probe && python3 /opt/cerase/healthcheck.py || exit 1

# The upstream server speaks MCP over stdio. mcp-proxy bridges it to HTTP on
# loopback and the gate exposes that bridge on :3000 for the gateway. With
# `--login` the entrypoint hands over to the upstream supervisor instead, so
# the guided browser sign-in gets a display and the noVNC viewer.
ENTRYPOINT ["/opt/cerase/entrypoint.sh"]
