#!/usr/bin/env bash
#
# podman-gdb.sh - debug a process inside a running podman container
# ==================================================================
#
# Starts gdbserver inside a running podman container, attaches it to a
# process there, and connects a local debugger (gdb or lldb) to it.
#
#
# HOW IT WORKS
# ------------
# The container does not need any published ports. Ports can only be
# published when a container is created, so a normal "gdbserver :2345"
# setup would mean recreating the container. Instead, gdbserver is started
# with "-" as its communication channel, which makes it speak the GDB remote
# protocol over stdin/stdout. That stdin/stdout is the `podman exec -i`
# session, so the debugger talks to gdbserver through podman:
#
#   gdb mode:   gdb  --pipe-->  podman exec -i  -->  gdbserver --attach - PID
#   lldb mode:  lldb --tcp-->  socat (127.0.0.1:PORT)  -->  podman exec -i  -->  gdbserver
#
# gdb can start the pipe itself ("target remote | <command>"). lldb cannot,
# so socat listens on a local port and runs the podman exec command for the
# connection.
#
#
# REQUIREMENTS
# ------------
# On the host:
#   - podman
#   - gdb, or lldb + socat (on macOS: `brew install socat`)
#
# In the container:
#   - gdbserver, either installed in the image (e.g. `apt install gdbserver`,
#     `dnf install gdb-gdbserver`, `apk add gdb`) or copied in with -g
#   - /bin/sh and /proc (used to find processes by name)
#
#
# USAGE
# -----
#   podman-gdb.sh [options] CONTAINER
#
#   -p PID     PID inside the container to attach to (default: 1)
#   -n NAME    find the PID by process name; matches /proc/<pid>/comm exactly
#              (comm is truncated to 15 characters by the kernel). When
#              several processes match, the lowest PID is used.
#   -d DBG     local debugger: gdb or lldb (default: gdb if installed, else lldb)
#   -b FILE    local copy of the target binary, ideally with debug symbols.
#              Without it the debugger reads the binary from the container
#              through gdbserver, which works but is slower.
#   -g FILE    local gdbserver binary to copy into the container (to
#              /tmp/gdbserver) when the image has none. It must be built for
#              the container's architecture; a statically linked build avoids
#              library mismatches.
#   -P PORT    local port socat listens on in lldb mode (default: 2345).
#              Only bound to 127.0.0.1.
#   -h         show help
#
#
# EXAMPLES
# --------
#   # Attach to PID 1 (the container's main process)
#   ./podman-gdb.sh myapp
#
#   # Attach to a process by name
#   ./podman-gdb.sh -n worker myapp
#
#   # Use a local build with symbols
#   ./podman-gdb.sh -p 42 -b ./build/server myapp
#
#   # Image has no gdbserver: copy a static one in
#   ./podman-gdb.sh -g ./gdbserver-static-aarch64 myapp
#
#   # Force lldb on a different port
#   ./podman-gdb.sh -d lldb -P 9999 myapp
#
#
# PERMISSIONS
# -----------
# Attaching to a running process needs ptrace, which containers do not
# allow by default. The script runs gdbserver with `podman exec --privileged`,
# which gives only that exec session the extra capabilities (including
# CAP_SYS_PTRACE). The container itself does not need to be restarted.
# In rootless podman those capabilities apply only inside the container's
# user namespace, which is enough to trace processes in the same container.
#
#
# ENDING A SESSION
# ----------------
# Quitting the debugger detaches from the process, so it keeps running.
# Use `kill` in the debugger first if you want to stop it instead.
# In lldb mode, socat is stopped automatically when the script exits.
#
#
# CAVEATS
# -------
# - macOS on Apple Silicon: gdb does not run natively, so the script uses
#   lldb. lldb can debug Linux targets through gdbserver, but support is
#   less complete than gdb's. Running gdb from another Linux container is
#   an alternative.
# - Emulated containers: if the container runs a different architecture
#   than the podman VM/host (e.g. amd64 under emulation on arm64), ptrace
#   usually does not work and gdbserver will fail to attach.
# - Only one debugger can be attached to a process at a time.
#
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] CONTAINER

  -p PID     PID inside the container to attach to (default: 1)
  -n NAME    find the PID by process name (matches /proc/<pid>/comm)
  -d DBG     local debugger: gdb or lldb (default: gdb if installed, else lldb)
  -b FILE    local copy of the binary, with symbols (optional)
  -g FILE    local gdbserver binary to copy into the container if it has none
             (must be built for the container's architecture; a static build is best)
  -P PORT    local TCP port used in lldb mode (default: 2345)
  -h         show this help
EOF
  exit "${1:-1}"
}

