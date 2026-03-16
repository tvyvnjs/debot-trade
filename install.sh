#!/bin/sh
set -e

# ============================================================
# debot-trade-cli installer
# ============================================================

BINARY_NAME="debot-trade-cli"
REPO="tvyvnjs/debot-trade"
INSTALL_DIR="$HOME/.local/bin"   # ← 改为用户目录，无需 sudo

info()  { printf "\033[1;34m[INFO]\033[0m  %s\n" "$1"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$1"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$1"; exit 1; }

# ------ Detect OS ------
detect_os() {
    OS_RAW=$(uname -s)
    case "$OS_RAW" in
        Linux*)               OS="linux"   ;;
        Darwin*)              OS="darwin"  ;;
        MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
        *) error "Unsupported OS: $OS_RAW" ;;
    esac
}

# ------ Detect Arch ------
detect_arch() {
    ARCH_RAW=$(uname -m)
    case "$ARCH_RAW" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH_RAW" ;;
    esac
}

# ------ Check command exists ------
need_cmd() {
    if ! command -v "$1" > /dev/null 2>&1; then
        error "Required command '$1' not found. Please install it first."
    fi
}

# ------ MD5 helper (portable) ------
compute_md5() {
    if command -v md5sum > /dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    elif command -v md5 > /dev/null 2>&1; then
        md5 -q "$1"
    else
        warn "Neither md5sum nor md5 found, skipping checksum verification"
        echo ""
    fi
}

# ------ Fetch latest release version from GitHub ------
fetch_latest_version() {
    info "Fetching latest version ..."

    VERSION=$(curl -sSL --max-time 10 "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep '"tag_name"' \
        | head -1 \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$VERSION" ]; then
        error "Failed to fetch latest version. Check your network or GitHub API rate limit."
    fi

    info "Latest version: ${VERSION}"
}

# ------ Add to PATH in shell rc ------
ensure_path() {
    # Already in PATH — nothing to do
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) return 0 ;;
    esac

    EXPORT_LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""

    # Detect shell profile (mirrors the reference script)
    shell_name=$(basename "$SHELL" 2>/dev/null || echo "sh")
    case "$shell_name" in
        zsh)  profile="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                profile="$HOME/.bash_profile"
            elif [ -f "$HOME/.bashrc" ]; then
                profile="$HOME/.bashrc"
            else
                profile="$HOME/.profile"
            fi
            ;;
        *)    profile="$HOME/.profile" ;;
    esac

    # Skip if the line is already present
    if [ -f "$profile" ] && grep -qF '$HOME/.local/bin' "$profile" 2>/dev/null; then
        export PATH="$INSTALL_DIR:$PATH"
        return 0
    fi

    printf '\n# Added by debot-trade-cli installer\n%s\n' "$EXPORT_LINE" >> "$profile"
    export PATH="$INSTALL_DIR:$PATH"

    info "Added $INSTALL_DIR to PATH in $profile"
    echo ""
    echo "  To use '${BINARY_NAME}' in this session, run:"
    echo "    source $profile"
    echo "  Or open a new terminal window."
}

# ------ Main install flow ------
install() {
    need_cmd curl
    detect_os
    detect_arch
    fetch_latest_version

    DOWNLOAD_BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

    if [ "$OS" = "windows" ]; then
        ARCHIVE_EXT=".zip"
    else
        ARCHIVE_EXT=".tar.gz"
    fi

    ARCHIVE_NAME="${BINARY_NAME}-${OS}-${ARCH}${ARCHIVE_EXT}"
    CHECKSUM_NAME="checksums-md5.txt"
    DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/${ARCHIVE_NAME}"
    CHECKSUM_URL="${DOWNLOAD_BASE_URL}/${CHECKSUM_NAME}"

    info "Platform:  ${OS}/${ARCH}"
    info "Version:   ${VERSION}"
    info "Download:  ${DOWNLOAD_URL}"
    echo ""

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    # Download archive
    info "Downloading ${ARCHIVE_NAME} ..."
    HTTP_CODE=$(curl -sSL -w "%{http_code}" -o "${TMP_DIR}/${ARCHIVE_NAME}" "$DOWNLOAD_URL")
    if [ "$HTTP_CODE" != "200" ]; then
        error "Download failed (HTTP $HTTP_CODE). Check URL: $DOWNLOAD_URL"
    fi

    # Download & verify MD5
    info "Verifying MD5 checksum ..."
    HTTP_CODE=$(curl -sSL -w "%{http_code}" -o "${TMP_DIR}/${CHECKSUM_NAME}" "$CHECKSUM_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] && [ -f "${TMP_DIR}/${CHECKSUM_NAME}" ]; then
        EXPECTED_MD5=$(awk -v f="${ARCHIVE_NAME}" '$2==f {print $1}' "${TMP_DIR}/${CHECKSUM_NAME}")
        if [ -z "$EXPECTED_MD5" ]; then
            warn "No MD5 entry found for ${ARCHIVE_NAME} in ${CHECKSUM_NAME}, skipping verification"
        fi
        ACTUAL_MD5=$(compute_md5 "${TMP_DIR}/${ARCHIVE_NAME}")
        if [ -n "$ACTUAL_MD5" ] && [ -n "$EXPECTED_MD5" ] && [ "$ACTUAL_MD5" != "$EXPECTED_MD5" ]; then
            error "MD5 mismatch! Expected: $EXPECTED_MD5  Got: $ACTUAL_MD5"
        fi
        if [ -n "$ACTUAL_MD5" ] && [ -n "$EXPECTED_MD5" ]; then
            info "MD5 OK: $ACTUAL_MD5"
        fi
    else
        warn "MD5 checksum file not available, skipping verification"
    fi

    # Extract
    info "Extracting ..."
    if [ "$OS" = "windows" ]; then
        need_cmd unzip
        unzip -q "${TMP_DIR}/${ARCHIVE_NAME}" -d "${TMP_DIR}"
        BIN_FILE="${BINARY_NAME}-${OS}-${ARCH}.exe"
        INSTALLED_NAME="${BINARY_NAME}.exe"
    else
        tar xzf "${TMP_DIR}/${ARCHIVE_NAME}" -C "${TMP_DIR}"
        BIN_FILE="${BINARY_NAME}-${OS}-${ARCH}"
        INSTALLED_NAME="${BINARY_NAME}"
    fi

    if [ ! -f "${TMP_DIR}/${BIN_FILE}" ]; then
        error "Expected binary '${BIN_FILE}' not found in archive"
    fi

    # Install — mkdir -p ensures the dir exists; no sudo needed
    mkdir -p "$INSTALL_DIR"
    mv "${TMP_DIR}/${BIN_FILE}" "${INSTALL_DIR}/${INSTALLED_NAME}"
    chmod +x "${INSTALL_DIR}/${INSTALLED_NAME}"

    # Ensure on PATH
    ensure_path

    echo ""
    info "✅ Successfully installed ${BINARY_NAME} ${VERSION} to ${INSTALL_DIR}/${INSTALLED_NAME}"
    echo ""
    echo "  Version:  $("${INSTALL_DIR}/${INSTALLED_NAME}" version 2>/dev/null || echo 'unknown')"
    echo ""
    echo "  Get started:"
    echo "    ${BINARY_NAME} config --api-key YOUR_KEY --api-secret YOUR_SECRET"
    echo "    ${BINARY_NAME} wallets"
    echo "    ${BINARY_NAME} trade --chain solana --token-in SOL_ADDR --token-out TOKEN --amount 1000000000 --public-key WALLET"
    echo ""
    echo "  If '${BINARY_NAME}' is not found, restart your terminal or run:"
    echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
}

install
