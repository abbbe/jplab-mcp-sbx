# jplab-mcp-sbx

A mixin kit for [Docker Sandboxes](https://docs.docker.com/) (`sbx`) that adds
JupyterLab with Real-Time Collaboration and a correctly-wired Datalayer 
`jupyter-mcp-server` to the stock `claude` agent sandbox.

1. Do once: grab the sbx kit and stash it somewhere (here - to ~/.sbx/jplab-mcp-sbx):
```console
git clone https://github.com/abbbe/jplab-mcp-sbx ~/.sbx/jplab-mcp-sbx
```

2. Create a new sandbox. Here - called jlcc, bind-mounting the content current directory.
```console
sbx run --detached claude --name jlcc . --kit ~/.sbx/jplab-mcp-sbx -p 8888:8888
...
  Published 127.0.0.1:8888 -> 8888/tcp4
  Published jupyterlab: localhost:49160 -> 8888/tcp
```
You can use either port to access it, but 8888 is stable across sandbox restarts.
Thanks to `--detached` (has to be used only once during creation) the sandbox survives 30s threshold.

Grab the token for Jupyter Lab web UI:
```console
sbx exec jlcc cat /home/agent/.jupyter-token
KV***mL
```

Open `http://localhost:8888/lab?token=<token>`.