PID="" NAME="" DBG="" BIN="" LOCAL_GDBSERVER="" PORT=2345
while getopts "p:n:d:b:g:P:h" opt; do
  case $opt in
    p) PID=$OPTARG ;;
    n) NAME=$OPTARG ;;
    d) DBG=$OPTARG ;;
    b) BIN=$OPTARG ;;
    g) LOCAL_GDBSERVER=$OPTARG ;;
    P) PORT=$OPTARG ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage
C=$1

die() { echo "error: $*" >&2; exit 1; }

command -v podman >/dev/null || die "podman not found in PATH"
[[ $(podman inspect -f '{{.State.Running}}' "$C" 2>/dev/null) == true ]] \
  || die "container '$C' is not running"

# --- pick the local debugger -------------------------------------------------
if [[ -z $DBG ]]; then
  if command -v gdb >/dev/null; then DBG=gdb
  elif command -v lldb >/dev/null; then DBG=lldb
  else die "neither gdb nor lldb is installed locally"; fi
fi
[[ $DBG == gdb || $DBG == lldb ]] || die "-d must be gdb or lldb"

# --- resolve the target PID --------------------------------------------------
if [[ -n $NAME ]]; then
  PID=$(podman exec "$C" sh -c '
    for p in /proc/[0-9]*; do
      [ "$(cat "$p/comm" 2>/dev/null)" = "$1" ] && echo "${p#/proc/}"
    done' _ "$NAME" | sort -n | head -n1)
  [[ -n $PID ]] || die "no process named '$NAME' in container '$C'"
fi
PID=${PID:-1}
echo ">> target: container=$C pid=$PID ($(podman exec "$C" cat "/proc/$PID/comm" 2>/dev/null || echo '?'))"

# --- make sure gdbserver is available in the container -----------------------
GDBSERVER=$(podman exec "$C" sh -c 'command -v gdbserver' 2>/dev/null || true)
if [[ -z $GDBSERVER ]]; then
  [[ -n $LOCAL_GDBSERVER ]] || die "gdbserver not found in container; install it there or pass -g /path/to/gdbserver"
  podman cp "$LOCAL_GDBSERVER" "$C:/tmp/gdbserver"
  podman exec "$C" chmod +x /tmp/gdbserver
  GDBSERVER=/tmp/gdbserver
fi

# --privileged gives the exec session CAP_SYS_PTRACE, which attaching needs.
REMOTE_CMD="podman exec -i --privileged $C $GDBSERVER --attach - $PID"

# --- connect -----------------------------------------------------------------
if [[ $DBG == gdb ]]; then
  # gdb can run gdbserver itself and talk to it through a pipe.
  exec gdb ${BIN:+"$BIN"} -ex "target remote | $REMOTE_CMD"
fi

# lldb cannot use a pipe, so socat bridges a local TCP port to the exec session.
command -v socat >/dev/null || die "lldb mode needs socat (brew install socat)"
socat "TCP-LISTEN:$PORT,bind=127.0.0.1,reuseaddr" "EXEC:$REMOTE_CMD" &
SOCAT_PID=$!
trap 'kill $SOCAT_PID 2>/dev/null || true' EXIT
sleep 0.5
kill -0 "$SOCAT_PID" 2>/dev/null || die "socat failed to listen on port $PORT"
lldb ${BIN:+"$BIN"} -o "gdb-remote 127.0.0.1:$PORT"
