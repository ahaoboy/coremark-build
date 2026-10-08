#!/usr/bin/env bash
#
# Cross-compile CoreMark with Zig and package the result.
#
# Everything the build needs (Zig toolchain, packaging tools, optional Zig cache
# reuse) is handled by this script, so CI only has to run:
#
#     bash build-musl.sh
#
# Environment overrides:
#   TARGET        rust-style target triple (default aarch64-unknown-linux-musl)
#   ZIG_VERSION   pinned Zig version; default is the latest stable release
#   COREMARK_REF  coremark git ref (default main)
#   ITERATIONS    CoreMark iterations define (default 0 = auto)
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Configuration (override through the environment / CI matrix)
# ------------------------------------------------------------

TARGET="${TARGET:-aarch64-unknown-linux-musl}"
ZIG_VERSION="${ZIG_VERSION:-}"
COREMARK_REF="${COREMARK_REF:-main}"
ITERATIONS="${ITERATIONS:-0}"

# Bump when the layout/content of the cached Zig directory changes.
ZIG_CACHE_VERSION="1"

# aarch64-unknown-linux-musl -> aarch64-linux-musl
case "$TARGET" in
    *-unknown-linux-musl) ZIG_TARGET="${TARGET%-unknown-linux-musl}-linux-musl" ;;
    *-unknown-linux-gnu)  ZIG_TARGET="${TARGET%-unknown-linux-gnu}-linux-gnu" ;;
    *-linux-musl|*-linux-gnu) ZIG_TARGET="$TARGET" ;;
    *) echo "unsupported TARGET: $TARGET" >&2; exit 1 ;;
esac

COREMARK_DIR="$ROOT_DIR/.coremark"
ZIG_DIR="$ROOT_DIR/.zig"
DIST_DIR="$ROOT_DIR/dist"

# The executable inside the archives is always named "coremark"; the archives
# and checksum file carry the target triple.
BINARY_NAME="coremark"
PACKAGE_NAME="coremark-${TARGET}"

BINARY="$DIST_DIR/$BINARY_NAME"
ZIP="$ROOT_DIR/${PACKAGE_NAME}.zip"
TARBALL="$ROOT_DIR/${PACKAGE_NAME}.tar.gz"
SHAFILE="$ROOT_DIR/${PACKAGE_NAME}.sha256"

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# Host detection
# ------------------------------------------------------------

case "$(uname -s)" in
    Linux)  HOST_OS="linux" ;;
    Darwin) HOST_OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
    *) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  HOST_ARCH="x86_64" ;;
    aarch64|arm64) HOST_ARCH="aarch64" ;;
    *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

if [[ "$HOST_OS" == "windows" ]]; then
    ZIG="$ZIG_DIR/zig.exe"
else
    ZIG="$ZIG_DIR/zig"
fi

# ------------------------------------------------------------
# Tool installation (no-op when everything is already present)
# ------------------------------------------------------------

# Run a command as root when the current user is not root and sudo exists.
run_privileged() {
    if [[ "$(id -u)" != "0" ]] && have sudo; then
        sudo "$@"
    else
        "$@"
    fi
}

install_packages() {
    local pkgs=("$@")

    if have apt-get; then
        run_privileged apt-get update -qq
        run_privileged apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
    elif have apk; then
        run_privileged apk add --no-cache "${pkgs[@]}"
    elif have pacman; then
        run_privileged pacman -S --noconfirm --needed "${pkgs[@]}"
    elif have dnf; then
        run_privileged dnf install -y "${pkgs[@]}"
    elif have yum; then
        run_privileged yum install -y "${pkgs[@]}"
    else
        echo "no supported package manager; please install: ${pkgs[*]}" >&2
        return 1
    fi
}

# Tools needed to download/unpack and to package the result.
REQUIRED_TOOLS=(curl tar zip)
[[ "$HOST_OS" == "windows" ]] && REQUIRED_TOOLS+=(unzip)

missing=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    have "$tool" || missing+=("$tool")
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "==> Installing missing tools: ${missing[*]}"
    install_packages "${missing[@]}"
fi

# Verification tools are optional, install them best-effort.
if ! have readelf || ! have file; then
    install_packages file binutils || true
fi

# ------------------------------------------------------------
# Resolve the Zig version (latest stable unless pinned)
# ------------------------------------------------------------

