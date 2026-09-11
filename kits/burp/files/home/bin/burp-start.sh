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

# PIN JAVA 21 IF IT IS THERE.  The kit installs openjdk-21-jre, but the base
# template already carries openjdk-25, which wins the `java` alternative -- and
# Burp then prints "Your JRE appears to be version 25.0.4 from Ubuntu. Burp has
# not been fully tested on this platform and you may experience problems."
# Measured in a live sandbox.  Java 21 is PortSwigger's stated minimum and the
# version their own builds ship, so prefer it explicitly rather than inheriting
# whatever the alternatives system picked.
JAVA=$(ls -d /usr/lib/jvm/java-21-openjdk-*/bin/java 2>/dev/null | head -1)
[ -x "${JAVA:-}" ] || JAVA=$(command -v java)
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
#
# THE PORT IS THE AUTHORITY HERE, NOT THE PROCESS TABLE.  This was a pgrep
# alone, matching '[b]urpsuite_pro\.jar|[B]urpSuite' -- and it MISSED the
# flavour this kit goes out of its way to prefer.  An install4j launcher execs
# its bundled JRE, so the launcher's own name is gone from argv by the time
# anything can look for it.  Measured on a live sandbox, with Burp holding both
# ports, the process is:
#   .../state/burp-install/jre/bin/java -splash:.../.install4j/... --add-opens ...
# and BOTH old patterns scored zero.  So the one guard whose job is to stop a
# second Burp never fired for an installer-based Burp at all.
#
# Contending for the port is the actual failure mode, so test the port.  pgrep
# survives only to name a pid in the message, with the install directory this
# script itself chooses ($STATE/burp-install) added to the pattern.  The
# brackets stop pgrep matching the shell running this very script, whose own
# command line would otherwise contain the pattern.
if port_open "$PROXY_PORT"; then
    pid=$(pgrep -f '[b]urpsuite_pro\.jar|[B]urpSuite|[b]urp-install' | head -1)
    if [ -n "$pid" ]; then
        echo "Burp is already running (pid $pid)."
    else
        echo "Something already holds port $PROXY_PORT; not starting a second Burp."
    fi
    echo "  proxy :$PROXY_PORT  bridge api :$API_PORT   log: $LOG"
    exit 0
fi

# --- 2. Validate the staging ----------------------------------------------
# This is the most likely misconfiguration in the whole kit, so it gets the
# best error message in it.
if [ ! -f "$JAR" ] && [ ! -f "$DIST/burp-installer.sh" ]; then
    cat >&2 <<EOF
burp-start: no Burp at $DIST (looked for burpsuite_pro.jar and burp-installer.sh)

Burp and the MCP bridge are staged on the HOST and mounted in; they are not part
of this kit (PortSwigger's download needs your account, so nothing here can fetch
it for you).

On the host, once -- prefer the platform installer, which is the only flavour
that carries Burp's embedded browser for this architecture:
    ./kits/burp/stage-burp.sh --installer /path/to/burpsuite_pro_linux_arm64_v2026_8.sh

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

# --- 2b. Prefer a PortSwigger installation over the standalone jar ---------
# THE STANDALONE JAR HAS NO BROWSER ON THIS ARCHITECTURE.  Measured: the jar's
# chromium.properties declares a build for every platform including
# linuxarm64=151.0.7922.137, but the jar only *contains*
# chromium-{linux64,macosx64,win64}-*.zip.  StandaloneJarChromiumBinaryInstaller
# resolves that archive with getSystemResourceAsStream -- a CLASSPATH lookup
# inside the jar, not a download -- so on aarch64 it asks for
# chromium-linuxarm64-151.0.7922.137.zip, does not find it, and Burp's browser
# fails with no network traffic at all and nothing in the log.  That is why
# "Burp's browser failed to start" showed no blocked hosts and no
# ~/.BurpSuite/pre-wired-browser directory.
#
# PortSwigger's platform installers take the other code path
# (Install4JChromiumBinaryInstaller reading the browser out of the installation
# directory) and DO ship the arm64 build.  They also bundle PortSwigger's own
# JRE, which is what silences "Your JRE appears to be version ... from Ubuntu".
#
# So: if an installer has been staged, use it.  The install lands on the STATE
# mount, so it is paid for once ever rather than once per sandbox.
INSTALL_DIR="$STATE/burp-install"
INSTALLER="$DIST/burp-installer.sh"

# The install drops BurpSuite, BurpSuite.vmoptions and a .desktop file side by
# side, so match on EXECUTABILITY rather than on the glob order -- a plain
# `head -1` would happily hand back BurpSuite.vmoptions.
resolve_launcher() {
    LAUNCHER=""
    local c
    for c in "$INSTALL_DIR"/BurpSuite*; do
        if [ -f "$c" ] && [ -x "$c" ]; then LAUNCHER="$c"; return 0; fi
    done
    return 1
}

if ! resolve_launcher && [ -f "$INSTALLER" ]; then
    echo "[burp-start] installing Burp into $INSTALL_DIR (once; this takes a few minutes)"
    # install4j unattended flags: -q is unattended, -dir only valid with -q,
    # -console makes it report progress instead of running mute.
    sh "$INSTALLER" -q -dir "$INSTALL_DIR" -overwrite -console 2>&1 | sed 's/^/[installer] /'
    resolve_launcher || die "installer finished but no BurpSuite* launcher under $INSTALL_DIR"
    echo "[burp-start] installed: $LAUNCHER"
