#!/bin/sh
# cpp2rust-compile-docker.sh — compile a generated .rs file inside the
# cpp2rust Docker image.
#
#   ./cpp2rust-compile-docker.sh hello.rs
#   ./cpp2rust-compile-docker.sh -o hello hello.rs
#
# The output defaults to the input stem (hello.rs -> ./hello). Run the
# resulting binary with ./cpp2rust-exec-docker.sh.
#
# The image can be overridden with CPP2RUST_IMAGE, and extra rustc flags
# appended with CPP2RUST_RUSTFLAGS:
#
#   CPP2RUST_IMAGE=cpp2rust:latest ./cpp2rust-compile-docker.sh hello.rs
#   CPP2RUST_RUSTFLAGS="-C opt-level=0" ./cpp2rust-compile-docker.sh hello.rs
#
# NOTE: like cpp2rust-docker.sh, the .rs file and the output must live under
# the current directory (that is what gets mounted).
set -eu

IMAGE="${CPP2RUST_IMAGE:-cpp2rust}"

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \?//'
}

OUT=""
SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)
      OUT="${2:?option $1 needs an argument}"; shift 2 ;;
    -o?*|--out=?*)
      OUT="${1#*=}"; OUT="${OUT#-o}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -?*)
      echo "error: unknown option: $1" >&2; exit 1 ;;
    *)
      SRC="$1"; shift; break ;;
  esac
done

if [ -z "$SRC" ]; then
  echo "usage: $(basename "$0") [-o OUT] FILE.rs" >&2
  exit 1
fi
if [ ! -f "$SRC" ]; then
  echo "error: file not found: $SRC" >&2
  exit 1
fi
if [ $# -gt 0 ]; then
  echo "error: unexpected argument: $1" >&2
  exit 1
fi
if [ -z "$OUT" ]; then
  case "$SRC" in
    *.rs) OUT="${SRC%.rs}" ;;
    *) OUT="$SRC.out" ;;
  esac
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found in PATH" >&2
  exit 1
fi

# Runs inside the container: $1 = source, $2 = output.
BUILD=$(cat <<'SCRIPT'
set -eu
src="$1"; out="$2"
# shellcheck disable=SC2086
rustc --edition 2024 "$src" -o "$out" \
  -A warnings \
  -C linker=clang-23 \
  -L dependency=/opt/cpp2rust/libcc2rs-target/release/deps \
  -L dependency=/opt/cpp2rust/libc-dep-target/release/deps \
  --extern libcc2rs=/opt/cpp2rust/libcc2rs-target/release/liblibcc2rs.rlib \
  --extern libc=$(echo /opt/cpp2rust/libc-dep-target/release/deps/liblibc-*.rlib) \
  --extern nix=$(echo /opt/cpp2rust/libc-dep-target/release/deps/libnix-*.rlib) \
  --extern jiff=$(echo /opt/cpp2rust/libc-dep-target/release/deps/libjiff-*.rlib) \
  ${CPP2RUST_RUSTFLAGS:-}
SCRIPT
)

exec docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  --entrypoint sh "$IMAGE" \
  -c "$BUILD" cpp2rust-compile "$SRC" "$OUT"
