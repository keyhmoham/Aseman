# Sandbox computer: the default per-space sandbox image of tradera.
#
# Every space runs one. It is the shared computer of the space's agents: the
# deep agents runtime runs their shell commands and file tools here (through
# spaces.ask), so the lead and every specialist work on the same files under
# /workspace. The deep agents file tools run python3 in the sandbox.
#
#   docker build -t tradera/tool-runtime:v1 deploy/tool-runtime
#   docker build -t tradera/sandbox-computer:latest deploy/sandbox-computer
# The tool runtime (deploy/tool-runtime), whose files are copied in below.
ARG TOOL_RUNTIME_IMAGE=tradera/tool-runtime:v1
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
# tradera-desktop starts and drives that desktop for people and agents alike
# (kept identical to services/plugins/actions/spaces/desktop.sh, which the node
# also writes onto older machines).
COPY tradera-desktop /usr/local/bin/tradera-desktop
RUN chmod +x /usr/local/bin/tradera-desktop
# The tool runtime: tools installed into a space run here, one process per
# tool, started by the node.
COPY --from=tool-runtime /opt/tradera-tool-runtime /opt/tradera-tool-runtime
# /workspace is the space's shared working tree.
RUN mkdir -p /workspace && git config --system init.defaultBranch main \
 && git config --system --add safe.directory '*'
ENV PIP_BREAK_SYSTEM_PACKAGES=1
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