if [[ -z "$ZIG_VERSION" ]]; then
    echo "==> Resolving latest stable Zig"

    # The index is emitted newest-first, so the first release-looking key wins.
    ZIG_VERSION="$(
        curl -fsSL --retry 3 https://ziglang.org/download/index.json 2>/dev/null \
            | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"[[:space:]]*:' \
            | head -n1 \
            | tr -dc '0-9.'
    )" || true

    if [[ -z "$ZIG_VERSION" ]]; then
        ZIG_VERSION="0.17.0"
        echo "==> Could not query ziglang.org, falling back to Zig $ZIG_VERSION"
    fi
fi

# ------------------------------------------------------------
# GitHub Actions cache (best-effort; silently skipped elsewhere)
# ------------------------------------------------------------

cache_enabled() {
    [[ -n "${ACTIONS_CACHE_URL:-}" && -n "${ACTIONS_RUNTIME_TOKEN:-}" ]]
}

cache_key() {
    echo "zig-${HOST_OS}-${HOST_ARCH}-${ZIG_VERSION}"
}

cache_restore() {
    cache_enabled || return 1
    have tar || return 1

    local base="${ACTIONS_CACHE_URL%/}" key location response
    key="$(cache_key)"

    response="$(
        curl -fsS \
            -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
            -H "Accept: application/json;api-version=6.0-preview.1" \
            "$base/_apis/artifactcache/cache?keys=$key&version=$ZIG_CACHE_VERSION"
    )" || return 1

    location="$(printf '%s' "$response" \
        | grep -o '"archiveLocation":"[^"]*"' | head -n1 | cut -d'"' -f4)"

    [[ -n "$location" ]] || return 1

    mkdir -p "$ZIG_DIR"
    curl -fsSL \
        -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
        "$location" -o "$ZIG_DIR/cache.tar" || return 1

    tar -xf "$ZIG_DIR/cache.tar" -C "$ZIG_DIR"
    rm -f "$ZIG_DIR/cache.tar"
}

cache_save() {
    cache_enabled || return 0

    local base="${ACTIONS_CACHE_URL%/}" key id size tmp
    key="$(cache_key)"
    tmp="$(mktemp -d)"

    # Reserve the key first; an existing entry returns a non-zero status and the
    # archive is then never built.
    size=0
    if have du; then
        size="$(du -sb "$ZIG_DIR" 2>/dev/null | cut -f1)"
        [[ -n "$size" ]] || size=0
    fi

    id="$(
        curl -fsS -X POST \
            -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
            -H "Accept: application/json;api-version=6.0-preview.1" \
            -H "Content-Type: application/json" \
            --data "{\"key\":\"$key\",\"version\":\"$ZIG_CACHE_VERSION\",\"cacheSize\":$size}" \
            "$base/_apis/artifactcache/caches" \
            | grep -o '"cacheId":[0-9]*' | cut -d: -f2
    )" || { rm -rf "$tmp"; return 0; }

    if [[ -z "$id" ]]; then
        rm -rf "$tmp"
        return 0
    fi

    tar -cf "$tmp/zig.tar" -C "$ZIG_DIR" .
    size="$(wc -c < "$tmp/zig.tar" | tr -d '[:space:]')"

    if curl -fsS -X PATCH \
        -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
        -H "Content-Type: application/octet-stream" \
        -H "Content-Range: bytes 0-$((size - 1))/$size" \
        --data-binary @"$tmp/zig.tar" \
        "$base/_apis/artifactcache/caches/$id"; then
        curl -fsS -X POST \
            -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
            -H "Accept: application/json;api-version=6.0-preview.1" \
            -H "Content-Type: application/json" \
            --data "{\"size\":$size}" \
            "$base/_apis/artifactcache/caches/$id" || true
    fi

    rm -rf "$tmp"
}

# ------------------------------------------------------------
# Install Zig
# ------------------------------------------------------------

