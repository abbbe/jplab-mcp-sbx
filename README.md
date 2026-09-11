# sbx-kits: JupyterLab, a desktop, and Burp Suite Pro

Three mixin kits for [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`),
composed onto the stock `claude` agent. Each one works alone; together they give a sandbox
where Claude drives Burp over MCP, you watch and click the real Burp GUI in a browser, and
JupyterLab is there for scripting.

| kit | what it adds | port | starts |
|---|---|---|---|
| [`kits/jupyter`](kits/jupyter) | JupyterLab with RTC + `jupyter-mcp-server` over stdio | 8888 | automatically |
| [`kits/desktop`](kits/desktop) | TigerVNC (Xvnc) + fluxbox + noVNC, resizes to the browser | 6080 | automatically |
| [`kits/burp`](kits/burp) | Burp Suite Pro + [`burp-mcp-bridge`](https://github.com/fwaeytens/burp-mcp-bridge) | 8080 | on demand |

Kits are composed at **create** time — `sbx kit add` on a running sandbox silently skips
`ports:` and `volumes:`, so a kit added later has nothing published.

## Use the wrapper

`bin/sbx-kits` composes the `sbx run` invocation and owns the parts no kit can: the shared
token, and fixed host ports.

```console
git clone https://github.com/abbbe/sbx-kits ~/.sbx/sbx-kits
~/.sbx/sbx-kits/bin/sbx-kits up            # creates a sandbox named after $PWD
~/.sbx/sbx-kits/bin/sbx-kits status        # sandbox state + per-service health
~/.sbx/sbx-kits/bin/sbx-kits urls          # URLs and token again
~/.sbx/sbx-kits/bin/sbx-kits shell         # a shell inside it
```

`up` prints the noVNC and JupyterLab URLs with the token filled in. Defaults live in
`~/.config/sbx-kits/config` (plain `KEY=value`), so `KITS=jupyter,desktop` or `MEMORY=12g`
there beats retyping flags. `--dry-run` prints the `sbx run` it would execute.

JupyterLab only: `sbx-kits up notebook --kits jupyter`.

The wrapper exists because the raw invocation is a dozen arguments, three of which must be
byte-identical to two others — an additional workspace mounts at its identical host path and
a kit cannot read the mount table, so each staged path has to be passed twice. It also always
passes `--detached`, without which the sandbox stops 30 seconds after the last session
disconnects, and it shifts off a busy host port rather than letting `sbx run` fail the whole
create with a 409.

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

Then create the sandbox and do the one interactive step:

```console
./bin/sbx-kits up burpbox
sbx exec -it burpbox /home/agent/bin/burp-start.sh   # first run: EULA, then licence
```

Burp's first run is a console conversation, not a GUI wizard: it prints the EULA and blocks on
stdin, so it needs a terminal — that is why the command above uses `sbx exec -it`.
`dist/license.key` is at the same path inside the sandbox, so you can `cat` it there and paste. After that the activation lives in `state/java` on the host
and survives `sbx rm`.

## The desktop follows your browser window

Open the noVNC URL and the desktop sizes itself to the browser window, at 1:1 pixels — no
scaling, no letterboxing, no scrollbars. Resize the window and it follows.

That comes from two halves that both have to be right. The URL carries `?resize=remote`, which
is the noVNC setting that makes the client ask for a size rather than scale what it is given;
`sbx-kits urls` and `desktopctl url` both print it that way. The other half is the server:
`kits/desktop` runs TigerVNC's **Xvnc**, which is the X server and the VNC server in one
process, started with `-AcceptSetDesktopSize=1`.

It used to run Xvfb with x11vnc in front, and that pairing *cannot* do this. Xvfb welds its
framebuffer maximum on at startup — `xrandr` on the old stack reported `maximum 1920 x 1080`
against `maximum 32768 x 32768` on Xvnc — and x11vnc has no SetDesktopSize hook at all, so a
viewer asking for a different size was simply refused. All you could do was scale in the
browser and squint.

`$VNC_GEOMETRY` (default 1920x1080) is now only the size the desktop *starts* at, for whatever
happens before a viewer connects. When nothing is attached — a GUI the agent started headlessly,
a screenshot that has to come out at a known size — set it by hand:

```console
sbx exec burpbox /home/agent/bin/desktopctl resize 2560x1440
sbx exec burpbox /home/agent/bin/desktopctl status     # prints the current size
```

A viewer that connects later will override that, which is the right precedence: the viewer wins
when there is a viewer.

**A native client works too**, and gets the same dynamic resize, because Xvnc speaks RFB
directly. 5900 is not published, and that is deliberate — the RFB protocol truncates the
password to eight characters, so an exposed 5900 is a remote desktop behind eight characters.
`sbx-kits` has no flag for it on purpose. To do it anyway, take the command the wrapper would
have run and add the mapping yourself, loopback-only:

```console
./bin/sbx-kits up burpbox --dry-run      # prints the full sbx run line
<that line> -p 127.0.0.1:5900:5900       # then point a VNC viewer at localhost:5900
```

macOS's own Screen Sharing.app will connect but will not resize — it does not send
SetDesktopSize. A TigerVNC or RealVNC viewer does.

## One token

There is a single secret per sandbox at `/home/agent/.sbx-token`. Whichever kit's install step
runs first creates it and the rest reuse it, so any subset of the kits composes.

`sbx-kits up` generates it on the host, keeps it under `~/.local/state/sbx-kits/<name>.token`,
and pins it with `--kit-arg token=`. That matters for two reasons: `sbx run` surfaces no install
or startup output, so a sandbox has nowhere to announce a token it generated itself; and
`/home/agent/.sbx-token` is container overlay, so an `sbx kit add` container swap would
otherwise regenerate it and silently change your VNC password mid-session.

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
sbx-kits down burpbox      # stop
sbx-kits wake burpbox      # start again without spawning the Claude TUI
sbx-kits destroy burpbox   # remove it (host-staged Burp state is untouched)
```

Burp does not come back by itself after a restart — run `burp-start.sh` again. The desktop and
JupyterLab do.

## Memory

A mixin cannot raise the sandbox's memory limit, so it has to come from the command line;
`sbx-kits up` passes `-m 8g` by default (`--memory`, or `MEMORY=` in the config file). Burp runs
with `-XX:MaxRAMPercentage=50`, which reads the cgroup limit, so it tracks whatever the sandbox
was given without the kit knowing the number.
