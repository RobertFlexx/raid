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

log_info() {
    echo -e "${BLUE}[•]${RESET} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${RESET} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${RESET} $1"
}

log_error() {
    echo -e "${RED}[✗]${RESET} $1"
}

log_step() {
    echo -e "${CYAN}[${BOLD}$1${RESET}${CYAN}]${RESET} $2"
}

print_banner() {
    clear
    echo ""
    echo -e "  ${BOLD}raid${RESET} ${DIM}v${VERSION}${RESET}"
    echo -e "  ${DIM}Low-level recursive file system traversal${RESET}"
    echo ""
}
    echo -e "${DIM}    Low-level recursive file system traversal${RESET}"
    echo -e "${DIM}    Installer v${VERSION}${RESET}"
    echo ""
}

check_curl() {
    if ! command -v curl &> /dev/null; then
        log_info "Installing curl..."
        case "$OS" in
            ubuntu|debian|linuxmint|elementary)
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
                    log_error "Homebrew not found. Please install Homebrew first."
                    exit 1
                fi
                ;;
        esac
    fi
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

install_zig() {
    log_step "1" "Checking Zig installation..."

    if command -v zig &> /dev/null; then
        local zig_version=$(zig version 2>/dev/null | head -c 4)
        local major=$(echo "$zig_version" | cut -d. -f1)
        local minor=$(echo "$zig_version" | cut -d. -f2)

        if [[ "$major" -ge 0 && "$minor" -ge 12 ]]; then
            log_success "Zig $(zig version) already installed"
            return 0
        else
            log_warn "Zig version too old ($(zig version)), need 0.12+"
        fi
    else
        log_info "Zig not found"
    fi

    log_step "1" "Installing Zig..."

    case "$OS" in
        ubuntu|debian|linuxmint|elementary|pop)
            local keyring_dir="/usr/share/keyrings"
            local apt_source="/etc/apt/sources.list.d/zig.list"

            if [[ ! -f "$apt_source" ]]; then
                log_info "Adding Zig repository..."
                curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key 2>/dev/null | \
                    sudo tee "$keyring_dir/llvm-snapshot.gpg.key" > /dev/null
                echo "deb [signed-by=$keyring_dir/llvm-snapshot.gpg.key] http://apt.llvm.org/$(lsb_release -cs)/ llvm-toolchain-$(lsb_release -cs)-17 main" | \
                    sudo tee "$apt_source" > /dev/null
                sudo apt-get update -qq
            fi

            sudo apt-get install -y zig
            ;;

        fedora|rhel|centos|rocky|almalinux)
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
                log_info "Installing Zig via official installer..."
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
            log_info "Installing Zig via official installer..."
            local ZIG_VERSION="0.13.0"
            local ARCH=$(uname -m)
            local ZIG_URL=""

            case "$ARCH" in
                x86_64)
                    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
                    ;;
                aarch64|arm64)
                    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-aarch64-${ZIG_VERSION}.tar.xz"
                    ;;
                *)
                    log_error "Unsupported architecture: $ARCH"
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
        log_success "Zig $(zig version) installed"
    else
        log_error "Failed to install Zig"
        exit 1
    fi
}

install_build_deps() {
    log_step "2" "Checking build dependencies..."

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
                log_info "Installing build dependencies..."
                sudo apt-get update -qq
                sudo apt-get install -y build-essential pkg-config libx11-dev
            fi
            ;;

        fedora|rhel|centos|rocky|almalinux)
            local deps=(gcc make pkgconf-pkg-config libX11-devel)
            for dep in "${deps[@]}"; do
                if ! rpm -q "$dep" &> /dev/null 2>&1; then
                    deps_missing=1
                    break
                fi
            done
            if [[ $deps_missing -eq 1 ]]; then
                log_info "Installing build dependencies..."
                sudo dnf groupinstall -y "Development Tools"
                sudo dnf install -y make pkgconf-pkg-config libX11-devel
            fi
            ;;

        arch|manjaro|endeavouros)
            if ! pacman -Q base-devel &> /dev/null 2>&1; then
                log_info "Installing build dependencies..."
                sudo pacman -S --noconfirm base-devel
            fi
            ;;

        opensuse|opensuse-leap|opensuse-tumbleweed)
            if ! rpm -q patterns-devel-base-devel_basis &> /dev/null 2>&1; then
                log_info "Installing build dependencies..."
                sudo zypper install -y -t pattern devel_basis
            fi
            ;;

        alpine)
            if ! apk info libc-dev &> /dev/null 2>&1; then
                log_info "Installing build dependencies..."
                sudo apk add build-base
            fi
            ;;
    esac

    log_success "Build dependencies ready"
}

clone_and_build() {
    log_step "3" "Cloning raid repository..."

    local build_dir="/tmp/raid-build-$$"

    if [[ -d "/tmp/raid-build-$$" ]]; then
        rm -rf "$build_dir"
    fi

    mkdir -p "$build_dir"
    git clone --depth 1 "https://github.com/${REPO}.git" "$build_dir" 2>&1 | \
        while IFS= read -r line; do
            printf "\r    %s" "$line"
        done
    echo ""

    log_success "Repository cloned"

    log_step "3" "Building raid..."

    local zig_path=""
    if [[ -d "/usr/local/zig" ]]; then
        zig_path="/usr/local/zig"
    fi

    (cd "$build_dir" && PATH="${zig_path}:${PATH}" zig build-exe -lc -O ReleaseFast raid.zig) &
    local build_pid=$!
    spinner $build_pid
    wait $build_pid

    if [[ $? -ne 0 ]]; then
        log_error "Build failed"
        rm -rf "$build_dir"
        exit 1
    fi

    log_success "Build complete"

    echo "$build_dir/raid"
}

install_binary() {
    local binary_path="$1"

    log_step "4" "Installing raid..."

    local target="${SYSTEM_BIN}/raid"

    if [[ -w "$SYSTEM_BIN" ]]; then
        sudo cp "$binary_path" "$target"
        sudo chmod +x "$target"
    elif [[ -w "$HOME/.local/bin" ]] || mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        target="${INSTALL_DIR}/raid"
        cp "$binary_path" "$target"
        chmod +x "$target"

        if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
            log_warn "Add ${INSTALL_DIR} to your PATH"
        fi
    else
        log_error "Cannot write to installation directories"
        log_info "Run with sudo or set INSTALL_DIR"
        exit 1
    fi

    log_success "Installed to $target"

    if ! command -v raid &> /dev/null; then
        echo ""
        log_warn "raid not found in PATH. Add to your shell config:"
        if [[ "$target" == "${SYSTEM_BIN}/raid" ]]; then
            echo -e "${DIM}    export PATH=\"${SYSTEM_BIN}:\$PATH\"${RESET}"
        else
            echo -e "${DIM}    export PATH=\"${INSTALL_DIR}:\$PATH\"${RESET}"
        fi
    fi
}

cleanup() {
    log_step "5" "Cleaning up..."
    rm -rf /tmp/raid-build-$$
    log_success "Done"
}

main() {
    print_banner

    log_info "Detecting system..."
    detect_os
    echo -e "    ${BOLD}${OS_NAME}${RESET} ${DIM}${OS_VERSION}${RESET}"
    echo ""

    check_curl
    install_zig
    install_build_deps

    local binary_path
    binary_path=$(clone_and_build)
    install_binary "$binary_path"

    cleanup

    echo ""
    echo -e "${BOLD}All done!${RESET} Run ${GREEN}raid${RESET} to get started."
    echo ""
    raid --version 2>/dev/null || true
}

main "$@"
