#!/usr/bin/env bash
# Setup script for sops + age encryption
# Usage: ./scripts/sops-setup.sh [--key-file PATH]
set -euo pipefail

SOPS_VERSION="3.9.1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
SOPS_YAML="${REPO_ROOT}/.sops.yaml"

while [[ $# -gt 0 ]]; do
    case $1 in
        --key-file)  AGE_KEY_FILE="$2"; shift 2 ;;
        --sops-yaml) SOPS_YAML="$2";    shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

install_age() {
    if command -v age &>/dev/null; then
        echo "age already installed: $(age --version)"
        return
    fi
    echo "Installing age..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y age
}

install_sops() {
    if command -v sops &>/dev/null; then
        echo "sops already installed: $(sops --version)"
        return
    fi
    echo "Installing sops ${SOPS_VERSION}..."
    local arch
    arch="$(dpkg --print-architecture)"
    local url="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}"
    local tmp
    tmp="$(mktemp)"
    wget -q -O "${tmp}" "${url}"
    $SUDO install "${tmp}" /usr/local/bin/sops
    rm -f "${tmp}"
    echo "sops installed: $(sops --version)"
}

generate_age_key() {
    if [ -f "${AGE_KEY_FILE}" ]; then
        echo "Age key already exists at ${AGE_KEY_FILE}" >&2
    else
        echo "Generating age key pair at ${AGE_KEY_FILE}..." >&2
        mkdir -p "$(dirname "${AGE_KEY_FILE}")"
        age-keygen -o "${AGE_KEY_FILE}"
        chmod 600 "${AGE_KEY_FILE}"
    fi

    # Extract public key (only this line goes to stdout; rest goes to stderr)
    local pub_key
    pub_key="$(grep "^# public key:" "${AGE_KEY_FILE}" | awk '{print $NF}')"
    echo "Public key: ${pub_key}" >&2
    echo "${pub_key}"
}

update_sops_yaml() {
    local pub_key="$1"
    if grep -q "${pub_key}" "${SOPS_YAML}"; then
        echo "Public key already present in .sops.yaml"
    elif grep -q "age1REPLACE_WITH_YOUR_PUBLIC_KEY" "${SOPS_YAML}"; then
        sed -i "s|age1REPLACE_WITH_YOUR_PUBLIC_KEY|${pub_key}|" "${SOPS_YAML}"
        echo "Updated .sops.yaml with public key"
    else
        # Replace existing age key with the local one
        sed -i "s|age: age1.*|age: ${pub_key}|" "${SOPS_YAML}"
        echo "Updated .sops.yaml with local public key"
    fi
}

install_age
install_sops

pub_key="$(generate_age_key)"
update_sops_yaml "${pub_key}"

echo ""
echo "Setup complete!"
echo ""
echo "Your age private key is at: ${AGE_KEY_FILE}"
echo "IMPORTANT: Keep this file secure and do NOT commit it to git."
echo ""
echo "Next steps:"
echo "  1. Run 'make sops_install_hook' to install the git pre-commit hook"
echo "  2. Place secrets in reclass/classes/secret/<node>.yml under _param:"
echo "     They will be automatically encrypted before each commit"
echo "  3. Import the secret class in your node: add 'secret.<node>' to its classes:"
echo "  4. Share the public key in .sops.yaml with your team."
echo "     Each team member must run 'make sops_setup' with their own key,"
echo "     then add their public key to .sops.yaml (multiple keys supported)."
