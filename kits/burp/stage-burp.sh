#!/usr/bin/env bash
# Stage Burp Pro and the MCP bridge on the HOST, for mounting into a sandbox.
#
# This runs on your machine, not in the sandbox, and it is deliberately NOT
# under files/ so it never gets shipped into one.  It works the same on macOS
# and Linux: nothing here looks in /Applications or anywhere else macOS-specific.
#
# WHY STAGING AT ALL, RATHER THAN DOWNLOADING AT CREATE.  Three reasons, in
# order of weight.  The licence and Burp's project file need a writable host
# directory regardless, and once that exists putting the jars beside it is free.
# portswigger.net is the last host you want reachable from a sandbox that
# renders attacker-controlled responses, and staging keeps it off the
# allowlist.  And a ~400MB download on every `sbx create` is a tax with no
# upside, since the jar changes monthly at most.
#
# WHY THE BURP JAR IS NOT DOWNLOADED HERE EITHER.  Measured: a GET of
# https://portswigger.net/burp/releases/download?product=pro&version=...&type=Jar
# from an unauthenticated client 302s to the marketing page and returns HTML.
# The Pro jar is behind your PortSwigger session, so no script can fetch it and
# this one does not pretend to.  You download it; --jar points at it.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HOME}/.sbx/burp"
BRIDGE_VERSION="2.8.0"
JAR=""
INSTALLER=""
LICENSE_FILE=""
TOKEN=""
RESEED=0

usage() {
    cat <<EOF
Usage: $0 (--installer PATH | --jar PATH) [options]
       $0 --reseed [--root DIR]

  --installer PATH       Burp Suite Professional PLATFORM INSTALLER (.sh) for
                         the sandbox's architecture. PREFER THIS: it is the only
                         flavour that carries Burp's embedded browser for arm64,
                         and it bundles PortSwigger's own JRE. Download it from
                         https://portswigger.net/burp/releases/ -- log in, pick
                         your version, platform "Linux (ARM)" on Apple Silicon
                         or "Linux (x64)" on an Intel host.
  --jar PATH             Burp Suite Professional standalone JAR. Works, but its
                         embedded browser is x64-only (the jar ships
                         chromium-{linux64,macosx64,win64} and nothing for
                         linuxarm64, despite declaring it in chromium.properties).
  --root DIR             Staging root (default: \$HOME/.sbx/burp)
  --bridge-version VER   fwaeytens/burp-mcp-bridge release (default: $BRIDGE_VERSION)
  --license-file FILE    File containing your Burp licence key (else prompted)
  --token STRING         Preset the shared sandbox token instead of generating one
  --reseed               Copy the live Burp configs from state/ back over this
                         kit's *.seed.json, re-parameterising absolute paths.
                         Run it after changing settings in the Burp GUI.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --jar) JAR="${2:?}"; shift 2 ;;
        --installer) INSTALLER="${2:?}"; shift 2 ;;
        --root) ROOT="${2:?}"; shift 2 ;;
        --bridge-version) BRIDGE_VERSION="${2:?}"; shift 2 ;;
        --license-file) LICENSE_FILE="${2:?}"; shift 2 ;;
        --token) TOKEN="${2:?}"; shift 2 ;;
        --reseed) RESEED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "stage-burp: $*" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
    else shasum -a 256 "$@"; fi
}

# --- reseed mode ----------------------------------------------------------
# Burp writes its configuration back to the files given by --user-config-file
# and --config-file, and those live on the state mount.  So the way to preset a
# setting whose JSON key nobody has documented is: set it once in the GUI, then
# run this, then commit the diff.  That is how the proxy listener spelling and
# Burp's "run the browser without a sandbox" toggle get captured, rather than
# guessed.
if [ "$RESEED" = 1 ]; then
    [ -d "$ROOT/state" ] || die "no state directory at $ROOT/state"
    for f in user-config project-config; do
        live="$ROOT/state/$f.json"
        [ -s "$live" ] || { echo "stage-burp: no $live yet, skipping" >&2; continue; }
        python3 - "$live" "$KIT_DIR/files/home/etc/burp/$f.seed.json" "$ROOT/dist" <<'PY'
import json, sys
live, seed, dist = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(live).read().replace(dist, "@BURP_DIST@")
cfg = json.loads(raw)
# The upstream proxy is per-sandbox, so put the placeholder back rather than
# baking one sandbox's egress proxy address into the kit.
srv = cfg.get("user_options", {}).get("connections", {}).get("upstream_proxy", {})
for s in srv.get("servers", []):
    s["proxy_host"] = "@PROXY_HOST@"
    s["proxy_port"] = 0
