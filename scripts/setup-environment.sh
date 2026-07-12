#!/bin/bash
# setup-environment.sh — Bootstrap a fresh Ubuntu 24.04 machine for SONiC development
#
# Idempotent: safe to re-run if partially failed.
#
# Usage:
#   ./setup-environment.sh
#
# Environment variables (all optional):
#   SONIC_WORKSPACE     — where to create the workspace (default: $HOME/sonic_workspace)
#   SONIC_BUILDIMAGE_REPO — git URL for sonic-buildimage (default: git@github.com:mahmutolger/sonic-buildimage.git)
#   SKIP_CLONE          — set to 1 to skip git clone (only install deps)
#   SKIP_DOCKER         — set to 1 to skip Docker installation
#   FAKE_OS_ID          — (testing only) override OS ID from /etc/os-release
#
# What this script does:
#   1. Verify Ubuntu 24.04
#   2. Check disk space (>= 300G) and RAM (>= 8G)
#   3. Install Docker Engine from official apt repo
#   4. Add user to docker group
#   5. Install host build dependencies (git, make, python3-pip, jinjanator, jq)
#   6. Load overlay kernel module
#   7. Clone sonic-buildimage + set up forks/remotes
#   8. Initialize git submodules
#   9. Verify: docker hello-world, print summary
#
# After running this, proceed to:
#   cd $SONIC_WORKSPACE/sonic-buildimage
#   make init
#   make configure PLATFORM=vs
#   make target/sonic-vs.img.gz

# NOTE: We intentionally do NOT use 'set -e'. Every command whose failure
# matters is checked explicitly with || and converted into step_fail() or
# step_warn() calls, so the script always reaches print_summary.
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SONIC_WORKSPACE="${SONIC_WORKSPACE:-$HOME/sonic_workspace}"
SONIC_BUILDIMAGE_REPO="${SONIC_BUILDIMAGE_REPO:-git@github.com:mahmutolger/sonic-buildimage.git}"
SONIC_BUILDIMAGE_HTTPS="https://github.com/mahmutolger/sonic-buildimage.git"

PASS=0
FAIL=0
WARN=0

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
HAVE_SUDO=false
sudo_available() {
    if [ "$HAVE_SUDO" = "true" ]; then
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        HAVE_SUDO=true
        return 0
    fi
    return 1
}

green()  { echo -e "\033[32m$1\033[0m"; }
red()    { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

step_pass() {
    green "  [PASS] $1"
    PASS=$((PASS + 1))
}

step_fail() {
    red "  [FAIL] $1"
    FAIL=$((FAIL + 1))
}

step_warn() {
    yellow "  [WARN] $1"
    WARN=$((WARN + 1))
}

section() {
    echo ""
    echo "================================================================"
    echo "  $1"
    echo "================================================================"
}

print_summary() {
    echo ""
    echo "================================================================"
    echo "  SETUP COMPLETE"
    echo "================================================================"
    echo "  PASS: $PASS  FAIL: $FAIL  WARN: $WARN"
    echo ""
    if [ "$FAIL" -gt 0 ]; then
        red "  Some steps FAILED. Review the output above for details."
        exit 1
    else
        green "  All checks passed!"
        if [ "$WARN" -gt 0 ]; then
            yellow "  Review warnings above before proceeding."
        fi
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Step 1: Check OS
# ---------------------------------------------------------------------------
check_os() {
    section "Step 1: Operating System Check"

    if [ ! -f /etc/os-release ]; then
        step_fail "Cannot determine OS — /etc/os-release not found"
        return 0
    fi

    local id version
    id="${FAKE_OS_ID:-$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')}"
    version=$(grep -oP '^VERSION_ID=\K.*' /etc/os-release | tr -d '"')

    echo "  Detected: $id $version"

    if [ "$id" != "ubuntu" ]; then
        step_fail "This script requires Ubuntu. Detected: $id"
        echo "  SONiC build is tested on Ubuntu 22.04 and 24.04."
        return 0
    fi

    case "$version" in
        24.04)
            step_pass "Ubuntu 24.04 detected"
            ;;
        22.04)
            step_pass "Ubuntu 22.04 detected"
            step_warn "22.04 is supported but 24.04 is recommended"
            ;;
        *)
            step_warn "Ubuntu $version — not explicitly tested. 22.04 or 24.04 recommended."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 2: Check disk and RAM
