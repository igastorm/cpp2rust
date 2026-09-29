# syntax=docker/dockerfile:1
#
# cpp2rust execution container (Debian trixie-slim, multi-stage).
#
#   docker build -t cpp2rust .
#   ./cpp2rust-docker.sh --file=hello.cpp -o=hello.rs
#   ./cpp2rust-docker.sh --dir=build -o=out.rs
#
# The C++ frontend needs Clang 23, which is not in Debian trixie proper,
# so both stages fetch it from https://apt.llvm.org (suite
# llvm-toolchain-trixie-23). Keep LLVM_VERSION in sync with README.md
# (libclang-XX-dev) and CI (.github/workflows/run-tests.yml).
ARG LLVM_VERSION=23

# ---------------------------------------------------------------------------
# Builder: compile cpp2rust + preprocess translation rules + build rlibs.
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS builder

ARG LLVM_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# 1) Toolchain repo (apt.llvm.org). trixie-slim ships without curl/gnupg,
#    so bootstrap them from the stock Debian mirrors first.
#    Layout follows https://apt.llvm.org/llvm.sh for new Debian releases
#    (DEB822 source, keyring in /etc/apt/trusted.gpg.d).
# NOTE: llvm-XX-dev does not depend on the transitive -dev packages that
# LLVMExports.cmake turns into IMPORTED targets (ZLIB::ZLIB, zstd, LibEdit,
# CURL, ...); ubuntu runners only work by accident (preinstalled), so they
# are listed explicitly in the install step below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        -o /etc/apt/trusted.gpg.d/apt.llvm.org.asc \
    && printf '%s\n' \
        'Types: deb' \
        'Architectures: amd64 arm64' \
        'Signed-By: /etc/apt/trusted.gpg.d/apt.llvm.org.asc' \
        "URIs: https://apt.llvm.org/trixie/" \
        "Suites: llvm-toolchain-trixie-${LLVM_VERSION}" \
        'Components: main' \
        > /etc/apt/sources.list.d/llvm.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        cmake \
        ninja-build \
        python3 \
        git \
        clang-${LLVM_VERSION} \
        llvm-${LLVM_VERSION}-dev \
        libclang-${LLVM_VERSION}-dev \
        libclang-cpp${LLVM_VERSION}-dev \
        libclang-rt-${LLVM_VERSION}-dev \
        zlib1g-dev \
        libzstd-dev \
        libedit-dev \
        libcurl4-openssl-dev \
        libffi-dev \
        libxml2-dev \
        libncurses-dev \
    && rm -rf /var/lib/apt/lists/*

# 2) rustup (minimal profile). The actual toolchains
#    (stable + nightly, see cmake/rust-toolchain.cmake) are installed on
#    demand by CMake via the .rust-toolchain.stamp custom command.
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain none \
    && rustup --version

# 3) Build. Source lives at /src on purpose: cpp2rust bakes absolute paths
#    (COMPAT_INCLUDE_DIR=/src/cpp2rust/compat, CLANG_RESOURCE_DIR under
#    /usr/lib/llvm-XX) into the binary, and the runtime stage below
#    reproduces /src/cpp2rust/compat so the binary keeps working.
WORKDIR /src
COPY . /src
RUN cmake -S /src -B /src/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang-${LLVM_VERSION} \
        -DCMAKE_CXX_COMPILER=clang++-${LLVM_VERSION} \
    && cmake --build /src/build

# ---------------------------------------------------------------------------
# Runtime: cpp2rust binary + preprocessed rules + compat headers + Rust stable
# (for the `rustfmt +<stable>` call) + Clang 23 runtime (resource dir) +
# libcc2rs rlibs (for compiling the generated Rust output).
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS runtime

ARG LLVM_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# 1) Clang runtime. clang-${LLVM_VERSION} pulls libllvm, libclang-cpp and
#    libclang-common (which provides CLANG_RESOURCE_DIR, e.g.
#    /usr/lib/llvm-23/lib/clang/23) via dependencies.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        -o /etc/apt/trusted.gpg.d/apt.llvm.org.asc \
    && printf '%s\n' \
        'Types: deb' \
        'Architectures: amd64 arm64' \
        'Signed-By: /etc/apt/trusted.gpg.d/apt.llvm.org.asc' \
        "URIs: https://apt.llvm.org/trixie/" \
        "Suites: llvm-toolchain-trixie-${LLVM_VERSION}" \
        'Components: main' \
        > /etc/apt/sources.list.d/llvm.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        clang-${LLVM_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# 2) Rust stable only (nightly is a build-time dependency of
#    rule-preprocessor). Version is read from cmake/rust-toolchain.cmake
#    copied out of the builder so it cannot drift from the C++ binary's
#    baked-in `rustfmt +<stable>` invocation.
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:$PATH
COPY --from=builder /src/cmake/rust-toolchain.cmake /tmp/rust-toolchain.cmake
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain none \
    && STABLE="$(sed -n 's/.*RUST_STABLE_VERSION *"\([^"]*\)".*/\1/p' /tmp/rust-toolchain.cmake)" \
    && test -n "$STABLE" \
    && rustup toolchain install "$STABLE" --component rustfmt \
    && rustup default "$STABLE" \
    && rustup show \
    && rm /tmp/rust-toolchain.cmake

# 3) cpp2rust artifacts.
#    - binary -> /usr/local/bin (resolves rules via <exe-dir>/../rules)
#    - preprocessed rules IR (build/rules) -> /usr/local/rules
#    - compat headers -> /src/cpp2rust/compat (baked-in absolute path)
COPY --from=builder /src/build/cpp2rust/cpp2rust /usr/local/bin/cpp2rust
COPY --from=builder /src/build/rules /usr/local/rules
COPY --from=builder /src/cpp2rust/compat /src/cpp2rust/compat

# 4) rlibs for compiling the generated Rust code, e.g.:
#      rustc hello.rs -L /opt/cpp2rust/libcc2rs-target/release \
#        -L /opt/cpp2rust/libc-dep-target/release/deps --extern ...
#    (see tests/lit/lit/formats/Cpp2RustTest.py for the full rustc flags).
COPY --from=builder /src/build/libcc2rs-target/release/liblibcc2rs.rlib \
    /opt/cpp2rust/libcc2rs-target/release/liblibcc2rs.rlib
COPY --from=builder /src/build/libcc2rs-target/release/deps \
    /opt/cpp2rust/libcc2rs-target/release/deps
COPY --from=builder /src/build/libc-dep-target/release/deps \
    /opt/cpp2rust/libc-dep-target/release/deps

WORKDIR /work
ENTRYPOINT ["cpp2rust"]
CMD ["--help"]
