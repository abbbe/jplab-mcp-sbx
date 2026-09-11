#!/usr/bin/env bash
# The desktop: one X server that speaks RFB natively, a window manager, and
# noVNC in front of it.
#
# Descended from abbbe/sbx-workspace bin/svc/novnc.sh by way of an Xvfb+x11vnc
# version of this file.  That pairing worked, but it could not resize: Xvfb's
# framebuffer ceiling is welded on at startup by -screen, and x11vnc has no
# SetDesktopSize hook at all -- libvncserver carries the protocol machinery,
# the x11vnc binary has no matching symbol -- so a viewer asking for a
# different size was simply refused.  The desktop was 1920x1080 and you scaled
# it in the browser and squinted.  TigerVNC's Xvnc is the same X server and the
# VNC server in one process, honours SetDesktopSize, and reports a RandR
# maximum of 32768x32768, so the browser window drives the desktop size and
# there is no ceiling to pick in advance.
#
# THREE PROCESSES, ONE SERVICE, AND THE TWO REPLACEABLE ONES ARE KEPT ALIVE
# INDEPENDENTLY.  Only Xvnc is fatal: the window manager and the websocket
# bridge both draw on it or forward it, so if one of those dies it is restarted
# in place and nobody else hears about it.  An earlier version supervised only
# the X server, and the result was the worst kind of failure -- the VNC half
# would die, the service still looked "running" because the supervisor was
# alive, the noVNC page still loaded because websockify serves it, and the
# browser said "Failed to connect to server" with nothing anywhere explaining
# why.  A service is only up if the thing it exists to do still works.  Folding
# the VNC server into the X server removes that failure mode by construction:
# there is no longer a VNC half that can die on its own.
#
# WHY -ac, AND WHY THAT IS NOT AS ALARMING AS IT LOOKS.  Access control is off so
# that an X client in a DIFFERENT CONTAINER -- a pinned toolchain image, say,
# started with `-v /tmp/.X11-unix:/tmp/.X11-unix -e DISPLAY=:1` -- can draw here
# without sharing a cookie file across containers.  What makes that safe is the
# pairing with -nolisten tcp: the server has no X network socket at all, so the
# only way in is the unix socket you deliberately bind-mount.  Measured on
# Xvnc 1.15: with -nolisten tcp it listens on 5900 and nothing else, and it
# still creates /tmp/.X11-unix/X1 exactly as Xvfb did.  The RFB port is
# loopback-only and still demands the password.  Do not add TCP listening to
# this without removing -ac in the same edit.
set -uo pipefail

: "${DISPLAY:=:1}"
# The size the desktop STARTS at, not the size it is stuck with.  A viewer that
# supports SetDesktopSize -- noVNC with resize=remote, any current native
# client -- replaces this the moment it connects.  It still matters for
# anything that runs before a human shows up: the agent starting a GUI
# headlessly, screenshots, `desktopctl resize`.
: "${VNC_GEOMETRY:=1920x1080}"
: "${VNC_DEPTH:=24}"
: "${NOVNC_PORT:=6080}"

export DISPLAY

# WAYLAND_DISPLAY MUST BE UNSET, AND THIS IS NOT A WORKAROUND -- it is a lie
# being corrected.  An sbx sandbox exports WAYLAND_DISPLAY=wayland-0 into every
# process, and some X clients treat that variable alone as proof of a Wayland
# session without ever looking at $DISPLAY.  x11vnc 0.9.17 did exactly that --
# it printed "Wayland display server detected ... Exiting" and returned 1
# against a perfectly real X display -- which cost an evening before it was
# found.  Xvnc itself does NOT sniff the variable (measured: it starts fine
# with it set), so this line no longer protects the service.  It stays because
# it is inherited by fluxbox and by every GUI program started on this display,
# which is where the lie still does damage.
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

VNCDIR="$HOME/.vnc"
STATE="${DESKTOP_STATE:-$HOME/.local/state/desktop}"
mkdir -p "$VNCDIR" "$STATE"

