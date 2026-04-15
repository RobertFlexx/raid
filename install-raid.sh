#!/bin/bash

set -euo pipefail

REPO="RobertFlexx/raid"
INSTALL_DIR="${HOME}/.local/bin"
SYSTEM_BIN="/usr/local/bin"
VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

err() { echo -e "$@" >&2; }
info() { err "${BLUE}[•]${RESET} $1"; }
success() { err "${GREEN}[✓]${RESET} $1"; }
warn() { err "${YELLOW}[!]${RESET} $1"; }
error() { err "${RED}[✗]${RESET} $1"; }
step() { err "${CYAN}[${BOLD}$1${RESET}${CYAN}]${RESET} $2"; }

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        local temp="${spinstr#?}"
        printf " [%c] " "${spinstr:0:1}" >&2
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b" >&2
    done
    printf "    \b\b\b\b\b" >&2
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS="$ID"
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/alpine-release ]]; then
        OS="alpine"
        OS_NAME="Alpine Linux"
        OS_VERSION=$(cat /etc/alpine-release)
    elif [[ $(uname -s) == "Darwin" ]]; then
        OS="macos"
        OS_NAME="macOS"
        OS_VERSION=$(sw_vers -productVersion 2>/dev/null || uname -r)
    else
        OS="unknown"
        OS_NAME="Unknown"
        OS_VERSION=""
    fi
}

check_curl() {
    if ! command -v curl &> /dev/null; then
        info "Installing curl..."
        case "$OS" in
            ubuntu|debian|linuxmint|elementary|pop)
                sudo apt-get update -qq
                sudo apt-get install -y curl
                ;;
            fedora|rhel|centos|rocky|almalinux)
                sudo dnf install -y curl
                ;;
            arch|manjaro|endeavouros)
                sudo pacman -S --noconfirm curl
                ;;
            opensuse|opensuse-leap|opensuse-tumbleweed)
                sudo zypper install -y curl
                ;;
            alpine)
                sudo apk add curl
                ;;
            macos)
                if command -v brew &> /dev/null; then
                    brew install curl
                else
                    error "Homebrew not found. Please install Homebrew first."
                    exit 1
                fi
                ;;
        esac
    fi
}

install_zig() {
    step "1" "Checking Zig installation..."

    if command -v zig &> /dev/null; then
        local zig_version
        zig_version=$(zig version 2>/dev/null)
        local major minor
        major=$(echo "$zig_version" | cut -d. -f1)
        minor=$(echo "$zig_version" | cut -d. -f2)

        if [[ "$major" -ge 0 && "$minor" -ge 12 ]]; then
            success "Zig $zig_version already installed"
            return 0
        else
            warn "Zig version too old ($zig_version), need 0.12+"
        fi
    else
        info "Zig not found"
    fi

    step "1" "Installing Zig..."

    case "$OS" in
        ubuntu|debian|linuxmint|elementary|pop)
            local keyring_dir="/usr/share/keyrings"
            local apt_source="/etc/apt/sources.list.d/zig.list"

            if [[ ! -f "$apt_source" ]]; then
                info "Adding Zig repository..."
                curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key 2>/dev/null | \
                    sudo tee "$keyring_dir/llvm-snapshot.gpg.key" > /dev/null
                echo "deb [signed-by=$keyring_dir/llvm-snapshot.gpg.key] http://apt.llvm.org/$(lsb_release -cs)/ llvm-toolchain-$(lsb_release -cs)-17 main" | \
                    sudo tee "$apt_source" > /dev/null
                sudo apt-get update -qq
            fi

            sudo apt-get install -y zig
            ;;

        fedora|rhel|centos|rocky|almalinux|openmamba)
            if command -v dnf &> /dev/null; then
                sudo dnf install -y zig
            else
                sudo yum install -y zig
            fi
            ;;

        arch|manjaro|endeavouros)
            sudo pacman -S --noconfirm zig
            ;;

        opensuse|opensuse-leap|opensuse-tumbleweed)
            sudo zypper install -y zig
            ;;

        alpine)
            sudo apk add zig
            ;;

        macos)
            if command -v brew &> /dev/null; then
                brew install zig
            else
                info "Installing Zig via official installer..."
                local ZIG_VERSION="0.13.0"
                local ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-macos-x86_64-${ZIG_VERSION}.tar.xz"

                if [[ $(uname -m) == "arm64" ]]; then
                    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-macos-aarch64-${ZIG_VERSION}.tar.xz"
                fi

                curl -fsSL "$ZIG_URL" -o /tmp/zig.tar.xz
                sudo mkdir -p /usr/local/zig
                sudo tar -xf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1
                rm /tmp/zig.tar.xz
                export PATH="/usr/local/zig:$PATH"
            fi
            ;;

        *)
            info "Installing Zig via official installer..."
            local ZIG_VERSION="0.13.0"
            local ARCH
            ARCH=$(uname -m)
            local ZIG_URL=""

            case "$ARCH" in
                x86_64)
                    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
                    ;;
                aarch64|arm64)
                    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-aarch64-${ZIG_VERSION}.tar.xz"
                    ;;
                *)
                    error "Unsupported architecture: $ARCH"
                    exit 1
                    ;;
            esac

            curl -fsSL "$ZIG_URL" -o /tmp/zig.tar.xz
            sudo mkdir -p /usr/local/zig
            sudo tar -xf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1
            rm /tmp/zig.tar.xz
            export PATH="/usr/local/zig:$PATH"
            ;;
    esac

    if command -v zig &> /dev/null; then
        success "Zig $(zig version) installed"
    else
        error "Failed to install Zig"
        exit 1
    fi
}