json.dump(cfg, open(seed, "w"), indent=2)
open(seed, "a").write("\n")
print("reseeded %s" % seed)
PY
    done
    echo
    echo "Review with: git -C \"$KIT_DIR\" diff"
    exit 0
fi

# --- preflight ------------------------------------------------------------
for c in curl tar unzip python3 node npm; do
    command -v "$c" >/dev/null 2>&1 || die "missing required tool: $c"
done
node_major=$(node -p 'process.versions.node.split(".")[0]')
node_minor=$(node -p 'process.versions.node.split(".")[1]')
if [ "$node_major" -lt 18 ] || { [ "$node_major" -eq 18 ] && [ "$node_minor" -lt 14 ]; }; then
    die "node $(node -v) is too old; the bridge needs >= 18.14.1"
fi

[ -n "$JAR" ] || [ -n "$INSTALLER" ] || {
    usage >&2; echo >&2; die "one of --installer (preferred) or --jar is required"; }

mkdir -p "$ROOT/dist" "$ROOT/state/java"

# The sandbox inherits the host's architecture, so the installer has to match
# this machine, not the machine the licence was bought on.
case "$(uname -m)" in
    arm64|aarch64) WANT_ARCH=arm64 ;;
    x86_64|amd64)  WANT_ARCH=x64 ;;
    *)             WANT_ARCH="" ;;
esac

# --- Burp platform installer (preferred) ----------------------------------
if [ -n "$INSTALLER" ]; then
    echo "==> Burp platform installer"
    [ -f "$INSTALLER" ] || die "no such file: $INSTALLER"
    # install4j installers are shell scripts with a payload appended. A partial
    # or wrong download surfaces much later as a hung install, so check now.
    # -i because the marker in the header is the uppercase INSTALL4J_* variable
    # names, not the lowercase product name.
    head -c 2048 "$INSTALLER" | grep -qi 'install4j' \
        || die "$INSTALLER does not look like an install4j installer"
    case "$(basename "$INSTALLER")" in
        *linux*|*Linux*) : ;;
        *) echo "    WARNING: '$(basename "$INSTALLER")' does not look like a LINUX build;" >&2
           echo "             the sandbox is Linux regardless of your host OS." >&2 ;;
    esac
    if [ "$WANT_ARCH" = arm64 ]; then
        case "$(basename "$INSTALLER")" in
            *arm64*|*aarch64*) : ;;
            *) echo "    WARNING: this host is arm64 but '$(basename "$INSTALLER")' does not" >&2
               echo "             look like an arm64 build. Burp will not start." >&2 ;;
        esac
    fi
    cp "$INSTALLER" "$ROOT/dist/burp-installer.sh"
    chmod +x "$ROOT/dist/burp-installer.sh"
fi

# --- Burp standalone jar (fallback) ---------------------------------------
if [ -n "$JAR" ]; then
    echo "==> Burp jar"
    [ -f "$JAR" ] || die "no such file: $JAR"
    # A truncated download or an HTML error page saved as a .jar is the classic
    # silent failure here, and it surfaces later as "Burp will not start".
    unzip -p "$JAR" META-INF/MANIFEST.MF 2>/dev/null | grep -q 'Main-Class: *burp\.StartBurp' \
        || die "$JAR does not look like a Burp jar (no Main-Class: burp.StartBurp)"
    cp "$JAR" "$ROOT/dist/burpsuite_pro.jar"
fi

# --- MCP bridge: extension jar + node bridge ------------------------------
# Both are public GitHub release artefacts, so unlike the Burp jar these CAN be
# fetched.  github.com is allowed by sbx's default egress policy too, but that
# is irrelevant here -- this is a host download.
echo "==> burp-mcp-bridge $BRIDGE_VERSION extension jar"
curl -fL --retry 3 -o "$ROOT/dist/burp-mcp-bridge.jar" \
    "https://github.com/fwaeytens/burp-mcp-bridge/releases/download/v${BRIDGE_VERSION}/burp-mcp-bridge-${BRIDGE_VERSION}.jar"
unzip -p "$ROOT/dist/burp-mcp-bridge.jar" META-INF/MANIFEST.MF >/dev/null 2>&1 \
    || die "the downloaded bridge jar has no manifest -- probably an HTML error page"

echo "==> burp-mcp-bridge $BRIDGE_VERSION node bridge"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 "https://github.com/fwaeytens/burp-mcp-bridge/archive/refs/tags/v${BRIDGE_VERSION}.tar.gz" \
    | tar -xz -C "$TMP"
