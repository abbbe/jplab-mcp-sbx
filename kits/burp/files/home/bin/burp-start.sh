#!/usr/bin/env bash
# Start Burp Suite Professional on the virtual desktop, on demand.
#
# ON DEMAND, NOT SUPERVISED, AND THAT IS DELIBERATE.  Burp is a 2-4GB JVM that
# most sessions in this sandbox do not want, and a mixin cannot raise the
# sandbox's memory limit (only `sbx run -m` can).  So there is no startup entry
# and no restart loop: you start it when you need it, and if it dies you find
# out from burp.log rather than from a supervisor quietly relaunching it.
#
# THE UPSTREAM PROXY IS THE WHOLE BALL GAME.  Every sbx sandbox has HTTPS_PROXY
# set and sbx terminates TLS with its own certificate; bypassing it with
# NO_PROXY yields EOF because the policy drops the direct connection (measured,
# see abbbe/sbx-workspace README).  A JVM ignores HTTP_PROXY/HTTPS_PROXY
# entirely, so without the upstream-proxy block written into Burp's user config
# below, EVERY request Burp sends fails -- with an error that names nothing
# relevant.  If you change one thing in this file, do not change that.
set -uo pipefail

DIST=${BURP_DIST:-/opt/burp/dist}
STATE=${BURP_STATE:-/opt/burp/state}
JAR="$DIST/burpsuite_pro.jar"
PROXY_PORT=${BURP_PROXY_PORT:-8080}
API_PORT=${BURP_API_PORT:-8081}
LOG="$STATE/burp.log"

: "${DISPLAY:=:1}"
export DISPLAY
# See desktop-svc.sh: sbx exports WAYLAND_DISPLAY=wayland-0 into every process
# and some toolkits treat that alone as proof of a Wayland session.
unset WAYLAND_DISPLAY

die() { echo "burp-start: $*" >&2; exit 1; }

port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# --- 1. Refuse to double-start -------------------------------------------
# A second Burp loses the race for port 8080 and reports it as its own failure,
# which reads as "Burp is broken" rather than "Burp is already running".
if pid=$(pgrep -f 'burpsuite_pro\.jar' | head -1) && [ -n "$pid" ]; then
    echo "Burp is already running (pid $pid)."
    echo "  proxy :$PROXY_PORT  bridge api :$API_PORT   log: $LOG"
    exit 0
fi

# --- 2. Validate the staging ----------------------------------------------
# This is the most likely misconfiguration in the whole kit, so it gets the
# best error message in it.
if [ ! -f "$JAR" ]; then
    cat >&2 <<EOF
burp-start: no Burp jar at $JAR

The Burp jar and the MCP bridge are staged on the HOST and mounted in; they are
not part of this kit (PortSwigger's download needs your account, so nothing here
can fetch it for you).

On the host, once:
    ./kits/burp/stage-burp.sh --jar /path/to/burpsuite_pro_v2026.8.jar

Then recreate the sandbox with BOTH the mounts and the matching kit args, e.g.
    sbx run --detached claude --name burpbox . \\
        \$HOME/.sbx/burp/dist:ro \$HOME/.sbx/burp/state \\
        --kit .../kits/jupyter --kit .../kits/desktop --kit .../kits/burp \\
        --kit-arg sbx-burp.dist=\$HOME/.sbx/burp/dist \\
        --kit-arg sbx-burp.state=\$HOME/.sbx/burp/state \\
        -m 8g -p 8888:8888 -p 6080:6080 -p 8080:8080

An additional workspace mounts at its IDENTICAL host path, and the kit has no
way to read the mount table -- which is why the same path is typed twice.

Currently: BURP_DIST=$DIST  BURP_STATE=$STATE
EOF
    exit 1
fi
[ -d "$STATE" ] || die "state directory $STATE does not exist (mount it read-write)"
[ -w "$STATE" ] || die "state directory $STATE is not writable (do not mount it :ro)"
mkdir -p "$STATE/java" || die "cannot create $STATE/java"

# --- 3. Point the Java preferences store at the persistent mount ----------
# Belt and braces on purpose.  The launch line passes
# -Djava.util.prefs.userRoot, and $HOME/.java is symlinked at the same place:
# if the JRE honours the property it writes through the symlink, and if it
# ignores the property the JDK default IS $HOME/.java.  Either road lands in
# the mount, which is what makes the LICENCE ACTIVATION, the EULA acceptance
# and Burp's CA survive `sbx rm` -- activations are a finite resource and
# re-activating on every sandbox recreate eventually hits a support ticket.
if [ -e "$HOME/.java" ] && [ ! -L "$HOME/.java" ]; then
    die "$HOME/.java exists and is not a symlink; move it aside first"
fi
ln -sfn "$STATE/java" "$HOME/.java"

# --- 4. Wait for the display ----------------------------------------------
# This bounded wait, and the message under it, ARE the entire dependency
# mechanism between this kit and sbx-desktop.  There is no kit-to-kit
# dependency machinery, and none is needed as long as the failure names the
# missing kit instead of surfacing as a HeadlessException from the JVM.
for _ in $(seq 1 60); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.5
done
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || die \
    "no X display on $DISPLAY after 30s -- was this sandbox created with --kit .../kits/desktop ?"

