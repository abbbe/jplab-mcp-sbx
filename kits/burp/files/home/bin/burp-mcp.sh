#!/usr/bin/env bash
# The stdio MCP server Claude Code spawns, wrapping fwaeytens/burp-mcp-bridge.
#
# NOTHING MAY EVER BE WRITTEN TO STDOUT HERE.  stdio is the MCP transport; a
# single stray line of output corrupts the protocol and the failure looks like a
# broken server, not a chatty script.  Diagnostics go to stderr only.
#
# MCP_TRANSPORT_MODE=stdio IS NOT A PREFERENCE.  The bridge defaults to `both`,
# which serves stdio AND opens an HTTPS/SSE listener on port 3000.  Two ways
# that bites: anything on that path which prints to stdout corrupts this
# transport, and a second Claude session in the same sandbox spawns a second
# bridge that collides on 3000.  Claude Code connects over stdio, so the other
# half is pure liability.
#
# WAITING IS CONDITIONAL, NOT UNCONDITIONAL.  Burp starts on demand, so most
# sessions begin with no Burp at all and a fixed wait would stall every one of
# them at startup.  A Burp JVM that is up but not yet answering on 8081 is still
# loading its extension, and that IS worth waiting for.
#
# AND IT EXECS EITHER WAY.  A bridge that starts and returns a connection error
# per call leaves the tools listed and the error legible; a wrapper that exits
# instead leaves Claude with "server failed", no tools at all, and a mandatory
# /mcp after every Burp start.
set -uo pipefail

DIST=${BURP_DIST:-/opt/burp/dist}
BRIDGE="$DIST/bridge/index.js"
PORT=${BURP_API_PORT:-8081}

export MCP_TRANSPORT_MODE=stdio
export BURP_MCP_SERVER_PORT="$PORT"

if [ ! -f "$BRIDGE" ]; then
    echo "[burp-mcp] no bridge at $BRIDGE -- run stage-burp.sh on the host and" >&2
    echo "[burp-mcp] recreate the sandbox with --kit-arg sbx-burp.dist=<path>" >&2
    exit 1
fi

open() { timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; }

if ! open; then
    if pgrep -f 'burpsuite_pro\.jar' >/dev/null 2>&1; then
        echo "[burp-mcp] Burp is starting; waiting for the extension on :$PORT" >&2
        for _ in $(seq 1 120); do open && break; sleep 1; done
    else
        echo "[burp-mcp] Burp is not running; tool calls will fail until: burp-start.sh" >&2
    fi
fi

exec node "$BRIDGE"
