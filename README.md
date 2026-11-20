# linkedin-mcp

A Cerase image connector for the third-party
[stickerdaniel/linkedin-mcp-server](https://github.com/stickerdaniel/linkedin-mcp-server).
No upstream code is copied into this repository. The upstream image is the base;
this repository adds the runner gate, the liveness probe and the stdio-to-HTTP
bridge that Cerase expects from an `image` connector.

## Status

Installable on Cerase 0.4.12 or later. Each person signs in to their own LinkedIn account from the Cerase console, which runs the image with `--login --login-viewer` and keeps the session in `/home/pwuser/.linkedin-mcp`.

This package is not endorsed by or affiliated with
LinkedIn or with the upstream author. You log in with your own LinkedIn session,
and LinkedIn's terms may restrict automated access. Use it only on an account
you are allowed to automate.

## Upstream

The packaged server is
[stickerdaniel/linkedin-mcp-server](https://github.com/stickerdaniel/linkedin-mcp-server),
licensed under the Apache License, Version 2.0. The licence text is in
[LICENSE](LICENSE), and [NOTICE](NOTICE) records the attribution.

The Dockerfile pins the upstream image by digest. That digest is the `latest` tag
as published on 2026-11-04.

## Logging in

The server needs a LinkedIn browser session. The upstream image keeps that
session in `/home/pwuser/.linkedin-mcp`. Its login flow opens a browser on a
virtual display and serves a noVNC page so a person can complete LinkedIn's login
there; the session is then reused from that directory.

Cerase runs the image once with `--login --login-viewer` and shows the viewer page in the console. The image patches noVNC's `vnc_lite.html` so the WebSocket address is built from the page's own location, which lets the viewer work behind the console's path prefix. Without arguments the image is the MCP runner.

To try the login outside Cerase, run the upstream image with a host directory
mounted at `/home/pwuser/.linkedin-mcp`, complete the login through the viewer,
and keep that directory for later runs. The upstream README gives the exact
command and the viewer port.

## Image

The publish workflow pushes `ghcr.io/bartolomeo-roberti/linkedin-mcp` with the
tags `main` and `sha-<short>`.

`cerase.json` pins the image published by the first run, `ghcr.io/bartolomeo-roberti/linkedin-mcp@sha256:516d145bcddb9a9bec0222528b9e2b888731f33e73ea868a48a802513b70b1f8`. After a new publish, copy the new digest from the workflow summary into `cerase.json`.

The manifest lists the hosts the runner may reach: `linkedin.com`, `*.linkedin.com` and `*.licdn.com`.

## Files copied from Cerase

`scripts/runner-gate.py` and `scripts/healthcheck.py` are verbatim copies from
`cerase-core/agent-runtime/mcp-runner/docker/`. They must be refreshed together
when the originals change; do not edit them here.

## Build

```sh
docker build -t linkedin-mcp .
```

The image exposes port 3000 for the gateway. The bridge listens on
`127.0.0.1:3001` behind the gate, and the server runs with `HEADLESS=true`
because a Cerase runner has no display.
