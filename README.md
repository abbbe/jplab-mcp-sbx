# sbx kits: JupyterLab, a desktop, and Burp Suite Pro

Three mixin kits for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`),
composed onto the stock `claude` agent. Each one works alone; together they give a sandbox
where Claude drives Burp over MCP, you watch and click the real Burp GUI in a browser, and
JupyterLab is there for scripting.

| kit | what it adds | port | starts |
|---|---|---|---|
| [`kits/jupyter`](kits/jupyter) | JupyterLab with RTC + `jupyter-mcp-server` over stdio | 8888 | automatically |
| [`kits/desktop`](kits/desktop) | Xvfb + fluxbox + x11vnc + noVNC | 6080 | automatically |
| [`kits/burp`](kits/burp) | Burp Suite Pro + [`burp-mcp-bridge`](https://github.com/fwaeytens/burp-mcp-bridge) | 8080 | on demand |

Kits are composed at **create** time — `sbx kit add` on a running sandbox silently skips
`ports:` and `volumes:`, so a kit added later has nothing published.

## JupyterLab only

```console
git clone https://github.com/abbbe/jplab-mcp-sbx ~/.sbx/sbx-kits
sbx run --detached claude --name jlcc . --kit ~/.sbx/sbx-kits/kits/jupyter -p 8888:8888
```

```
  Published 127.0.0.1:8888 -> 8888/tcp4
  Published jupyterlab: localhost:49160 -> 8888/tcp
```

Either port works; 8888 is the stable one across restarts. `--detached` is needed once, at
creation: without it the sandbox stops 30 seconds after the last session disconnects.

Get the token and open `http://localhost:8888/lab?token=<token>`:

```console
sbx exec jlcc cat /home/agent/.sbx-token
```

## Everything, including Burp

Burp Pro and the MCP bridge are staged on the host and mounted in — PortSwigger's download
needs your account, so nothing here can fetch Burp for you. Download the **platform installer**
matching your machine's architecture (`Linux (ARM)` on Apple Silicon, `Linux (x64)` on Intel)
from <https://portswigger.net/burp/releases/>, then:

```console
./kits/burp/stage-burp.sh --installer ~/Downloads/burpsuite_linux_arm64_v2026_8.sh
```

**Use the installer, not the standalone JAR.** The JAR's `chromium.properties` declares a
browser build for every platform including `linuxarm64`, but the JAR only *contains*
`chromium-{linux64,macosx64,win64}-*.zip`. Its `StandaloneJarChromiumBinaryInstaller` resolves
that archive as a classpath resource inside the JAR — not a download — so on arm64 Burp's
browser fails with no network traffic and nothing in the log. The platform installer takes the
other code path and ships the arm64 Chromium (verified: `ELF 64-bit ARM aarch64`, 151.0.7922.137),
plus PortSwigger's own JRE, which also silences the "your JRE appears to be … from Ubuntu"
warning. `--jar` still works as a fallback and warns about the browser.

The install runs unattended on first `burp-start.sh`, into `state/burp-install` — about 950 MB,
paid once, and it survives `sbx rm` with the rest of the state mount.

It prints the exact `sbx run` line, with your paths already substituted. Then:

```console
sbx exec burpbox /home/agent/bin/desktopctl url    # noVNC URL + password
sbx exec burpbox /home/agent/bin/burp-start.sh     # first run: EULA, then licence wizard
```

(Absolute paths because `sbx exec` does not run a login shell, so `~/bin` may not be on `PATH`.
From a shell inside the sandbox the bare names usually work.)

The licence wizard is GUI-only — there is no command-line activation — so it happens once, in
the noVNC window. `dist/license.key` is at the same path inside the sandbox, so you can `cat`
it in a terminal there and paste. After that the activation lives in `state/java` on the host
and survives `sbx rm`.

## One token

There is a single secret per sandbox at `/home/agent/.sbx-token`. Whichever kit's install step
runs first creates it and the rest reuse it, so any subset of the kits composes. Preset it with
`--kit-arg token=<value>` (which applies to every kit at once) or `-e SBX_TOKEN=<value>`;
otherwise it is random.

JupyterLab uses it as its access token and the desktop as its VNC password. Note the RFB
protocol truncates VNC passwords to **eight characters**, so the desktop is only ever protected
by the first eight — which is why 6080 belongs on `127.0.0.1` and nowhere else. One token also
means one leak exposes both services.

## Ports: use `-p`, don't rely on the automatic ones

Each kit declares its port, and sbx auto-publishes those on ephemeral host ports. Two measured
reasons not to depend on them:

They are **reallocated when the sandbox restarts** — one sandbox went from 49166/67/68 at
create to 49169/70/71 after a stop/start, with the old numbers dead. Any bookmark goes stale.

And they are published dual-stack (`protocol:` accepts only `tcp` or `udp` in a kit, never
`tcp4`), so a service that binds IPv4-only inside the sandbox is unreachable over the `::1`
half — and macOS tries `::1` first, so `localhost:<port>` fails while `127.0.0.1:<port>`
works. Measured on this kit: Burp's own listener binds dual-stack and is fine either way,
but websockify had to be given `[::]` explicitly to stop being IPv4-only.

An explicit `-p 6080:6080` defaults to `tcp4`, which is stable and matches any listener.

## Egress is default-deny

Burp's own traffic is subject to the sandbox network policy, so the sandbox doubles as a scope
guard. Per engagement, on the host:

```console
sbx policy allow network --sandbox burpbox "target.example.com:443"
sbx policy check network target.example.com --sandbox burpbox   # states the reason
```

To find out what a kit reaches for, probe it under `deny-all` on a throwaway daemon:

```console
APP=sbx-kits-probe
sbx --app-name $APP policy init deny-all
sbx --app-name $APP create --name probe --kit "$PWD/kits/burp" claude /tmp/probe || true
sbx --app-name $APP policy log probe
sbx --app-name $APP reset --force
```

## Routing traffic through Burp

There is deliberately **no** global `HTTP_PROXY`: it would apply to every process including
Claude Code, sending the session's own Anthropic API traffic through Burp and leaving its
credentials in the proxy history. Opt in per command instead:

```console
via-burp curl -sS https://target.example.com/
```

In JupyterLab, pick the **Python 3 (via Burp)** kernel. Burp's CA is installed system-wide by
`burp-start.sh`; that is safe precisely *because* there is no global proxy — trusting a CA
redirects nothing by itself.

## Lifecycle

```console
sbx stop jlcc          # stop
sbx exec jlcc true     # start again without spawning the Claude TUI
```

Burp does not come back by itself after a restart — run `burp-start.sh` again. The desktop and
JupyterLab do.

## Memory

A mixin cannot raise the sandbox's memory limit, so pass it yourself: `-m 8g` when Burp is in
the mix. Burp runs with `-XX:MaxRAMPercentage=50`, which reads the cgroup limit, so it tracks
whatever you give the sandbox.
