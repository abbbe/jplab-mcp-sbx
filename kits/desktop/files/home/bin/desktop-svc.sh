#!/usr/bin/env bash
# The desktop: Xvfb, a window manager, a VNC server, and noVNC in front of it.
#
# Ported from abbbe/sbx-workspace bin/svc/novnc.sh. Four things in here were
# each paid for with an evening; every one of them is commented where it sits,
# and none of them should be "cleaned up".
#
# FOUR PROCESSES, ONE SERVICE, AND EACH OF THE THREE REPLACEABLE ONES IS KEPT
# ALIVE INDEPENDENTLY.  Only Xvfb is fatal: everything else draws on it or
# forwards it, so if one of those dies it is restarted in place and nobody else
# hears about it.  An earlier version supervised only Xvfb, and the result was
# the worst kind of failure -- x11vnc would die, the service still looked
# "running" because the supervisor was alive, the noVNC page still loaded
# because websockify serves it, and the browser said "Failed to connect to
# server" with nothing anywhere explaining why.  A service is only up if the
# thing it exists to do still works.
#
# WHY -ac, AND WHY THAT IS NOT AS ALARMING AS IT LOOKS.  Access control is off so
# that an X client in a DIFFERENT CONTAINER -- a pinned toolchain image, say,
# started with `-v /tmp/.X11-unix:/tmp/.X11-unix -e DISPLAY=:1` -- can draw here
# without sharing a cookie file across containers.  What makes that safe is the
# pairing with -nolisten tcp: the server has no network socket at all, so the
# only way in is the unix socket you deliberately bind-mount.  x11vnc still
# binds loopback only and still demands the password.  Do not add TCP listening
# to this without removing -ac in the same edit.
set -uo pipefail

: "${DISPLAY:=:1}"
: "${VNC_GEOMETRY:=1920x1080}"
: "${VNC_DEPTH:=24}"
: "${NOVNC_PORT:=6080}"

export DISPLAY

# WAYLAND_DISPLAY MUST BE UNSET, AND THIS IS NOT A WORKAROUND -- it is a lie
# being corrected.  An sbx sandbox exports WAYLAND_DISPLAY=wayland-0 into every
# process, and x11vnc 0.9.17 treats that variable alone as proof of a Wayland
# session: it prints "Wayland display server detected ... Exiting" and returns 1
# WITHOUT EVER LOOKING AT -display, even though the display it was handed is a
# perfectly real Xvfb.  Measured by flipping one variable both ways;
# XDG_SESSION_TYPE=wayland does NOT trigger it, so this is the whole cause.
#
# What that produced before it was found: x11vnc exiting 1 in a restart loop
# forever, nothing on 5900, the noVNC page still served by websockify, and
# "Failed to connect to server" in the browser as the only symptom.
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

VNCDIR="$HOME/.vnc"
STATE="${DESKTOP_STATE:-$HOME/.local/state/desktop}"
mkdir -p "$VNCDIR" "$STATE"

# ONE TOKEN PER SANDBOX, shared with every other kit in this repo. Whichever
# kit's install step ran first created it.  Note the RFB protocol truncates the
# password to 8 characters and throws the rest away -- x11vnc -storepasswd does
# that itself -- so the desktop is only ever protected by the first 8, which is
# why its port belongs on 127.0.0.1 and nowhere else.
TOKEN_FILE=${SBX_TOKEN_FILE:-$HOME/.sbx-token}
if [[ ! -s "$TOKEN_FILE" ]]; then
    echo "!!! $TOKEN_FILE is missing or empty; refusing to start an unauthenticated desktop" >&2
    exit 1
fi

# A DEFINED BACKGROUND, rather than whatever the default style decodes.  Note
# what this does NOT do: it does not stop fluxbox calling fbsetbg.  Measured --
# with session.screen0.rootCommand set, fbsetbg still ran and still popped its
# "I can't find an app to set the wallpaper with" dialog, and a `background:
# none` overlay did not suppress it either.  Installing feh is what actually
# fixes that (see spec.yaml); this block only pins the colour.  The kit also
# ships ~/.fluxbox/init, so this is the standalone-run fallback.
FBDIR="$HOME/.fluxbox"
mkdir -p "$FBDIR"
if [[ ! -e "$FBDIR/init" ]]; then
    echo 'session.screen0.rootCommand: xsetroot -solid grey20' > "$FBDIR/init"
fi

# keep_alive NAME COMMAND...
#     Restart one replaceable component for as long as the display lives.  It
#     stops when Xvfb does, so the outer loop gets a clean exit rather than a
#     pile of orphans respawning against a dead display.
#
# THE LOOP WAITS ON THE PROCESS, NEVER ON A PIPELINE.  Writing the prefixer as
# `"$@" 2>&1 | sed ...` reads naturally and is a trap: the shell then waits for
# the PIPELINE, so ANY GRANDCHILD that inherited the pipe keeps it open long
# after the component itself is gone.  fluxbox does exactly that -- fbsetbg
# cannot find a wallpaper setter and leaves an xmessage dialog running -- so the
# window manager died, sed never saw EOF, and this loop blocked FOREVER with
# nothing in the log to say so.  Measured: fluxbox killed with SIGABRT, no
# restart and no log line; killing the stray xmessage by hand released the loop
# and fluxbox came straight back.  The desktop was therefore dead on its first
# crash in every sandbox built from the template that had this bug.
#
# One long-lived prefixer per component, fed through a FIFO, keeps the readable
# log without letting a grandchild's lifetime decide the loop's.
keep_alive() {
    local name=$1; shift
    local fifo="$STATE/$name.fifo"
    rm -f "$fifo"
    mkfifo -m 600 "$fifo"

    # The component's own output goes into the service log, prefixed so three
    # interleaved streams stay readable.  An earlier version sent it to
    # /dev/null, which meant a component that could not start at all reported
    # only "exited rc=1; restarting" forever -- the supervisor saying THAT it
    # failed while discarding the one line saying WHY.  That cost an evening on
    # the Wayland check above.
    sed -u "s/^/[$name] /" < "$fifo" &

    (
        # fd 3 stays open for the whole loop, so the prefixer never sees EOF
        # between restarts and never needs restarting itself.
        exec 3>"$fifo"
        while kill -0 "$xvfb_pid" 2>/dev/null; do
            "$@" >&3 2>&3
            rc=$?
            kill -0 "$xvfb_pid" 2>/dev/null || break
            echo "[desktop] $name exited rc=$rc; restarting"
            sleep 2
        done
    ) &
}

