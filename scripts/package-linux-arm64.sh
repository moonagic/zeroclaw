#!/usr/bin/env bash
# ==============================================================================
# package-linux-arm64.sh
#
# Builds and packages ZeroClaw release archives for aarch64-unknown-linux-gnu
# (ARM64 Linux, e.g. Raspberry Pi 4/5, AWS Graviton, Debian/Ubuntu arm64, etc.)
#
# Usage:
#   ./scripts/package-linux-arm64.sh [--build] [--output-dir DIR]
#
# Options:
#   --build       Compile the release binary before packaging
#   --output-dir  Directory to read/write binaries and archives (default: ./dist-linux-arm64)
#   --help        Show this help message
# ==============================================================================
set -euo pipefail

TARGET="aarch64-unknown-linux-gnu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/dist-linux-arm64"
DO_BUILD=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Packages ZeroClaw for ${TARGET} into zeroclaw-${TARGET}.tar.gz.

Options:
  --build           Compile the release binary first.
                    - On native ARM64 Linux: uses native cargo/gcc.
                    - On macOS (Apple Silicon): uses cargo-zigbuild for native cross-compiling.
  --output-dir DIR  Custom output directory (default: ./dist-linux-arm64).
  -h, --help        Show this help message.

Environment variables:
  OUTPUT_DIR        Overrides the default output directory.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            DO_BUILD=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

cd "$REPO_ROOT"
mkdir -p "$OUTPUT_DIR"

find_binary() {
    if [ -f "$OUTPUT_DIR/zeroclaw" ]; then
        echo "$OUTPUT_DIR/zeroclaw"
    elif [ -f "$REPO_ROOT/target/$TARGET/release/zeroclaw" ]; then
        echo "$REPO_ROOT/target/$TARGET/release/zeroclaw"
    elif [ -f "$REPO_ROOT/target/release/zeroclaw" ] && [ "$(uname -m)" = "aarch64" ] && [ "$(uname -s)" = "Linux" ]; then
        echo "$REPO_ROOT/target/release/zeroclaw"
    fi
}

BIN_PATH="$(find_binary)"

if [ "$DO_BUILD" = false ] && [ -z "$BIN_PATH" ]; then
    echo "==> No existing binary found for ${TARGET}. Automatically starting build..."
    DO_BUILD=true
fi

if [ "$DO_BUILD" = true ]; then
    echo "==> Preparing to build release binary for ${TARGET}..."
    FEATURES="acp-bridge,agent-runtime,channel-acp-server,channel-discord,channel-email,channel-filesystem,channel-git,channel-lark,channel-matrix,channel-telegram,channel-webhook,gateway,observability-prometheus,plugins-wasm-cranelift,schema-export,tool-claude-code,tool-claude-code-runner,tool-codex-cli,tool-composio,tool-gemini-cli,tool-google-workspace,tool-jira,tool-linkedin,tool-microsoft365,tool-notion,tool-opencode-cli,tool-project-intel,tools-external,whatsapp-web"

    OS_TYPE="$(uname -s)"
    ARCH_TYPE="$(uname -m)"

    if [ "$OS_TYPE" = "Linux" ] && [ "$ARCH_TYPE" = "aarch64" ]; then
        # ── 1. Native ARM64 Linux Build ──────────────────────────────
        echo "==> Detected native ARM64 Linux environment ($ARCH_TYPE)."

        # Check required build tools
        MISSING_TOOLS=()
        for cmd in cargo gcc g++ pkg-config; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                MISSING_TOOLS+=("$cmd")
            fi
        done

        if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
            echo "Error: Missing required build tools: ${MISSING_TOOLS[*]}" >&2
            echo "Install them using your package manager, for example:" >&2
            echo "  Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y build-essential pkg-config" >&2
            echo "  RHEL/Fedora:   sudo dnf groupinstall 'Development Tools' && sudo dnf install pkgconf-pkg-config" >&2
            echo "  Arch Linux:    sudo pacman -S base-devel" >&2
            exit 1
        fi

        echo "==> Building natively via cargo..."
        cargo build \
            --release \
            --locked \
            --target "${TARGET}" \
            --no-default-features \
            --features "${FEATURES}"

        mkdir -p "$OUTPUT_DIR"
        cp "target/${TARGET}/release/zeroclaw" "$OUTPUT_DIR/zeroclaw"
        strip "$OUTPUT_DIR/zeroclaw" 2>/dev/null || true

    elif [ "$OS_TYPE" = "Darwin" ]; then
        # ── 2. Cross-compiling from macOS (Apple Silicon) ─────────────
        echo "==> Running on macOS ($ARCH_TYPE). Using cargo-zigbuild for ARM64 Linux cross-compilation..."
        export PATH="/opt/homebrew/bin:$PATH"

        if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
            rustup target add "${TARGET}" >/dev/null 2>&1 || true
            cargo zigbuild \
                --release \
                --locked \
                --target "${TARGET}.2.28" \
                --no-default-features \
                --features "${FEATURES}"

            mkdir -p "$OUTPUT_DIR"
            cp "target/${TARGET}/release/zeroclaw" "$OUTPUT_DIR/zeroclaw"
            strip "$OUTPUT_DIR/zeroclaw" 2>/dev/null || true
        else
            echo "Error: cargo-zigbuild or zig not found." >&2
            echo "Please install them via: brew install zig && cargo install cargo-zigbuild" >&2
            exit 1
        fi
    else
        echo "Error: Unsupported build platform: $OS_TYPE on $ARCH_TYPE" >&2
        echo "Please compile natively on an ARM64 Linux host or cross-compile with cargo-zigbuild on macOS." >&2
        exit 1
    fi
