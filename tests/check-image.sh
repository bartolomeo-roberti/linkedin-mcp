#!/bin/bash
set -euo pipefail

image=${1:?usage: check-image.sh <image>}

container=li-check
normal_container=li-check-normal
volume=li-check-vol-$$
page=$(mktemp)

cleanup() {
    docker rm -f "$container" "$normal_container" >/dev/null 2>&1 || true
    docker volume rm -f "$volume" >/dev/null 2>&1 || true
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

docker rm -f "$container" >/dev/null 2>&1 || true
docker volume rm -f "$volume" >/dev/null 2>&1 || true

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
