```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COREMARK_DIR="$ROOT_DIR/.coremark"
ZIG_DIR="$ROOT_DIR/.zig"
DIST_DIR="$ROOT_DIR/dist"

ZIG_VERSION="0.15.2"

TARGET="aarch64-unknown-linux-musl"
ZIG_TARGET="aarch64-linux-musl"

BINARY_NAME="coremark-${TARGET}"
BINARY="$DIST_DIR/$BINARY_NAME"
ZIP="$ROOT_DIR/${BINARY_NAME}.zip"

# ------------------------------------------------------------
# Install Zig
# ------------------------------------------------------------

if [[ ! -x "$ZIG_DIR/zig" ]]; then
    echo "==> Downloading Zig $ZIG_VERSION"

    mkdir -p "$ZIG_DIR"

    wget -q --show-progress \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -O "$ZIG_DIR/zig.tar.xz"

    tar -xf "$ZIG_DIR/zig.tar.xz" \
        -C "$ZIG_DIR" \
        --strip-components=1
fi

ZIG="$ZIG_DIR/zig"

echo "==> Zig $("$ZIG" version)"

# ------------------------------------------------------------
# Download CoreMark
# ------------------------------------------------------------

if [[ ! -d "$COREMARK_DIR" ]]; then
    echo "==> Downloading CoreMark"

    git clone \
        --depth=1 \
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

"$ZIG" cc \
    -target "$ZIG_TARGET" \
    -O2 \
    -static \
    -DPERFORMANCE_RUN=1 \
    -I. \
    -Ilinux \
    core_main.c \
    core_list_join.c \
    core_matrix.c \
    core_state.c \
    core_util.c \
    linux/core_portme.c \
    -o "$BINARY"

chmod +x "$BINARY"

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------

echo
echo "==> Binary"

file "$BINARY"

echo
echo "==> ELF"

readelf -h "$BINARY" | grep -E \
    'Class:|Machine:|Type:'

if readelf -l "$BINARY" | grep -q INTERP; then
    echo "WARNING: dynamically linked"
else
    echo "Static: yes"
fi

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

echo
echo "==> Creating package"

rm -f "$ZIP"

(
    cd "$DIST_DIR"
    zip -9 "$ZIP" "$BINARY_NAME"
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
```