fi

# Locate the compiled binary
BIN_PATH="$(find_binary)"

if [ -z "$BIN_PATH" ] || [ ! -f "$BIN_PATH" ]; then
    echo "Error: Could not find compiled binary 'zeroclaw' for ${TARGET}." >&2
    echo "Checked: $OUTPUT_DIR/zeroclaw and target/${TARGET}/release/zeroclaw" >&2
    echo "Run with '--build' to compile it first, or place the binary in $OUTPUT_DIR." >&2
    exit 1
fi

echo "==> Found binary: $BIN_PATH"
file "$BIN_PATH" || true

# Prepare staging directory
STAGING_DIR="$(mktemp -d /tmp/zeroclaw-package-XXXXXX)"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "==> Preparing staging area at $STAGING_DIR..."
cp "$BIN_PATH" "$STAGING_DIR/zeroclaw"
chmod 755 "$STAGING_DIR/zeroclaw"

# Include optional companions if available
for companion in zerocode zerorelay; do
    if [ -f "$OUTPUT_DIR/$companion" ]; then
        echo "==> Bundling companion: $companion"
        cp "$OUTPUT_DIR/$companion" "$STAGING_DIR/$companion"
        chmod 755 "$STAGING_DIR/$companion"
    elif [ -f "$REPO_ROOT/target/$TARGET/release/$companion" ]; then
        echo "==> Bundling companion: $companion"
        cp "$REPO_ROOT/target/$TARGET/release/$companion" "$STAGING_DIR/$companion"
        chmod 755 "$STAGING_DIR/$companion"
    elif [ -f "$REPO_ROOT/target/release/$companion" ] && [ "$(uname -m)" = "aarch64" ] && [ "$(uname -s)" = "Linux" ]; then
        echo "==> Bundling companion: $companion"
        cp "$REPO_ROOT/target/release/$companion" "$STAGING_DIR/$companion"
        chmod 755 "$STAGING_DIR/$companion"
    fi
done

# Include web dashboard if built
if [ -d "$REPO_ROOT/web/dist" ]; then
    echo "==> Bundling web dashboard (web/dist)..."
    mkdir -p "$STAGING_DIR/web"
    cp -r "$REPO_ROOT/web/dist" "$STAGING_DIR/web/"
fi

# Create archive
ARCHIVE_PATH="$OUTPUT_DIR/zeroclaw-${TARGET}.tar.gz"
echo "==> Creating tarball: $ARCHIVE_PATH..."
tar -czf "$ARCHIVE_PATH" -C "$STAGING_DIR" .

# Generate checksum
echo "==> Generating SHA-256 checksum..."
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUTPUT_DIR" && sha256sum "zeroclaw-${TARGET}.tar.gz" > "zeroclaw-${TARGET}.tar.gz.sha256")
elif command -v shasum >/dev/null 2>&1; then
    (cd "$OUTPUT_DIR" && shasum -a 256 "zeroclaw-${TARGET}.tar.gz" > "zeroclaw-${TARGET}.tar.gz.sha256")
fi

echo "==> Package complete!"
ls -lh "$OUTPUT_DIR"/zeroclaw-${TARGET}.tar.gz*
cat "$OUTPUT_DIR/zeroclaw-${TARGET}.tar.gz.sha256"