# --- 5. Seed the configs, once, into the writable state -------------------
# BURP WRITES THESE FILES BACK.  Whatever you change in the GUI is saved to the
# path given by --user-config-file / --config-file when Burp exits, which is
# why they must be the copies under $STATE and never the kit's own seeds (nor
# anything under $DIST, which is mounted read-only: Burp would fail to save
# mid-session and silently lose the extension registration).
#
# The upside of that write-back is that it makes this kit self-improving: set
# something in the GUI once, then `stage-burp.sh --reseed` copies the result
# back over the seeds. That is also how to harvest the config keys nobody has
# documented -- toggle, diff, commit.
render() {
    python3 - "$1" "$2" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src).read().replace("@BURP_DIST@", os.environ["DIST"])
cfg = json.loads(raw)

# Fill the upstream proxy from the sandbox's own HTTPS_PROXY, or remove the
# block entirely when there is none -- an upstream proxy pointing at a host
# that is not there is worse than no upstream proxy at all.
px = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or ""
srv = cfg.get("user_options", {}).get("connections", {}).get("upstream_proxy", {})
if "servers" in srv:
    if px:
        hostport = px.split("://", 1)[-1].rstrip("/")
        host, _, port = hostport.rpartition(":")
        if not host:
            host, port = hostport, "8080"
        for s in srv["servers"]:
            if s.get("proxy_host") == "@PROXY_HOST@":
                s["proxy_host"] = host
                s["proxy_port"] = int(port)
    else:
        srv["servers"] = []
        print("[burp-start] HTTPS_PROXY is unset; assuming direct egress", file=sys.stderr)

json.dump(cfg, open(dst, "w"), indent=2)
PY
}

export DIST
for f in user-config project-config; do
    [ -e "$STATE/$f.json" ] && continue
    render "$HOME/etc/burp/$f.seed.json" "$STATE/$f.json" \
        || die "could not render $f.json"
    echo "[burp-start] seeded $STATE/$f.json"
done

# --- 6. Launch ------------------------------------------------------------
# setsid nohup is not decoration.  `sbx exec <sandbox> burp-start.sh` tears down
# its process group when the exec returns, and without this Burp dies the
# instant the command that started it finishes.
#
# -XX:MaxRAMPercentage=50 rather than -Xmx: it is what PortSwigger's own
# vmoptions.txt ships, and the JVM reads the cgroup limit, so it tracks
# `sbx run -m 8g` without this kit having to know the number.
#
# No --use-defaults: it means "ignore saved configuration", which would discard
# the very files seeded above.  No --unpause-spider-and-scanner: auto-starting a
# scanner whose targets an LLM chooses is not a shippable default.
echo "[burp-start] launching Burp (log: $LOG)"
setsid nohup java \
    -XX:MaxRAMPercentage=50 \
    -Djava.util.prefs.userRoot="$HOME/.java" \
    -Dawt.useSystemAAFontSettings=on -Dswing.aatext=true \
    -jar "$JAR" \
    --project-file="$STATE/project.burp" \
    --config-file="$STATE/project-config.json" \
    --user-config-file="$STATE/user-config.json" \
    >>"$LOG" 2>&1 &

# --- 7. Wait for both ports, or explain the failure -----------------------
for _ in $(seq 1 120); do
    port_open "$PROXY_PORT" && port_open "$API_PORT" && break
    sleep 1
done

if ! port_open "$PROXY_PORT"; then
    echo "burp-start: proxy port $PROXY_PORT never opened. Last 20 lines of $LOG:" >&2
    tail -n 20 "$LOG" >&2
    # The generic form of this reads as a crash and sends people to the wrong
    # place, so name it: 137 is the container OOM killer, not a Burp bug.
    echo "(if the JVM vanished with rc=137 it was the OOM killer: raise sbx run -m)" >&2
    exit 1
fi

if ! port_open "$API_PORT"; then
    echo "burp-start: proxy is up but the MCP bridge API on $API_PORT is not." >&2
    echo "  The extension may not have loaded -- check Extensions in the Burp UI," >&2
    echo "  and the extension_file path in $STATE/user-config.json." >&2
fi

# --- 8. Trust Burp's CA inside the sandbox --------------------------------
# The trust store is container overlay, so this has to run in every new
# container even though the CA itself (living in the Java prefs on the state
# mount) is stable across recreates.
#
# System-wide trust is safe HERE because there is no global proxy: trusting a
# CA redirects nothing by itself, and only `via-burp` sends traffic somewhere
# that trust applies.  Same pairing as -ac with -nolisten tcp in desktop-svc.sh.
CA=/usr/local/share/ca-certificates/burp.crt
if [ ! -s "$CA" ]; then
    if curl -fsS "http://127.0.0.1:$PROXY_PORT/cert" -o /tmp/burp.der 2>/dev/null &&
       openssl x509 -inform der -in /tmp/burp.der -out /tmp/burp.crt 2>/dev/null; then
        sudo install -m 0644 /tmp/burp.crt "$CA" && sudo update-ca-certificates >/dev/null 2>&1 \
            && echo "[burp-start] installed Burp's CA into the system trust store"
    else
        echo "[burp-start] could not fetch Burp's CA yet; re-run this script once the UI is up" >&2
    fi
fi

echo
echo "Burp is up.  proxy :$PROXY_PORT   bridge api :$API_PORT   log: $LOG"
echo "  desktop:  $("$HOME/bin/desktopctl" url 2>/dev/null || echo '~/bin/desktopctl url')"
echo "  route a command through it:  via-burp curl -sS https://target/"
