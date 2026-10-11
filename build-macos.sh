#!/usr/bin/env bash
#
# Build a native macOS CoreMark binary with clang and package the result.
#
# Everything the build needs ships with the macOS runner (clang, lipo, zip), so
# CI only has to run:
#
#     bash build-macos.sh
#
# The default target is an Apple Silicon (arm64) binary.
#
# Environment overrides:
#   TARGET        package label (see the case below)
#   COREMARK_REF  coremark git ref (default main)
#   ITERATIONS    CoreMark iterations define (default 0 = auto)
#   CC            compiler to use (default clang)
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Configuration (override through the environment / CI matrix)
# ------------------------------------------------------------

TARGET="${TARGET:-aarch64-apple-darwin}"
COREMARK_REF="${COREMARK_REF:-main}"
ITERATIONS="${ITERATIONS:-0}"
CC="${CC:-clang}"

case "$TARGET" in
    aarch64-apple-darwin) ARCH="arm64" ;;
    x86_64-apple-darwin)  ARCH="x86_64" ;;
    *) echo "unsupported TARGET: $TARGET" >&2; exit 1 ;;
esac

COREMARK_DIR="$ROOT_DIR/.coremark"
DIST_DIR="$ROOT_DIR/dist"

# The executable inside the archive is always named "coremark"; the archive and
# checksum file carry the target label.
BINARY_NAME="coremark"
PACKAGE_NAME="coremark-${TARGET}"

BINARY="$DIST_DIR/$BINARY_NAME"
ZIP="$ROOT_DIR/${PACKAGE_NAME}.zip"
SHAFILE="$ROOT_DIR/${PACKAGE_NAME}.sha256"

have() { command -v "$1" >/dev/null 2>&1; }

# macOS ships shasum, not coreutils' sha256sum.
sha256_of() {
    if have sha256sum; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

# ------------------------------------------------------------
# Host detection
# ------------------------------------------------------------

case "$(uname -s)" in
    Darwin) ;;
    *) echo "build-macos.sh requires macOS (got: $(uname -s))" >&2; exit 1 ;;
esac

if ! have "$CC"; then
    echo "ERROR: $CC not found; install the Xcode command line tools" >&2
    exit 1
fi

echo "==> $CC $("$CC" --version 2>&1 | head -n1)"

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
echo "Arch:   $ARCH"
echo "========================================"

cd "$COREMARK_DIR"

# coremark.h expands COMPILER_FLAGS to FLAGS_STR, so it must always be defined.
FLAGS_STR="$CC -O2 -arch $ARCH"

CFLAGS=(
    -O2
    -std=gnu99
    # Exposes the full host API (clock_gettime) regardless of the dialect.
    -D_DARWIN_C_SOURCE
    -DPERFORMANCE_RUN=1
    "-DITERATIONS=$ITERATIONS"
    "-DFLAGS_STR=\"$FLAGS_STR\""
    -I.
    -Iposix
    -arch "$ARCH"
)

# macos/ only carries core_portme.mak, the portable code lives in posix/.
"$CC" \
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
if have lipo; then
    echo
    echo "==> Mach-O"

    LIPO_ARCHS="$(lipo -archs "$BINARY")"
    echo "Archs: $LIPO_ARCHS"

    if [[ " $LIPO_ARCHS " != *" $ARCH "* ]]; then
        echo "ERROR: expected arch '$ARCH' in $BINARY" >&2
        exit 1
    fi
else
    echo "lipo not found, skipping Mach-O verification"
fi

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

echo
echo "==> Creating package"

rm -f "$ZIP" "$SHAFILE"

(
    cd "$DIST_DIR"
    zip -9 "$ZIP" "$BINARY_NAME"
)

(
    cd "$ROOT_DIR"
    sha256_of "$(basename "$ZIP")" > "$(basename "$SHAFILE")"
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
echo
echo "Checksum:"
echo "  $SHAFILE"
echo
echo "Run on macOS:"
echo "  ./$BINARY_NAME 0x0 0x0 0x66"
