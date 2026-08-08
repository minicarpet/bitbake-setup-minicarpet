#!/bin/bash

# Prepares the host machine with all packages and system settings required
# to run a Yocto/bitbake build. Can be run standalone or called from setup.sh.

set -euo pipefail

OS_ID=""
OS_VERSION_ID=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
fi

REQUIRED_PKGS=(
    build-essential chrpath cpio debianutils diffstat file gawk gcc git jq
    iputils-ping libacl1 libcrypt-dev locales python3 python3-git python3-jinja2
    python3-pexpect python3-pip python3-subunit socat texinfo unzip
    wget xz-utils zstd
)

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
        || MISSING_PKGS+=("$pkg")
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    sudo apt update
    sudo apt install -y "${MISSING_PKGS[@]}"
else
    echo "All required packages already installed."
fi

if ! locale -a 2>/dev/null | grep -qi "en_US.utf8\|en_US.UTF-8"; then
    echo "Configuring en_US.UTF-8 locale..."
    if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
        echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen > /dev/null
    fi
    sudo locale-gen
else
    echo "Locale en_US.UTF-8 already available."
fi
