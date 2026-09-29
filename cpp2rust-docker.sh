#!/bin/sh
# cpp2rust-docker.sh — run the cpp2rust Docker image.
#
# Mounts the current directory into the container at the same absolute path
# and runs the container as your UID/GID, so relative and absolute host
# paths keep working and generated files keep the right ownership:
#
#   ./cpp2rust-docker.sh --file=hello.cpp -o=hello.rs
#   ./cpp2rust-docker.sh --dir=build -o=out.rs
#
# The image can be overridden with CPP2RUST_IMAGE:
#
#   CPP2RUST_IMAGE=cpp2rust:latest ./cpp2rust-docker.sh --file=hello.cpp -o=hello.rs
#
# NOTE: every translated input/output path must live under the current
# directory (that is what gets mounted). In particular, the absolute paths
# recorded in compile_commands.json must match the host layout, so run from
# the project root. A fixed mount point such as /work would break --dir.
set -eu

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found in PATH" >&2
  exit 1
fi

IMAGE="${CPP2RUST_IMAGE:-cpp2rust}"

# --read-only: the container never writes to its own filesystem, so it stays
# reusable. Anything that must be writable (temp files, caches) goes to the
# tmpfs mounted at /tmp; inputs/outputs live on the mounted work directory.
exec docker run --rm --read-only --tmpfs /tmp \
  -u "$(id -u):$(id -g)" \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  "$IMAGE" "$@"
