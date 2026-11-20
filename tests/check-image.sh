#!/bin/bash
set -euo pipefail

image=${1:?usage: check-image.sh <image>}

container=li-check
normal_container=li-check-normal
prefs_container=li-check-prefs
volume=li-check-vol-$$
prefs_volume=li-check-prefs-vol-$$
browser_volume=li-check-browser-vol-$$
page=$(mktemp)

cleanup() {
    docker rm -f "$container" "$normal_container" "$prefs_container" >/dev/null 2>&1 || true
    docker volume rm -f "$volume" "$prefs_volume" "$browser_volume" >/dev/null 2>&1 || true
    rm -f "$page"
}
trap cleanup EXIT

fail() {
    printf 'check-image: %s\n' "$1" >&2
    exit 1
}

relative='location\.pathname\.replace.*websockify\?token='

# The viewer page must build its WebSocket address relative to the page, so it
# still works behind the console's /connector-login/<token>/ prefix. The page
# is served under that prefix unchanged, so the string assertions below are
# what prove the prefixed case: the path is derived from location.pathname and
# no root-relative WebSocket path remains.
viewer=$(docker run --rm --entrypoint cat "$image" /usr/share/novnc/login.html) ||
    fail "cannot read /usr/share/novnc/login.html from $image"
grep -qE "$relative" <<<"$viewer" ||
    fail "login.html does not build its WebSocket path relative to the page"
if grep -qF '${location.host}/websockify' <<<"$viewer"; then
    fail "login.html still builds a root WebSocket path"
fi

# The guided login must serve the viewer under the console's runner limits and
# keep the profile on the mounted volume.
docker rm -f "$container" >/dev/null 2>&1 || true
docker volume rm -f "$volume" >/dev/null 2>&1 || true
docker volume create "$volume" >/dev/null || fail "cannot create the profile volume"

docker run -d --name "$container" \
    --read-only --tmpfs /tmp:rw,nosuid,nodev,size=256m \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 1g -v "$volume:/home/pwuser/.linkedin-mcp" \
    -p 127.0.0.1:6080:6080 \
    "$image" --login --login-viewer >/dev/null ||
    fail "cannot start the login viewer"

ready=0
for _ in $(seq 1 60); do
    if curl -sf http://127.0.0.1:6080/login.html -o "$page"; then
        ready=1
        break
    fi
    if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
        docker logs "$container" >&2 || true
        fail "the login viewer container exited before serving the page"
    fi
    sleep 1
done
if [[ $ready -ne 1 ]]; then
    docker logs "$container" >&2 || true
    fail "the login viewer did not answer within 60 s"
fi

grep -qE "$relative" "$page" ||
    fail "the served login page does not build its WebSocket path relative to the page"
if grep -qF '${location.host}/websockify' "$page"; then
    fail "the served login page still builds a root WebSocket path"
fi

logs=$(docker logs "$container" 2>&1) || fail "cannot read the login viewer logs"
grep -qF 'http://127.0.0.1:6080/' <<<"$logs" ||
    fail "the login viewer did not print its loopback URL"

# The login profile must not offer to store the LinkedIn password.
if ! docker exec -i "$container" python - <<'PY'
import json
import sys

path = "/home/pwuser/.linkedin-mcp/profile/Default/Preferences"
try:
    with open(path, encoding="utf-8") as stream:
        preferences = json.load(stream)
except (OSError, ValueError) as exc:
    print(f"cannot read {path}: {exc}", file=sys.stderr)
    sys.exit(1)
if preferences.get("credentials_enable_service") is not False:
    print("credentials_enable_service is not false", file=sys.stderr)
    sys.exit(1)
profile = preferences.get("profile")
if not isinstance(profile, dict) or profile.get("password_manager_enabled") is not False:
    print("profile.password_manager_enabled is not false", file=sys.stderr)
    sys.exit(1)
PY
then
    fail "the login profile does not disable the password manager"
fi

