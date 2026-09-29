Cpp2Rust
========

Cpp2Rust translates C++ to fully safe Rust automatically. It is a syntax-driven
translator based on clang's AST.

Cpp2Rust's algorithm is described in the paper
[Cpp2Rust: Automatic Translation of C++ to Safe Rust](https://web.ist.utl.pt/nuno.lopes/pubs/cpp2rust-pldi26.pdf)
published at PLDI 2026.

The [developer's manual](https://cpp2rust.github.io/cpp2rust/) describes how
Cpp2Rust works internally and how to extend it.


## Overview

Cpp2Rust first parses the input C++ file(s) with clang and produces an AST.
It then traverses the AST and emits Rust code as strings, inserting
calls to the `libcc2rs` runtime library where needed (e.g., for raw pointer
semantics).
Finally, the Rust code is pretty-printed using `rustfmt` to a single `.rs` file.

By default the *reference counting model* is used, which produces fully safe
Rust.
A generator of unsafe Rust is also available through the `--model=unsafe`
command line argument for debugging and performance comparisons.

### Runtime library (`libcc2rs`)

The generated code relies on a runtime library designed to simplify the
translation process.
C pointers are converted into the `Ptr<T>` type provided by `libcc2rs`.
`Ptr<T>` models C pointer semantics, including null, arithmetic, and aliasing,
while satisfying Rust's borrow checker through checked run-time operations.


## Requirements

On Ubuntu, install the required dependencies with:

```bash
sudo apt install libclang-23-dev clang++-23 ninja-build cmake
pip install ruff==0.15.22
```


## Build

```bash
mkdir build
cd build
cmake -GNinja ..
ninja
ninja check
```


## Docker

A multi-stage `Dockerfile` based on `debian:trixie-slim` is provided, so you
can run cpp2rust without installing LLVM and Rust locally.

```bash
docker build -t cpp2rust .
```

`cpp2rust-docker.sh` is a thin wrapper that mounts the current directory into
the container at the same absolute path and runs the container as your
UID/GID, so relative and absolute host paths keep working and generated
files keep the right ownership:

```bash
./cpp2rust-docker.sh --file=hello.cpp -o=hello.rs
./cpp2rust-docker.sh --file=hello.cpp -o=hello.rs --model=unsafe
```

It is equivalent to:

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" cpp2rust --file=hello.cpp -o=hello.rs
```

The image name can be overridden with `CPP2RUST_IMAGE`:

```bash
CPP2RUST_IMAGE=cpp2rust:latest ./cpp2rust-docker.sh --file=hello.cpp -o=hello.rs
```

### Translate a whole program (Docker)

Generate `compile_commands.json` as usual, then run the wrapper from the
project root. `compile_commands.json` records absolute host paths, which is
why the wrapper mounts the current directory at the same path inside the
container (a fixed mount point such as `/work` would break `--dir`):

```bash
cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON ..
./cpp2rust-docker.sh --dir=<dir> -o <output>.rs
```

### Compile and run the generated Rust code (Docker)

`cpp2rust-compile-docker.sh` compiles a translated `.rs` file inside the
container (the binary is dynamically linked against the container's
libraries, so it must also run there). The output defaults to the input
stem (`hello.rs` -> `./hello`):

```bash
./cpp2rust-compile-docker.sh hello.rs
./cpp2rust-compile-docker.sh -o hello hello.rs
```

`cpp2rust-exec-docker.sh` runs a binary inside the container. Program
arguments after the binary are forwarded as-is, and stdin is passed through:

```bash
./cpp2rust-exec-docker.sh ./hello
./cpp2rust-exec-docker.sh ./hello arg1 "arg 2"
```

Extra rustc flags can be appended with `CPP2RUST_RUSTFLAGS`, and the image
overridden with `CPP2RUST_IMAGE`, just like `cpp2rust-docker.sh`.

<details>
<summary>Equivalent manual command (reference)</summary>

The image ships the `libcc2rs` rlibs under `/opt/cpp2rust` and a Rust
toolchain, so the translated file can be compiled without leaving Docker.
The slim runtime image has no `cc`, so point rustc at the bundled `clang-23`.
Generated code also triggers harmless style warnings (fixed prelude imports,
extra parentheses, unused `argc`/`argv`, ignored `write!` results, ...), so
pass `-A warnings` like the project's own test suite does
(`tests/lit/lit/formats/Cpp2RustTest.py`):

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:$PWD" -w "$PWD" --entrypoint sh cpp2rust -c '
  rustc --edition 2024 hello.rs -o hello \
    -A warnings \
    -C linker=clang-23 \
    -L dependency=/opt/cpp2rust/libcc2rs-target/release/deps \
    -L dependency=/opt/cpp2rust/libc-dep-target/release/deps \
    --extern libcc2rs=/opt/cpp2rust/libcc2rs-target/release/liblibcc2rs.rlib \
    --extern libc=$(echo /opt/cpp2rust/libc-dep-target/release/deps/liblibc-*.rlib) \
    --extern nix=$(echo /opt/cpp2rust/libc-dep-target/release/deps/libnix-*.rlib) \
    --extern jiff=$(echo /opt/cpp2rust/libc-dep-target/release/deps/libjiff-*.rlib)'
./hello
```

</details>


## Run

### Translate a single file

```bash
./build/cpp2rust/cpp2rust --file=<file>.cpp -o=<file>.rs
```

By default, the reference counting model is used (fully safe output).
To generate unsafe Rust instead:

```bash
./build/cpp2rust/cpp2rust --file=<file>.cpp -o=<file>.rs --model=unsafe
```

**Minimal example.** Given `hello.cpp`:

```cpp
#include <cstdio>
int main() {
  printf("hello world\n");
  return 0;
}
```

Running `./build/cpp2rust/cpp2rust --file=hello.cpp -o=hello.rs` produces:

```rust
pub fn main() {
    std::process::exit(main_0());
}
fn main_0() -> i32 {
    println!("hello world");
    return 0;
}
```

Compile and run with:

```bash
rustc hello.rs -L build/libcc2rs-target/release
./hello
```

### Translate a whole program

First generate a
[`compile_commands.json`](https://clang.llvm.org/docs/JSONCompilationDatabase.html)
for your project. With CMake this is one extra flag:

```bash
cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON ..
```

Then run:

```bash
./build/cpp2rust/cpp2rust --dir=<dir> -o <output>.rs
```

`<dir>` must be the directory that contains `compile_commands.json`.


## Test Suite

```bash
# Run all tests
ninja check

# Run only the unit tests
ninja check-unit

# Run libcc2rs unit tests
ninja check-libcc2rs

# Run libcc2rs-macros unit tests
ninja check-libcc2rs-macros

# Regenerate expected output for unit tests after intentional changes
REPLACE_EXPECTED=1 ninja check-unit
```