# ONE TOKEN PER SANDBOX, shared with every other kit in this repo. Whichever
# kit's install step ran first created it.  Note the RFB protocol truncates the
# password to 8 characters and throws the rest away -- vncpasswd does that
# itself, silently -- so the desktop is only ever protected by the first 8,
# which is why its port belongs on 127.0.0.1 and nowhere else.
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
#     stops when Xvnc does, so the outer loop gets a clean exit rather than a
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

    # The component's own output goes into the service log, prefixed so the
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
        while kill -0 "$xserver_pid" 2>/dev/null; do
            "$@" >&3 2>&3
            rc=$?
            kill -0 "$xserver_pid" 2>/dev/null || break
            echo "[desktop] $name exited rc=$rc; restarting"
            sleep 2
        done
    ) &
}

# One full life of the desktop: bring up Xvnc, hang the other two off it, and
# return when Xvnc dies.  The outer loop below decides whether to try again.
run_desktop() {
    # THE PASSWORD FILE MUST EXIST BEFORE THE SERVER STARTS, which is the one
    # ordering difference from the x11vnc version -- there, the VNC server was a
    # separate process started after the display and could be handed its
    # password at that point.  Xvnc reads -rfbauth during its own startup, so a
    # missing file is a fatal server error rather than a failed component.
    #
    # vncpasswd -f reads the plaintext on stdin and writes the obfuscated form
    # on stdout.  Measured: it accepts a token longer than 8 characters without
    # a word of complaint, truncates it, and produces a file BYTE-IDENTICAL to
    # the one `x11vnc -storepasswd` used to write -- so this is a drop-in swap
    # and an existing ~/.vnc/passwd keeps working.
    # The subshell scopes the umask: set bare, it would be inherited by fluxbox,
    # by websockify, and by every GUI program started on this display for the
    # rest of the service's life.  And note the redirection does NOT merge
    # stderr -- `> file 2>&1` here would write any warning vncpasswd ever prints
    # INTO the password file, corrupting it in a way that reads as a wrong
    # password.  Its stderr belongs in the service log with everything else.
    ( umask 077; printf '%s\n' "$(cat "$TOKEN_FILE")" | vncpasswd -f > "$VNCDIR/passwd" )
    chmod 600 "$VNCDIR/passwd" 2>/dev/null
    if [[ ! -s "$VNCDIR/passwd" ]]; then
        # Never fall back to -SecurityTypes None: a desktop that quietly stops
        # requiring a password because its password file failed to write is
        # worse than one that does not start.
        echo "!!! $VNCDIR/passwd is missing or empty; refusing to start" >&2
        return 1
    fi

    echo "=== Xvnc on $DISPLAY (${VNC_GEOMETRY}x${VNC_DEPTH}), RFB on 127.0.0.1:5900 ==="
    # -AcceptSetDesktopSize is the entire point of this kit's TigerVNC rebuild:
    #   it is what lets the browser window drive the desktop size.  It defaults
    #   to on; it is spelled out here so nobody "cleans up" the flag that makes
    #   resizing work.
    # -AlwaysShared reproduces x11vnc's -shared.  Without it TigerVNC's default
    #   DisconnectClients kicks the existing viewer off when a second one
    #   connects, which for a desktop you might have open in two tabs reads as a
    #   random disconnect.
    # -MaxIdleTime/-MaxDisconnectionTime/-MaxConnectionTime all default to 0
    #   already.  They are pinned because every one of them is a timer that
    #   TERMINATES THE SERVER, and a non-zero default arriving in some future
    #   version would show up as a desktop that mysteriously dies overnight.
    Xvnc "$DISPLAY" \
        -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" \
        -rfbport 5900 -localhost \
        -SecurityTypes VncAuth -rfbauth "$VNCDIR/passwd" \
        -AcceptSetDesktopSize=1 -AlwaysShared \
        -MaxIdleTime=0 -MaxDisconnectionTime=0 -MaxConnectionTime=0 \
        -desktop "sbx" -ac -nolisten tcp &
    xserver_pid=$!

    # Wait for the server to accept clients rather than sleeping a guessed
    # interval.  A GUI started against a not-yet-listening display fails in ways
    # that read as application bugs.
    local _
    for _ in $(seq 1 60); do
        xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
        sleep 0.25
    done
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo "!!! Xvnc never accepted a connection on $DISPLAY" >&2
        kill "$xserver_pid" 2>/dev/null
        return 1
    fi
    echo "=== display ready ==="

    xsetroot -solid grey20 2>/dev/null || true

    echo "=== window manager ==="
    keep_alive fluxbox fluxbox

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
    wait "$xserver_pid"
    echo "!!! Xvnc exited -- the desktop is gone" >&2
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
