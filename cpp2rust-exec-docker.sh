#!/bin/sh
# cpp2rust-exec-docker.sh — run a binary inside the cpp2rust Docker image.
#
# Intended for binaries built by ./cpp2rust-compile-docker.sh (dynamically
# linked against the container's libraries), but works for any executable
# under the current directory:
#
#   ./cpp2rust-exec-docker.sh ./hello
#   ./cpp2rust-exec-docker.sh ./hello arg1 "arg 2"
#
# Program arguments are forwarded as-is and stdin is passed through.
# The image can be overridden with CPP2RUST_IMAGE:
#
#   CPP2RUST_IMAGE=cpp2rust:latest ./cpp2rust-exec-docker.sh ./hello
#
# NOTE: like cpp2rust-docker.sh, the binary must live under the current
# directory (that is what gets mounted).
set -eu

IMAGE="${CPP2RUST_IMAGE:-cpp2rust}"

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \?//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ""|-?*) echo "usage: $(basename "$0") BIN [PROGRAM_ARGS...]" >&2; exit 1 ;;
esac

BIN="$1"; shift
if [ ! -f "$BIN" ]; then
  echo "error: file not found: $BIN" >&2
  exit 1
fi
# exec does not look up bare names in the cwd, so qualify them.
case "$BIN" in
  */*) ;;
  *) BIN="./$BIN" ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found in PATH" >&2
  exit 1
fi

# -i so piped stdin reaches the program; -t only when attached to a tty.
TTY=""
[ -t 0 ] && TTY="-t"

# shellcheck disable=SC2086
exec docker run --rm -i $TTY \
  -u "$(id -u):$(id -g)" \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  --entrypoint sh "$IMAGE" \
  -c 'exec "$@"' cpp2rust-exec "$BIN" "$@"
