```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Configuration (override through the environment / CI matrix)
# ------------------------------------------------------------

TARGET="${TARGET:-aarch64-unknown-linux-musl}"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
COREMARK_REF="${COREMARK_REF:-master}"
ITERATIONS="${ITERATIONS:-0}"

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

BINARY_NAME="coremark-${TARGET}"
BINARY="$DIST_DIR/$BINARY_NAME"
ZIP="$ROOT_DIR/${BINARY_NAME}.zip"

# ------------------------------------------------------------
# Install Zig
# ------------------------------------------------------------

if [[ ! -x "$ZIG_DIR/zig" ]]; then
    case "$(uname -s)" in
        Linux)  HOST_OS="linux" ;;
        Darwin) HOST_OS="macos" ;;
        *) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  HOST_ARCH="x86_64" ;;
        aarch64|arm64) HOST_ARCH="aarch64" ;;
        *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
    esac

    # Zig >= 0.14 uses zig-<arch>-<os>-<version>
    ZIG_TARBALL="zig-${HOST_ARCH}-${HOST_OS}-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

    echo "==> Downloading Zig $ZIG_VERSION ($HOST_ARCH-$HOST_OS)"

    mkdir -p "$ZIG_DIR"

    curl -fL --retry 3 --retry-delay 2 \
        "$ZIG_URL" \
        -o "$ZIG_DIR/zig.tar.xz"

    tar -xf "$ZIG_DIR/zig.tar.xz" \
        -C "$ZIG_DIR" \
        --strip-components=1

    rm -f "$ZIG_DIR/zig.tar.xz"
fi

ZIG="$ZIG_DIR/zig"

echo "==> Zig $("$ZIG" version)"

# ------------------------------------------------------------
# Download CoreMark
# ------------------------------------------------------------

if [[ ! -d "$COREMARK_DIR/.git" ]]; then
    echo "==> Downloading CoreMark ($COREMARK_REF)"

    git clone \
        --depth=1 \
        --branch "$COREMARK_REF" \
        https://github.com/eembc/coremark.git \
        "$COREMARK_DIR"
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
echo "========================================"

cd "$COREMARK_DIR"

# coremark.h/COMPILER_FLAGS expands FLAGS_STR, so it must always be defined.
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

if command -v file >/dev/null 2>&1; then
    file "$BINARY"
fi

# Fail the build instead of shipping a wrong-architecture binary.
if command -v readelf >/dev/null 2>&1; then
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

rm -f "$ZIP" "$ROOT_DIR/${BINARY_NAME}.tar.gz"

(
    cd "$DIST_DIR"
    zip -9 "$ZIP" "$BINARY_NAME"
    tar -czf "$ROOT_DIR/${BINARY_NAME}.tar.gz" "$BINARY_NAME"
)

(
    cd "$ROOT_DIR"
    sha256sum "${BINARY_NAME}.zip" "${BINARY_NAME}.tar.gz" \
        > "${BINARY_NAME}.sha256"
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
echo "  $ROOT_DIR/${BINARY_NAME}.tar.gz"
echo
echo "Checksum:"
echo "  $ROOT_DIR/${BINARY_NAME}.sha256"
echo
echo "Smoke test on the target machine:"
echo "  ./$BINARY_NAME 0x0 0x0 0x66"