# The login browser window must fill the virtual screen, not sit at Chromium's
# default size inside it. The Xvfb screen and the largest X window are read
# through libX11 because the image carries no xwininfo or xdotool.
if ! docker exec -i -e DISPLAY=:99 "$container" python - <<'PY'
import ctypes
import sys

x = ctypes.CDLL("libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XQueryTree.argtypes = [
    ctypes.c_void_p,
    ctypes.c_ulong,
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
    ctypes.POINTER(ctypes.c_uint),
]
x.XGetGeometry.argtypes = [
    ctypes.c_void_p,
    ctypes.c_ulong,
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_uint),
    ctypes.POINTER(ctypes.c_uint),
    ctypes.POINTER(ctypes.c_uint),
    ctypes.POINTER(ctypes.c_uint),
]
x.XFree.argtypes = [ctypes.c_void_p]

display = x.XOpenDisplay(None)
if not display:
    print("cannot open the X display", file=sys.stderr)
    sys.exit(1)
root = x.XDefaultRootWindow(display)


def geometry(window):
    root_return = ctypes.c_ulong()
    x_return = ctypes.c_int()
    y_return = ctypes.c_int()
    width = ctypes.c_uint()
    height = ctypes.c_uint()
    border = ctypes.c_uint()
    depth = ctypes.c_uint()
    if not x.XGetGeometry(
        display,
        window,
        ctypes.byref(root_return),
        ctypes.byref(x_return),
        ctypes.byref(y_return),
        ctypes.byref(width),
        ctypes.byref(height),
        ctypes.byref(border),
        ctypes.byref(depth),
    ):
        return None
    return width.value, height.value


screen = geometry(root)
if screen is None:
    print("cannot read the X root window", file=sys.stderr)
    sys.exit(1)

largest = None


def walk(window, depth=0):
    global largest
    size = geometry(window)
    if size is not None and depth > 0:
        if largest is None or size[0] * size[1] > largest[0] * largest[1]:
            largest = size
    root_return = ctypes.c_ulong()
    parent_return = ctypes.c_ulong()
    children = ctypes.POINTER(ctypes.c_ulong)()
    count = ctypes.c_uint()
    if x.XQueryTree(
        display,
        window,
        ctypes.byref(root_return),
        ctypes.byref(parent_return),
        ctypes.byref(children),
        ctypes.byref(count),
    ):
        for index in range(count.value):
            walk(children[index], depth + 1)
        if children:
            x.XFree(children)


walk(root)
if largest is None:
    print("no browser window found", file=sys.stderr)
    sys.exit(1)
print(f"Xvfb screen {screen[0]}x{screen[1]}, browser window {largest[0]}x{largest[1]}")
if abs(largest[0] - screen[0]) > 2 or abs(largest[1] - screen[1]) > 2:
    print("the browser window does not match the Xvfb screen", file=sys.stderr)
    sys.exit(1)
PY
then
    fail "the browser window does not fill the Xvfb screen"
fi

docker rm -f "$container" >/dev/null 2>&1 || true
docker volume rm -f "$volume" >/dev/null 2>&1 || true

# A profile that already holds settings keeps them when the login writes the
# password-manager switches into the fresh profile.
docker volume create "$prefs_volume" >/dev/null || fail "cannot create the preferences volume"
docker run --rm -v "$prefs_volume:/home/pwuser/.linkedin-mcp" --entrypoint bash "$image" -c \
    'mkdir -p /home/pwuser/.linkedin-mcp/profile/Default && printf "%s\n" "{\"unrelated\":\"keep-me\",\"profile\":{\"other\":\"keep\"}}" > /home/pwuser/.linkedin-mcp/profile/Default/Preferences && chmod 600 /home/pwuser/.linkedin-mcp/profile/Default/Preferences' ||
    fail "cannot seed the preferences volume"