rm -rf "$ROOT/dist/bridge"
mkdir -p "$ROOT/dist/bridge"
cp -R "$TMP/burp-mcp-bridge-${BRIDGE_VERSION}/bridge/." "$ROOT/dist/bridge/"
( cd "$ROOT/dist/bridge" && { npm ci --omit=dev >/dev/null 2>&1 || npm install --omit=dev >/dev/null 2>&1; } ) \
    || die "npm install failed in $ROOT/dist/bridge"

# node_modules IS BUILT ON THE HOST AND RUN ON LINUX, so it may only contain
# portable JavaScript.  Today the bridge's single dependency is
# @modelcontextprotocol/sdk, which is pure JS -- this check exists so that the
# day that stops being true you find out here, rather than as an inscrutable
# ERR_DLOPEN_FAILED when Claude first calls a burp tool.
if find "$ROOT/dist/bridge/node_modules" -name '*.node' -print -quit 2>/dev/null | grep -q .; then
    die "a bridge dependency ships a compiled native binding; node_modules built here will not
    load inside the sandbox. Install it in the sandbox instead of staging it."
fi

# --- licence key ----------------------------------------------------------
echo "==> licence key"
if [ -n "$LICENSE_FILE" ]; then
    [ -f "$LICENSE_FILE" ] || die "no such file: $LICENSE_FILE"
    cp "$LICENSE_FILE" "$ROOT/dist/license.key"
elif [ ! -s "$ROOT/dist/license.key" ]; then
    printf 'Paste your Burp licence key (input hidden): ' >&2
    read -rs key
    printf '\n' >&2
    [ -n "$key" ] || die "no licence key given"
    printf '%s' "$key" > "$ROOT/dist/license.key"
else
    echo "    keeping the existing $ROOT/dist/license.key"
fi
chmod 600 "$ROOT/dist/license.key"

# --- manifest -------------------------------------------------------------
( cd "$ROOT/dist" && sha256 burp-mcp-bridge.jar \
    $([ -f burpsuite_pro.jar ] && echo burpsuite_pro.jar) \
    $([ -f burp-installer.sh ] && echo burp-installer.sh) > MANIFEST.sha256 )

# --- what to run ----------------------------------------------------------
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"
tokarg=""
[ -n "$TOKEN" ] && tokarg=" \\
    --kit-arg token=$TOKEN"

cat <<EOF

Staged into $ROOT  (bridge $BRIDGE_VERSION)
$([ -f "$ROOT/dist/burp-installer.sh" ] && printf '    dist/burp-installer.sh      %s (installed on first burp-start.sh)' "$(du -h "$ROOT/dist/burp-installer.sh" | cut -f1)")
$([ -f "$ROOT/dist/burpsuite_pro.jar" ] && printf '    dist/burpsuite_pro.jar      %s' "$(du -h "$ROOT/dist/burpsuite_pro.jar" | cut -f1)")
    dist/burp-mcp-bridge.jar    $(du -h "$ROOT/dist/burp-mcp-bridge.jar" | cut -f1)
    dist/bridge/                node bridge with node_modules
    dist/license.key            (0600)
    state/                      empty until first run; holds the activation

Create the sandbox with:

  sbx run --detached claude --name burpbox . \\
    $ROOT/dist:ro \\
    $ROOT/state \\
    --kit $REPO_ROOT/kits/jupyter \\
    --kit $REPO_ROOT/kits/desktop \\
    --kit $REPO_ROOT/kits/burp \\
    --kit-arg sbx-burp.dist=$ROOT/dist \\
    --kit-arg sbx-burp.state=$ROOT/state$tokarg \\
    -m 8g \\
    -p 8888:8888 -p 6080:6080 -p 18080:8080

The sandbox's Burp proxy is published on host port 18080, NOT 8080: anyone using
this kit very likely has a Burp of their own already listening on 127.0.0.1:8080,
and sbx fails the whole create with "address already in use" rather than picking
another port. Point external clients at 127.0.0.1:18080. Inside the sandbox the
listener is still on 8080, so via-burp and the proxied Jupyter kernel are unaffected.

Then, inside it:
    sbx exec burpbox desktopctl url          # noVNC URL and password
    sbx exec burpbox burp-start.sh           # first run: EULA + licence wizard

And for each target you intend to test (egress is default-deny):
    sbx policy allow network --sandbox burpbox "target.example.com:443"

Your licence key is in $ROOT/dist/license.key -- inside the sandbox it is at
the same path, so you can cat it in a noVNC terminal and paste it into the
wizard.
EOF
