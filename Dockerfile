# The LinkedIn connector, built on the upstream image.
#
# The base is stickerdaniel/linkedin-mcp-server, which already carries the
# server, its Python environment and the browser it drives. Pinned by digest
# because a tag on Docker Hub can be re-pushed; the digest is the `latest` tag
# as published on 2026-11-04. To move the version, change the tag and the digest
# together and keep the catalogue entry unchanged.
FROM docker.io/stickerdaniel/linkedin-mcp-server@sha256:8f6b618b9965eb3eb12dd27df861f019ab621a78b408a9b7cd4aaef62954ce97 AS runtime

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

EXPOSE 3000

ENV CERASE_HEALTHCHECK_URL=http://127.0.0.1:3001/mcp

HEALTHCHECK --interval=5m --start-interval=5s --timeout=10s --start-period=60s --retries=2 \
    CMD python3 /opt/cerase/runner-gate.py --probe && python3 /opt/cerase/healthcheck.py || exit 1

# The upstream server speaks MCP over stdio. mcp-proxy bridges it to HTTP on
# loopback and the gate exposes that bridge on :3000 for the gateway. With
# `--login` the entrypoint hands over to the upstream supervisor instead, so
# the guided browser sign-in gets a display and the noVNC viewer.
ENTRYPOINT ["/opt/cerase/entrypoint.sh"]