fi

# Build the command prefix once; everything below launches "${BURP[@]}" plus the
# project/config arguments, whichever flavour we ended up with.
if resolve_launcher; then
    # An install4j launcher takes JVM options from INSTALL4J_ADD_VM_PARAMS, not
    # from its argv, and uses the JRE bundled beside it rather than $JAVA.
    export INSTALL4J_ADD_VM_PARAMS="-XX:MaxRAMPercentage=50 -Djava.util.prefs.userRoot=$HOME/.java -Dawt.useSystemAAFontSettings=on -Dswing.aatext=true"
    BURP=("$LAUNCHER")
elif [ -f "$JAR" ]; then
    BURP=("$JAVA"
          -XX:MaxRAMPercentage=50
          -Djava.util.prefs.userRoot="$HOME/.java"
          -Dawt.useSystemAAFontSettings=on -Dswing.aatext=true
          -jar "$JAR")
    echo "[burp-start] using the standalone jar; Burp's embedded browser will not" >&2
    echo "[burp-start] work on $(uname -m). Stage a platform installer to get it:" >&2
    echo "[burp-start]   stage-burp.sh --installer <burpsuite_pro_linux_arm64_*.sh>" >&2
fi

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

# --- 6. First run needs a TERMINAL, not a detached process ----------------
# BURP'S FIRST RUN IS A CONSOLE CONVERSATION, NOT A GUI WIZARD.  With an empty
# Java preferences store it prints the whole EULA to stdout and blocks on
# "Do you accept the license agreement? (y/n)" from STDIN -- before it opens a
# window, binds a port, or loads an extension.  The licence key prompt follows
# the same way.
#
# Measured: launched detached, with stdin not a terminal, Burp printed the EULA
# into burp.log, read EOF, and exited. Nothing on the desktop, nothing on 8080,
# and the only evidence was 70KB of licence text in the log. That is why this
# refuses to detach on a first run instead of reproducing that silence.
#
# Once accepted, `burp.eula` lands in the prefs store -- which lives on the
# state mount -- so this branch is taken exactly once per staging directory,
# not once per sandbox.
# DO NOT HARDCODE THE PREFS PATH.  An earlier version probed
# $HOME/.java/.userPrefs/burp/prefs.xml, which is where the JDK default and
# -Djava.util.prefs.userRoot both say it should be -- and it is where the
# INSTALLER's own prefs land ($STATE/java/.userPrefs/com/install4j/...).  Burp
# itself writes ONE LEVEL DEEPER: measured, the accepted EULA is at
# $STATE/java/.java/.userPrefs/burp/prefs.xml, so the two JVMs involved disagree
# about the root and the hardcoded path matched neither reliably.
#
# The cost of getting this wrong is invisible and permanent: the probe fails
# forever, so EVERY start takes the interactive first-run branch below, sits in
# the foreground streaming Burp's log to the terminal, and waits for an EULA
# prompt that will never come because Burp is already licensed.  Searching the
# prefs tree for the key is immune to which root the JRE picked.
if ! grep -rq --include=prefs.xml 'burp\.eula' "$HOME/.java" 2>/dev/null; then
    if [ ! -t 0 ]; then
        cat >&2 <<EOF
burp-start: this is Burp's first run against $STATE/java, and it will ask you to
accept the EULA (and then for your licence key) ON THE TERMINAL. Detaching now
would just block on a closed stdin and exit.

Re-run it attached to a terminal:

    sbx exec -it $(hostname) /home/agent/bin/burp-start.sh

Your licence key is at $DIST/license.key. Answer the prompts once; the answers
are stored in $STATE/java and survive sbx rm, so every later start is detached
and silent.
EOF
        exit 1
    fi

    echo "[burp-start] first run: answer the EULA and licence prompts below."
    echo "[burp-start] licence key: $DIST/license.key"
    echo

    # THE REDIRECT IS SET UP BEFORE THE exec, NOT PIPED INTO IT.  Written the
    # obvious way -- `exec "${BURP[@]}" ... 2>&1 | tee -a "$LOG"` -- the exec is
    # one element of a PIPELINE, so it replaces the subshell bash forked for that
    # element and NOT this script.  The script then survives Burp, falls through
    # to the detached launch in step 7, and starts a SECOND Burp the moment the
    # foreground one exits or is interrupted.  Measured: ^C on the first run
    # printed "launching Burp" and brought up another instance.
    #
    # Process substitution keeps the log without putting exec in a pipeline, so
    # this really is the last thing the script does.
    exec > >(tee -a "$LOG") 2>&1
    exec "${BURP[@]}" \
        --project-file="$STATE/project.burp" \
        --config-file="$STATE/project-config.json" \
        --user-config-file="$STATE/user-config.json"
fi

# --- 7. Launch detached ---------------------------------------------------
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
setsid nohup "${BURP[@]}" \
    --project-file="$STATE/project.burp" \
    --config-file="$STATE/project-config.json" \
    --user-config-file="$STATE/user-config.json" \
    >>"$LOG" 2>&1 &

# --- 8. Wait for both ports, or explain the failure -----------------------
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

# --- 9. Trust Burp's CA inside the sandbox --------------------------------
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