docker run -d --name "$prefs_container" \
    --read-only --tmpfs /tmp:rw,nosuid,nodev,size=256m \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 1g -v "$prefs_volume:/home/pwuser/.linkedin-mcp" \
    -p 127.0.0.1:6081:6080 \
    "$image" --login --login-viewer >/dev/null ||
    fail "cannot start the login viewer with an existing Preferences file"

prefs_ready=0
for _ in $(seq 1 60); do
    if curl -sf http://127.0.0.1:6081/login.html -o /dev/null; then
        prefs_ready=1
        break
    fi
    if ! docker inspect -f '{{.State.Running}}' "$prefs_container" 2>/dev/null | grep -qx true; then
        docker logs "$prefs_container" >&2 || true
        fail "the login viewer with an existing Preferences file exited early"
    fi
    sleep 1
done
if [[ $prefs_ready -ne 1 ]]; then
    docker logs "$prefs_container" >&2 || true
    fail "the login viewer with an existing Preferences file did not answer within 60 s"
fi

if ! docker exec -i "$prefs_container" python - <<'PY'
import json
import sys

path = "/home/pwuser/.linkedin-mcp/profile/Default/Preferences"
with open(path, encoding="utf-8") as stream:
    preferences = json.load(stream)
profile = preferences.get("profile")
if preferences.get("unrelated") != "keep-me":
    print("the unrelated top-level key was lost", file=sys.stderr)
    sys.exit(1)
if not isinstance(profile, dict) or profile.get("other") != "keep":
    print("the unrelated profile key was lost", file=sys.stderr)
    sys.exit(1)
if preferences.get("credentials_enable_service") is not False:
    print("credentials_enable_service is not false", file=sys.stderr)
    sys.exit(1)
if profile.get("password_manager_enabled") is not False:
    print("profile.password_manager_enabled is not false", file=sys.stderr)
    sys.exit(1)
PY
then
    fail "the login profile did not keep the existing Preferences"
fi

docker rm -f "$prefs_container" >/dev/null 2>&1 || true
docker volume rm -f "$prefs_volume" >/dev/null 2>&1 || true

# Under the runner's limits, the headless browser must start with its profile
# in the state volume and open a page.
docker volume create "$browser_volume" >/dev/null || fail "cannot create the browser-test volume"
if ! docker run --rm -i \
    --read-only --tmpfs /tmp:rw,nosuid,nodev,size=256m \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 1g -v "$browser_volume:/home/pwuser/.linkedin-mcp" \
    --entrypoint python "$image" - >/dev/null <<'PY'
import asyncio
from patchright.async_api import async_playwright


async def main():
    async with async_playwright() as playwright:
        context = await playwright.chromium.launch_persistent_context(
            "/home/pwuser/.linkedin-mcp/profile",
            channel="chromium",
            headless=True,
            viewport={"width": 1280, "height": 720},
        )
        page = context.pages[0] if context.pages else await context.new_page()
        await page.goto("about:blank")
        if page.url != "about:blank":
            raise SystemExit(f"unexpected page {page.url}")
        await context.close()


asyncio.run(main())
PY
then
    fail "headless Chromium does not start under the runner flags"
fi
docker volume rm -f "$browser_volume" >/dev/null 2>&1 || true

# With no arguments the image is still the runner: gate, bridge and server,
# with no login mode in the process or the logs.
docker rm -f "$normal_container" >/dev/null 2>&1 || true
docker run -d --name "$normal_container" "$image" >/dev/null ||
    fail "cannot start the image without arguments"

sleep 20

running=$(docker inspect -f '{{.State.Running}}' "$normal_container" 2>/dev/null) ||
    fail "the container started without arguments disappeared"
if [[ $running != true ]]; then
    docker logs "$normal_container" >&2 || true
    fail "the container started without arguments is not running after 20 s"
fi

normal_logs=$(docker logs "$normal_container" 2>&1) ||
    fail "cannot read the logs of the container started without arguments"
if grep -q -- '--login' <<<"$normal_logs"; then
    fail "the container started without arguments mentions --login in its logs"
fi
