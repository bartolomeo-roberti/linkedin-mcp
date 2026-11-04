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
# loopback and the gate exposes that bridge on :3000 for the gateway.
ENTRYPOINT ["python3", "/opt/cerase/runner-gate.py", "--", "/opt/bridge/bin/mcp-proxy", \
    "--port", "3001", "--host", "127.0.0.1", "--pass-environment", "--", \
    "python", "-m", "linkedin_mcp_server"]