# One full life of the desktop: bring up Xvfb, hang the other three off it, and
# return when Xvfb dies.  The outer loop below decides whether to try again.
run_desktop() {
    echo "=== Xvfb on $DISPLAY (${VNC_GEOMETRY}x${VNC_DEPTH}) ==="
    Xvfb "$DISPLAY" -screen 0 "${VNC_GEOMETRY}x${VNC_DEPTH}" -ac -nolisten tcp &
    xvfb_pid=$!

    # Wait for the server to accept clients rather than sleeping a guessed
    # interval.  A GUI started against a not-yet-listening display fails in ways
    # that read as application bugs.
    local _
    for _ in $(seq 1 60); do
        xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
        sleep 0.25
    done
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo "!!! Xvfb never accepted a connection on $DISPLAY" >&2
        kill "$xvfb_pid" 2>/dev/null
        return 1
    fi
    echo "=== display ready ==="

    # x11vnc wants the password in a file rather than on the command line, where
    # it would be visible in ps to every process in the sandbox.
    #
    # -quiet is deliberately NOT used.  It suppresses fatal startup errors and
    # not merely per-connection chatter: with -quiet, the Wayland refusal above
    # prints NOTHING AT ALL and x11vnc just exits 1.  Measured.  Per-connection
    # noise is worth paying for a log that says why a service will not start.
    x11vnc -storepasswd "$(cat "$TOKEN_FILE")" "$VNCDIR/passwd" 2>&1 | sed "s/^/[storepasswd] /"
    chmod 600 "$VNCDIR/passwd" 2>/dev/null
    if [ ! -s "$VNCDIR/passwd" ]; then
        # -rfbauth against a missing or empty file fails on every attempt, which
        # looks identical to the Wayland failure from outside.  Say which it is.
        # Never fall back to -nopw: a desktop that quietly stops requiring a
        # password because its password file failed to write is worse than one
        # that does not start.
        echo "!!! $VNCDIR/passwd is missing or empty; x11vnc cannot authenticate" >&2
        kill "$xvfb_pid" 2>/dev/null
        return 1
    fi

    xsetroot -solid grey20 2>/dev/null || true

    echo "=== window manager ==="
    keep_alive fluxbox fluxbox

    echo "=== x11vnc (loopback only, password required) ==="
    keep_alive x11vnc \
        x11vnc -display "$DISPLAY" -forever -shared -localhost \
               -rfbauth "$VNCDIR/passwd" -rfbport 5900

    # WEBSOCKIFY MUST BE GIVEN [::], NOT 0.0.0.0 AND NOT A BARE PORT.
    #
    # A kit-declared port is published on BOTH address families -- the schema
    # accepts only "tcp" or "udp" there, never "tcp4" -- so sbx creates
    # 127.0.0.1:<ephemeral> AND ::1:<ephemeral>.  macOS resolves localhost to
    # ::1 first, so a v4-only listener in here means the host side accepts and
    # then forwards into nothing.  Same class of bug as jupyter-svc.sh's
    # --ip='*' (which is likewise NOT 0.0.0.0).
    #
    # A BARE PORT DOES NOT FIX IT, though it looks like it should: websockify's
    # getaddrinfo picks the IPv4 wildcard.  Measured in a live sandbox --
    # `websockify ... 6080` gives `0.0.0.0:6080` and no v6 socket at all, and
    # curl to [::1]:6080 fails while 127.0.0.1:6080 returns 200.
    #
    # `[::]` binds one v6 socket that also accepts v4-mapped connections
    # (bindv6only=0 in this image).  Measured on the same sandbox: `[::]:6081`
    # shows a single `:::6081` listener and BOTH 127.0.0.1 and [::1] return 200.
    # Note netstat shows only the tcp6 line for a dual-stack socket -- that is
    # correct, not half a bind.
    echo "=== noVNC on :$NOVNC_PORT ==="
    keep_alive websockify \
        websockify --web=/usr/share/novnc "[::]:$NOVNC_PORT" 127.0.0.1:5900

    # Wait on the X server alone.  Everything above is replaceable while it lives.
    wait "$xvfb_pid"
    echo "!!! Xvfb exited -- the desktop is gone" >&2
    return 0
}

# The outer restart loop, in the same register as jupyter-svc.sh: a desktop that
# ran for a while and then died is a transient fault and should come straight
# back; one that dies immediately is misconfigured, and backing off is the only
# way to keep the log readable.  There is no supervise.sh in this world -- the
# startup dispatcher runs this script once and never looks again.
delay=1
while true; do
    start=$SECONDS
    run_desktop
    rc=$?
    (( SECONDS - start > 30 )) && delay=1
    echo "[desktop] exited rc=$rc after $((SECONDS-start))s; restart in ${delay}s" >&2
    sleep "$delay"
    (( delay = delay * 2 )); (( delay > 60 )) && delay=60
done