if [[ ! -x "$ZIG" ]]; then
    mkdir -p "$ZIG_DIR"

    if cache_restore; then
        ZIG_FROM_CACHE=1
        echo "==> Restored Zig $ZIG_VERSION from the GitHub Actions cache"
    elif [[ "$HOST_OS" == "windows" ]]; then
        ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-${HOST_ARCH}-windows-${ZIG_VERSION}.zip"

        echo "==> Downloading Zig $ZIG_VERSION ($HOST_ARCH-$HOST_OS)"
        curl -fL --retry 3 --retry-delay 2 \
            "$ZIG_URL" -o "$ZIG_DIR/zig.zip"

        mkdir -p "$ZIG_DIR/.extract"
        unzip -q "$ZIG_DIR/zig.zip" -d "$ZIG_DIR/.extract"

        inner="$(find "$ZIG_DIR/.extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
        mv "$inner"/* "$ZIG_DIR"/
        rm -rf "$ZIG_DIR/.extract" "$ZIG_DIR/zig.zip"
    else
        ZIG_TARBALL="zig-${HOST_ARCH}-${HOST_OS}-${ZIG_VERSION}.tar.xz"
        ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

        echo "==> Downloading Zig $ZIG_VERSION ($HOST_ARCH-$HOST_OS)"
        curl -fL --retry 3 --retry-delay 2 \
            "$ZIG_URL" -o "$ZIG_DIR/zig.tar.xz"
        tar -xf "$ZIG_DIR/zig.tar.xz" -C "$ZIG_DIR" --strip-components=1
        rm -f "$ZIG_DIR/zig.tar.xz"
    fi
fi

if [[ ! -x "$ZIG" ]]; then
    echo "Zig is missing at $ZIG" >&2
    exit 1
fi

echo "==> Zig $("$ZIG" version)"

# Persist a freshly installed toolchain for the next run (no-op outside
# GitHub Actions, and skipped when this run already came from the cache).
if [[ "${ZIG_FROM_CACHE:-0}" != "1" ]]; then
    cache_save
fi

# ------------------------------------------------------------
# Download CoreMark
# ------------------------------------------------------------

if [[ ! -d "$COREMARK_DIR/.git" ]]; then
    echo "==> Downloading CoreMark ($COREMARK_REF)"

    # Drop a stale/partial checkout so the clone cannot fail on the target dir.
    rm -rf "$COREMARK_DIR"

    git clone \
        --depth=1 \
        --branch "$COREMARK_REF" \
        https://github.com/eembc/coremark.git \
        "$COREMARK_DIR"
fi

if [[ ! -f "$COREMARK_DIR/core_main.c" ]]; then
    echo "ERROR: CoreMark sources are missing in $COREMARK_DIR" >&2
    exit 1
fi

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo
echo "========================================"
echo "Building CoreMark"
echo "========================================"
echo "Target: $TARGET"
echo "Zig:    $("$ZIG" version)"
echo "========================================"

cd "$COREMARK_DIR"

# coremark.h expands COMPILER_FLAGS to FLAGS_STR, so it must always be defined.
FLAGS_STR="zig cc -target $ZIG_TARGET -O2 -static"

CFLAGS=(
    -target "$ZIG_TARGET"
    -O2
    -static
    -std=gnu99
    -DPERFORMANCE_RUN=1
    "-DITERATIONS=$ITERATIONS"
    "-DFLAGS_STR=\"$FLAGS_STR\""
    -I.
    -Iposix
)

# The portable layer lives in posix/ (linux/ only carries core_portme.mak).
"$ZIG" cc \
    "${CFLAGS[@]}" \
    core_main.c \
    core_list_join.c \
    core_matrix.c \
    core_state.c \
    core_util.c \
    posix/core_portme.c \
    -o "$BINARY"

chmod +x "$BINARY"

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------

echo
echo "==> Binary"

if have file; then
    file "$BINARY"
fi

# Fail the build instead of shipping a wrong-architecture binary.
if have readelf; then
    echo
    echo "==> ELF"

    ELF_HEADER="$(readelf -h "$BINARY")"
    echo "$ELF_HEADER" | grep -E 'Class:|Machine:|Type:'

    case "$TARGET" in
        aarch64-*) EXPECT_MACHINE="AArch64" ;;
        x86_64-*)  EXPECT_MACHINE="X86-64" ;;
        *)         EXPECT_MACHINE="" ;;
    esac

    if [[ -n "$EXPECT_MACHINE" ]] && \
       ! grep -q "Machine:.*$EXPECT_MACHINE" <<<"$ELF_HEADER"; then
        echo "ERROR: expected Machine '$EXPECT_MACHINE' for $TARGET" >&2
        exit 1
    fi

    if readelf -l "$BINARY" | grep -q INTERP; then
        echo "ERROR: binary is dynamically linked" >&2
        exit 1
    fi

    echo "Static: yes"
else
    echo "readelf not found, skipping ELF verification"
fi

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

echo
echo "==> Creating package"

rm -f "$ZIP" "$TARBALL" "$SHAFILE"

(
    cd "$DIST_DIR"
    zip -9 "$ZIP" "$BINARY_NAME"
    tar -czf "$TARBALL" "$BINARY_NAME"
)

(
    cd "$ROOT_DIR"
    sha256sum "$(basename "$ZIP")" "$(basename "$TARBALL")" \
        > "$(basename "$SHAFILE")"
)

echo
echo "========================================"
echo "Done"
echo "========================================"
echo
echo "Binary:"
echo "  $BINARY"
echo
echo "Package:"
echo "  $ZIP"
echo "  $TARBALL"
echo
echo "Checksum:"
echo "  $SHAFILE"
