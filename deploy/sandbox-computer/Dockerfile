# Sandbox computer: the default per-space sandbox image of aseman.
#
# Every space runs one. It is the shared computer of the space's agents: the
# deep agents runtime runs their shell commands and file tools here (through
# spaces.ask), so the lead and every specialist work on the same files under
# /workspace. The deep agents file tools run python3 in the sandbox.
# OpenCode + aseman-appui are baked in so every new space can generate
# on-demand fullstack App UIs (appui_create) on the Aseman LLM backbone.
# Default UI for those apps is Material 3 Expressive (@material/web).
#
#   docker build -t aseman/tool-runtime:v1 deploy/tool-runtime
#   docker build -t aseman/sandbox-computer:latest deploy/sandbox-computer
# The tool runtime (deploy/tool-runtime), whose files are copied in below.
ARG TOOL_RUNTIME_IMAGE=aseman/tool-runtime:v1
FROM ${TOOL_RUNTIME_IMAGE} AS tool-runtime

# The official node image from Amazon's public mirror of Docker Hub: anonymous
# pulls from Docker Hub itself are rate limited per IP, and CI runners share theirs.
FROM public.ecr.aws/docker/library/node:22-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl wget git jq less procps ripgrep fd-find tree \
      python3 python3-pip python3-venv build-essential sqlite3 \
      zip unzip file tini \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*
# The project's desktop (Computer): a virtual X screen, a VNC server and noVNC,
# plus a browser and the tools agents use to see and drive the screen. Baking
# them keeps "open Computer" to seconds instead of an install on every machine.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xvfb x11vnc openbox novnc websockify xdotool scrot xterm x11-utils x11-xserver-utils dbus-x11 tint2 thunar python3-tk \
      fonts-dejavu-core fonts-liberation adwaita-icon-theme chromium \
 && rm -rf /var/lib/apt/lists/*
# aseman-desktop starts and drives that desktop for people and agents alike
# (kept identical to services/plugins/actions/spaces/desktop.sh, which the node
# also writes onto older machines).
COPY aseman-desktop /usr/local/bin/aseman-desktop
RUN chmod +x /usr/local/bin/aseman-desktop
# The tool runtime: tools installed into a space run here, one process per
# tool, started by the node.
COPY --from=tool-runtime /opt/aseman-tool-runtime /opt/aseman-tool-runtime
# OpenCode: baked into every space sandbox so agents can distribute coding
# tasks and generate on-demand fullstack App UIs (appui_create) via the
# Aseman metered LLM gateway (Material 3 Expressive UI by default).
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path \
 && install -d /usr/local/bin \
 && if [ -x "$HOME/.opencode/bin/opencode" ]; then ln -sf "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode; fi \
 && if [ -x /root/.opencode/bin/opencode ]; then ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode; fi \
 && command -v opencode >/dev/null
COPY opencode/opencode.json /etc/opencode/opencode.json
ENV OPENCODE_CONFIG=/etc/opencode/opencode.json
# App UI helper + agent instructions + OpenUI kit used by platform builtins.
COPY appui/AGENTS.md /opt/aseman-appui/AGENTS.md
COPY appui/openui /opt/aseman-appui/openui
COPY appui/aseman-appui /usr/local/bin/aseman-appui
RUN chmod +x /usr/local/bin/aseman-appui \
 && mkdir -p /opt/aseman-appui \
 && ln -sf /usr/local/bin/aseman-appui /opt/aseman-appui/aseman-appui
# /workspace is the space's shared working tree.
RUN mkdir -p /workspace && git config --system init.defaultBranch main \
 && git config --system --add safe.directory '*'
ENV PIP_BREAK_SYSTEM_PACKAGES=1
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