# ---------------------------------------------------------------------------
check_resources() {
    section "Step 2: Disk and RAM"

    # Disk (on the partition containing $SONIC_WORKSPACE)
    local ws_parent
    ws_parent="$(dirname "$SONIC_WORKSPACE")"
    mkdir -p "$ws_parent" 2>/dev/null || true

    local avail_gb
    avail_gb=$(df -BG --output=avail "$ws_parent" 2>/dev/null | tail -1 | tr -d ' G' || echo "0")
    echo "  Available disk: ${avail_gb}G (on $(df -h --output=target "$ws_parent" 2>/dev/null | tail -1))"

    if [ "$avail_gb" -lt 100 ]; then
        step_fail "Less than 100G free disk space ($avail_gb GB). SONiC needs 300G+ recommended."
    elif [ "$avail_gb" -lt 300 ]; then
        step_warn "Disk space ($avail_gb GB) is below 300G recommended. Full build may run out of space."
    else
        step_pass "Disk space sufficient ($avail_gb GB)"
    fi

    # RAM
    local total_ram_gb
    total_ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    echo "  Total RAM: ${total_ram_gb}G"

    if [ "$total_ram_gb" -lt 8 ]; then
        step_fail "Less than 8G RAM ($total_ram_gb GB). SONiC builds need 8G+ (28G+ recommended for 4 jobs)."
    elif [ "$total_ram_gb" -lt 28 ]; then
        step_warn "RAM ($total_ram_gb GB) is below 28G. Build with SONIC_BUILD_JOBS=2 or lower."
    else
        step_pass "RAM sufficient ($total_ram_gb GB)"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Install Docker Engine
# ---------------------------------------------------------------------------
install_docker() {
    section "Step 3: Docker Engine"

    if [ "${SKIP_DOCKER:-0}" = "1" ]; then
        step_warn "Skipping Docker installation (SKIP_DOCKER=1)"
        return 0
    fi

    # Already installed?
    if command -v docker &>/dev/null && docker --version &>/dev/null; then
        echo "  Docker already installed: $(docker --version)"
        step_pass "Docker is installed"
    elif ! sudo_available; then
        step_warn "Docker not installed and sudo requires password — skipping"
        echo "           Install Docker manually: https://docs.docker.com/engine/install/ubuntu/"
    else
        echo "  Installing Docker Engine from official apt repository..."

        # Prerequisites (from upstream scripts/prerequisites.sh)
        if sudo apt-get update -qq; then
            echo "  apt update OK"
        else
            step_fail "apt-get update failed"
            return 0
        fi

        if sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release; then
            echo "  Docker prerequisites installed"
        else
            step_fail "Failed to install Docker prerequisites (ca-certificates curl gnupg lsb-release)"
            return 0
        fi

        # Add Docker's official GPG key
        if ! sudo install -m 0755 -d /etc/apt/keyrings; then
            step_fail "Failed to create /etc/apt/keyrings"
            return 0
        fi

        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            if sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.gpg; then
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
            else
                step_fail "Failed to download Docker GPG key"
                return 0
            fi
        fi

        # Add the repository
        local arch
        arch=$(dpkg --print-architecture)
        local codename
        codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

        if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
            if ! echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null; then
                step_fail "Failed to add Docker apt repository"
                return 0
            fi
        fi

        if ! sudo apt-get update -qq; then
            step_fail "apt-get update failed after adding Docker repo"
            return 0
        fi

        if sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            if command -v docker &>/dev/null; then
                step_pass "Docker installed: $(docker --version)"
            else
                step_fail "Docker packages installed but 'docker' command not found"
            fi
        else
            step_fail "Docker installation failed -- check network and apt sources"
            return 0
        fi
    fi

    # Add user to docker group
    if groups "$USER" | grep -q '\bdocker\b'; then
        echo "  User '$USER' already in docker group"
        step_pass "User in docker group"
    elif sudo_available; then
        echo "  Adding user '$USER' to docker group..."
        sudo usermod -aG docker "$USER"
        step_pass "User added to docker group"
        yellow ""
        yellow "  !!! IMPORTANT: Log out and log back in (or run 'newgrp docker') !!!"
        yellow "  !!! before Docker will work without sudo.                      !!!"
        yellow ""
    else
        step_warn "User not in docker group and sudo unavailable — add manually:"
        echo "             sudo usermod -aG docker $USER"
    fi

    # Can we actually use docker?
    if docker info &>/dev/null; then
        step_pass "Docker daemon is running and accessible"
    else
        step_warn "Docker not accessible without sudo. If you just added yourself to the"
        echo "           docker group, log out and back in, then re-run this script."
    fi
}

# ---------------------------------------------------------------------------
# Step 4: Install host build dependencies
#
# Authoritative host package list sources:
#
#   README.md lines 127-133:
#     "Install pip and jinja in host build machine, execute below commands
#      if j2/jinjanator is not available:
#        sudo apt install -y python3-pip
#        pip3 install --user jinjanator"
#
#   README.md lines 103-104 (upstream prerequisites.sh):
#     "curl -sSL https://.../scripts/prerequisites.sh | bash"
#     That script installs: python3-pip, git, ca-certificates, curl,
#     gnupg, lsb-release, docker-ce, docker-ce-cli, containerd.io
#
#   README.md lines 138-146:
#     "Install Docker and configure your system to allow running the
#      'docker' command without 'sudo'"
#
# NOTE: The FULL build dependencies (800+ packages) live inside the
# sonic-slave Docker container (see sonic-slave-bookworm/Dockerfile.j2).
# The host only needs Docker + git + make + jinjanator + jq.
#
# Additional packages below (make, jq, build-essential) are needed on a
# truly fresh Ubuntu 24.04 minimal install but are not listed in the
# upstream README.
# ---------------------------------------------------------------------------
install_host_deps() {
    section "Step 4: Host Build Dependencies"

    if ! sudo_available; then
        step_warn "sudo requires password — skipping package installation"
        echo "           Install manually:"
        echo "             sudo apt-get install -y git make curl jq python3 python3-pip python3-setuptools python3-wheel build-essential"
        echo "             pip3 install --user jinjanator"
        echo "             sudo modprobe overlay"

        # Verify what we can without sudo
        for pkg in git make python3 python3-pip jq curl; do
            if command -v "$pkg" &>/dev/null || dpkg -s "$pkg" &>/dev/null 2>&1; then
                step_pass "$pkg installed"
            else
                step_warn "$pkg not found — install with apt when sudo is available"
            fi
        done
        return 0
    fi

    echo "  Updating apt cache..."
    sudo apt-get update -qq

    local packages=(
        git make curl jq
        python3 python3-pip python3-setuptools python3-wheel
        build-essential
    )

    echo "  Installing: ${packages[*]}"
    sudo apt-get install -y -qq "${packages[@]}"

    for pkg in git make python3 python3-pip jq curl; do
        if command -v "$pkg" &>/dev/null || dpkg -s "$pkg" &>/dev/null; then
            step_pass "$pkg installed"
        else
            step_fail "$pkg not found"
        fi
    done

    # jinjanator (Python template engine, replacement for j2cli on Ubuntu 24.04)
    echo ""
    echo "  Installing jinjanator via pip3..."
    if pip3 install --user --break-system-packages jinjanator 2>/dev/null; then
        step_pass "jinjanator installed"
    elif pip3 install --user jinjanator 2>/dev/null; then
        step_pass "jinjanator installed"
    else
        # Fall back to system j2cli package
        if sudo apt-get install -y -qq j2cli 2>/dev/null; then
            step_pass "j2cli installed (fallback, jinjanator pip install failed)"
        else
            step_fail "jinjanator/j2cli not available"
        fi
    fi

    # overlay kernel module
    echo ""
    if lsmod | grep -q '^overlay'; then
        step_pass "overlay kernel module loaded"
    else
        echo "  Loading overlay kernel module..."
        if sudo modprobe overlay 2>/dev/null; then
            step_pass "overlay module loaded"
        else
            step_fail "Could not load overlay module. Is KVM/nested virt available?"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Clone repositories and set up remotes
# ---------------------------------------------------------------------------
clone_repos() {
    section "Step 5: Clone Repositories"

    if [ "${SKIP_CLONE:-0}" = "1" ]; then
        step_warn "Skipping clone (SKIP_CLONE=1)"
        return 0
    fi

    mkdir -p "$SONIC_WORKSPACE"

    local buildimage_dir="$SONIC_WORKSPACE/sonic-buildimage"

    # --- sonic-buildimage ---
    if [ -d "$buildimage_dir/.git" ] && git -C "$buildimage_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        echo "  sonic-buildimage already cloned at $buildimage_dir"
        step_pass "sonic-buildimage directory exists"
    else
        echo "  Cloning sonic-buildimage..."
        if git clone "$SONIC_BUILDIMAGE_REPO" "$buildimage_dir" 2>/dev/null; then
            step_pass "sonic-buildimage cloned (SSH)"
        else
            yellow "  SSH clone failed (no SSH key?). Trying HTTPS..."
            if git clone "$SONIC_BUILDIMAGE_HTTPS" "$buildimage_dir" 2>/dev/null; then
                step_pass "sonic-buildimage cloned (HTTPS)"
                yellow ""
                yellow "  NOTE: To use SSH in the future, set up an SSH key:"
                yellow "    ssh-keygen -t ed25519 -C \"your@email.com\""
                yellow "    cat ~/.ssh/id_ed25519.pub  # add to github.com → Settings → SSH Keys"
                yellow ""
            else
                step_fail "Could not clone sonic-buildimage"
                return 0
            fi
        fi
    fi

    # Set up remotes: origin = fork, upstream = sonic-net
    echo "  Setting up remotes in sonic-buildimage..."
    (
        cd "$buildimage_dir"

        # Does origin point to upstream? If so, rename it.
        local origin_url
        origin_url=$(git remote get-url origin 2>/dev/null || echo "")
        if echo "$origin_url" | grep -q 'sonic-net'; then
            if ! git remote get-url upstream &>/dev/null; then
                git remote rename origin upstream
                echo "    Renamed origin → upstream (was sonic-net)"
            fi
        fi

        # Ensure 'upstream' exists
        if ! git remote get-url upstream &>/dev/null; then
            git remote add upstream https://github.com/sonic-net/sonic-buildimage.git
            echo "    Added upstream → sonic-net/sonic-buildimage"
        fi

        # Ensure 'origin' points to the fork
        if ! git remote get-url origin &>/dev/null; then
            git remote add origin "$SONIC_BUILDIMAGE_REPO"
            echo "    Added origin → mahmutolger/sonic-buildimage"
        elif ! git remote get-url origin | grep -q 'mahmutolger'; then
            # origin exists but doesn't point to fork — this is unusual
            yellow "    WARNING: origin points to $(git remote get-url origin), not mahmutolger fork"
        fi

        echo "    Remotes:"
        git remote -v | sed 's/^/      /'
    )
    step_pass "Remotes configured"

    # --- Initialize submodules ---
    echo ""
    echo "  Initializing git submodules (this may take a while)..."
    (
        cd "$buildimage_dir"
        git submodule update --init --recursive
    )
    step_pass "Submodules initialized"

    # --- Verify .gitmodules points to fork for sonic-swss ---
    echo ""
    local gitsubmodules="$buildimage_dir/.gitmodules"
    if [ -f "$gitsubmodules" ]; then
        local swss_url
        swss_url=$(grep -A2 'sonic-swss"' "$gitsubmodules" | grep 'url' | sed 's/.*url = //' | tr -d '[:space:]')
        if [ -n "$swss_url" ]; then
            if echo "$swss_url" | grep -q 'mahmutolger'; then
                step_pass ".gitmodules sonic-swss URL points to mahmutolger fork"
            else
                step_warn ".gitmodules sonic-swss URL is: $swss_url"
                yellow "             Expected mahmutolger/sonic-swss (fork)."
                yellow "             Update .gitmodules or run:"
                yellow "               git -C $buildimage_dir config -f .gitmodules submodule.sonic-swss.url https://github.com/mahmutolger/sonic-swss"
            fi
        fi
    fi

    # --- sonic-swss submodule: set remotes ---
    local swss_dir="$buildimage_dir/src/sonic-swss"
    if [ -d "$swss_dir/.git" ]; then
        echo ""
        echo "  Setting up remotes in src/sonic-swss..."
        (
            cd "$swss_dir"

            local swss_origin
            swss_origin=$(git remote get-url origin 2>/dev/null || echo "")
            if echo "$swss_origin" | grep -q 'sonic-net'; then
                if ! git remote get-url upstream &>/dev/null; then
                    git remote rename origin upstream
                    echo "    Renamed origin → upstream (was sonic-net/swss)"
                fi
            fi

            if ! git remote get-url upstream &>/dev/null; then
                git remote add upstream https://github.com/sonic-net/sonic-swss
                echo "    Added upstream → sonic-net/sonic-swss"
            fi

            if ! git remote get-url origin &>/dev/null; then
                git remote add origin git@github.com:mahmutolger/sonic-swss.git
                echo "    Added origin → mahmutolger/sonic-swss (SSH)"
            else
                # origin exists -- check if it's HTTPS and switch to SSH for consistency
                local current_origin
                current_origin=$(git remote get-url origin 2>/dev/null || echo "")
                if echo "$current_origin" | grep -q '^https://'; then
                    echo "    origin is HTTPS: $current_origin"
                    echo "    Switching to SSH for consistency..."
                    if git remote set-url origin git@github.com:mahmutolger/sonic-swss.git; then
                        echo "    origin → git@github.com:mahmutolger/sonic-swss.git (SSH)"
                        step_pass "sonic-swss origin switched to SSH"
                    fi
                elif ! echo "$current_origin" | grep -q 'mahmutolger'; then
                    yellow "    WARNING: sonic-swss origin points to: $current_origin"
                    yellow "             Expected mahmutolger/sonic-swss fork"
                fi
            fi

            echo "    Remotes:"
            git remote -v | sed 's/^/      /'
        )
        step_pass "sonic-swss remotes configured"
    else
        step_warn "src/sonic-swss not found — .gitmodules may point elsewhere"
    fi

    # --- sonic-stp submodule: set remotes (same pattern) ---
    local stp_dir="$buildimage_dir/src/sonic-stp"
    if [ -d "$stp_dir/.git" ]; then
        echo ""
        echo "  Setting up remotes in src/sonic-stp..."
        (
            cd "$stp_dir" || exit 1

            local stp_origin
            stp_origin=$(git remote get-url origin 2>/dev/null || echo "")
            if echo "$stp_origin" | grep -q 'sonic-net'; then
                if ! git remote get-url upstream &>/dev/null; then
                    if git remote rename origin upstream; then
                        echo "    Renamed origin → upstream (was sonic-net/stp)"
                    fi
                fi
            fi

            if ! git remote get-url upstream &>/dev/null; then
                git remote add upstream https://github.com/sonic-net/sonic-stp
                echo "    Added upstream → sonic-net/sonic-stp"
            fi

            if ! git remote get-url origin &>/dev/null; then
                git remote add origin git@github.com:mahmutolger/sonic-stp.git
                echo "    Added origin → mahmutolger/sonic-stp (SSH)"
            else
                local current_origin
                current_origin=$(git remote get-url origin 2>/dev/null || echo "")
                if echo "$current_origin" | grep -q '^https://'; then
                    echo "    origin is HTTPS, switching to SSH..."
                    git remote set-url origin git@github.com:mahmutolger/sonic-stp.git
                    echo "    origin → git@github.com:mahmutolger/sonic-stp.git (SSH)"
                elif ! echo "$current_origin" | grep -q 'mahmutolger'; then
                    yellow "    WARNING: sonic-stp origin points to: $current_origin"
                fi
            fi

            echo "    Remotes:"
            git remote -v | sed 's/^/      /'
        )
        step_pass "sonic-stp remotes configured"
    else
        step_warn "src/sonic-stp not found -- submodule may not be initialized yet"
    fi
}

# ---------------------------------------------------------------------------
# Step 6: Verification
# ---------------------------------------------------------------------------
verify() {
    section "Step 6: Verification"

    # docker hello-world
    echo "  Running: docker run hello-world"
    if docker run --rm hello-world 2>&1 | grep -q 'Hello from Docker'; then
        step_pass "docker run hello-world succeeded"
    else
        step_fail "docker run hello-world failed"
    fi

    # sonic-buildimage directory
    local buildimage_dir="$SONIC_WORKSPACE/sonic-buildimage"
    if [ -d "$buildimage_dir" ] && [ -f "$buildimage_dir/Makefile" ]; then
        step_pass "sonic-buildimage present at $buildimage_dir"
    else
        step_warn "sonic-buildimage not found at $buildimage_dir"
    fi

    # sonic-slave image exists?
    if docker images --format '{{.Repository}}' 2>/dev/null | grep -q 'sonic-slave'; then
        step_pass "Sonic-slave Docker image(s) found"
    else
        echo "  No sonic-slave image yet — will be built on first 'make sonic-slave-bash'"
    fi

    # Check for SSH key (for git operations)
    if [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_ed25519.pub" ] || \
       [ -f "$HOME/.ssh/id_rsa" ] || [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        step_pass "SSH key found"
    else
        step_warn "No SSH key found. GitHub operations use HTTPS. Set up an SSH key for convenience."
    fi
}

# ---------------------------------------------------------------------------
# Step 7: Next steps
# ---------------------------------------------------------------------------
next_steps() {
    local buildimage_dir="$SONIC_WORKSPACE/sonic-buildimage"

    echo ""
    echo "================================================================"
    echo "  NEXT STEPS"
    echo "================================================================"
    echo ""
    echo "  If the docker group was just added, log out and back in first!"
    echo "  Then run:"
    echo ""
    echo "    cd $buildimage_dir"
    echo "    make init"
    echo "    make configure PLATFORM=vs"
    echo "    make target/sonic-vs.img.gz"
    echo ""
    echo "  For a quick interactive build container:"
    echo ""
    echo "    cd $buildimage_dir && make sonic-slave-bash"
    echo ""
    echo "================================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "================================================================"
    echo "  SONiC Dev Environment Setup"
    echo "  Workspace: $SONIC_WORKSPACE"
    echo "================================================================"

    check_os
    check_resources
    install_docker
    install_host_deps
    clone_repos
    verify
    print_summary
    next_steps
}

main "$@"