install_build_deps() {
    step "2" "Checking build dependencies..."

    local deps_missing=0

    case "$OS" in
        ubuntu|debian|linuxmint|elementary|pop)
            local deps=(build-essential pkg-config libx11-dev)
            for dep in "${deps[@]}"; do
                if ! dpkg -l "$dep" &> /dev/null 2>&1; then
                    deps_missing=1
                    break
                fi
            done
            if [[ $deps_missing -eq 1 ]]; then
                info "Installing build dependencies..."
                sudo apt-get update -qq
                sudo apt-get install -y build-essential pkg-config libx11-dev
            fi
            ;;

        fedora|rhel|centos|rocky|almalinux|openmamba)
            local deps=(gcc make pkgconf-pkg-config libX11-devel)
            local deps_ok=1
            for dep in "${deps[@]}"; do
                if ! rpm -q "$dep" &> /dev/null 2>&1; then
                    deps_ok=0
                    break
                fi
            done
            if [[ $deps_ok -eq 0 ]]; then
                info "Installing build dependencies..."
                sudo dnf install -y gcc make pkgconf-pkg-config libX11-devel || true
            fi
            ;;

        arch|manjaro|endeavouros)
            if ! pacman -Q base-devel &> /dev/null 2>&1; then
                info "Installing build dependencies..."
                sudo pacman -S --noconfirm base-devel
            fi
            ;;

        opensuse|opensuse-leap|opensuse-tumbleweed)
            if ! rpm -q patterns-devel-base-devel_basis &> /dev/null 2>&1; then
                info "Installing build dependencies..."
                sudo zypper install -y -t pattern devel_basis
            fi
            ;;

        alpine)
            if ! apk info libc-dev &> /dev/null 2>&1; then
                info "Installing build dependencies..."
                sudo apk add build-base
            fi
            ;;
    esac

    success "Build dependencies ready"
}

do_build() {
    local build_dir="$1"

    step "3" "Cloning raid repository..."

    if [[ -d "$build_dir" ]]; then
        rm -rf "$build_dir"
    fi

    mkdir -p "$build_dir"
    git clone --depth 1 "https://github.com/${REPO}.git" "$build_dir" 2>/dev/null

    success "Repository cloned"

    step "3" "Building raid..."

    local zig_path=""
    if [[ -d "/usr/local/zig" ]]; then
        zig_path="/usr/local/zig"
    fi

    (
        cd "$build_dir" || exit 1
        PATH="${zig_path}:${PATH}" zig build-exe -lc -O ReleaseFast raid.zig
    ) &
    local build_pid=$!
    spinner $build_pid
    wait $build_pid

    if [[ $? -ne 0 ]]; then
        error "Build failed"
        return 1
    fi

    success "Build complete"
}

do_install() {
    local binary_path="$1"

    step "4" "Installing raid..."

    local target="${SYSTEM_BIN}/raid"

    if sudo cp "$binary_path" "$target" 2>/dev/null; then
        sudo chmod +x "$target"
    elif mkdir -p "$INSTALL_DIR" 2>/dev/null && cp "$binary_path" "${INSTALL_DIR}/raid" 2>/dev/null; then
        target="${INSTALL_DIR}/raid"
        chmod +x "$target"

        if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
            warn "Add ${INSTALL_DIR} to your PATH"
        fi
    else
        error "Cannot write to installation directories"
        info "Run with sudo or set INSTALL_DIR"
        exit 1
    fi

    success "Installed to $target"
}

main() {
    err ""
    err "  ${BOLD}raid${RESET} ${DIM}v${VERSION}${RESET}"
    err "  ${DIM}Low-level recursive file system traversal${RESET}"
    err ""

    info "Detecting system..."
    detect_os
    err "    ${BOLD}${OS_NAME}${RESET} ${DIM}${OS_VERSION}${RESET}"
    err ""

    check_curl
    install_zig
    install_build_deps

    local build_dir="/tmp/raid-build-$$"
    do_build "$build_dir"

    local binary="${build_dir}/raid"
    if [[ ! -f "$binary" ]]; then
        error "Binary not found at $binary"
        rm -rf "$build_dir"
        exit 1
    fi

    do_install "$binary"

    step "5" "Cleaning up..."
    rm -rf "$build_dir"
    success "Done"

    err ""
    err "${BOLD}All done!${RESET} Run ${GREEN}raid${RESET} to get started."
    err ""
}

main "$@"
