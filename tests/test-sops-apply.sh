#!/usr/bin/env bash
# tests/test-sops-apply.sh
#
# Integration tests verifying that:
#   1. apply_nosudo generates a docker-compose.yml with the correct secret values
#      (no sops required — tests against the real project environment).
#   2. After a SOPS encrypt → sops_decrypt cycle, apply_nosudo still produces
#      the correct (decrypted) values in the generated docker-compose.yml.
#
# Usage:
#   bash tests/test-sops-apply.sh
#   make test_sops_apply

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SALT_CALL="${REPO_ROOT}/.tmp/relenv/bin/salt-call"
SALT_CALL_OPTS="-c ${REPO_ROOT} --log-level=quiet --state-output=changes"

# ── Colours & counters ────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'
PASS=0; FAIL=0

section() { echo ""; echo -e "${BOLD}=== $1 ===${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; ((PASS++)) || true; }
ko()      { echo -e "  ${RED}✗${RESET} $1"; ((FAIL++)) || true; }
skip()    { echo -e "  ${YELLOW}⊘${RESET} $1 (skipped: $2)"; }

# ── Temp workspace ────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d /tmp/sops-apply-test-XXXXXX)"
cleanup() { rm -rf "${TMPROOT}"; }
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────

# Run apply_nosudo in an isolated directory:
#   - Uses the existing relenv from REPO_ROOT/.tmp/relenv
#   - Points reclass inventory at a caller-supplied decrypted_reclass dir
#   - Writes compose files to workdir/compose/
# Usage: run_apply_nosudo <workdir> <reclass_dir>
run_apply_nosudo() {
    local workdir="$1" reclass_dir="$2"

    # Minimal minion config: absolute paths so salt-call can run from workdir
    cat > "${workdir}/minion" <<MINION
root_dir: ${workdir}/.tmp/
file_client: local
file_roots:
  base:
    - ${REPO_ROOT}/states
reclass: &reclass
  storage_type: yaml_fs
  inventory_base_uri: ${reclass_dir}
  scalar_parameters: "_param"
  ignore_class_notfound: true
  ignore_class_regexp:
    - 'service.*'
ext_pillar:
  - reclass: *reclass
master_tops:
  reclass: *reclass
log_level: error
log_file_level: quiet
MINION

    mkdir -p "${workdir}/.tmp/etc/salt" "${workdir}/.tmp/var/log/salt" \
             "${workdir}/compose"
    echo "example" > "${workdir}/.tmp/etc/salt/minion_id"
    echo "root: ${workdir}" > "${workdir}/grains"

    "${SALT_CALL}" ${SALT_CALL_OPTS} \
        -c "${workdir}" \
        --id=example \
        state.apply setupify.nosudo \
        >/dev/null 2>&1
}

# ── Prerequisites ─────────────────────────────────────────────────────────
section "Prerequisites"

RELENV_OK=false
SOPS_OK=false
AGE_OK=false

if [[ -x "${SALT_CALL}" ]]; then
    ok "relenv salt-call exists"
    RELENV_OK=true
else
    ko "relenv salt-call not found — run 'make relenv' first"
fi

if command -v sops &>/dev/null; then
    ok "sops installed: $(sops --version 2>&1 | head -1)"
    SOPS_OK=true
else
    skip "sops" "not installed — run 'make sops_setup' to enable sops tests"
fi

if command -v age &>/dev/null && command -v age-keygen &>/dev/null; then
    ok "age/age-keygen installed"
    AGE_OK=true
else
    skip "age" "not installed — run 'make sops_setup' to enable sops tests"
fi

# ── SECTION 1: apply_nosudo with plaintext secrets ────────────────────────
section "apply_nosudo: plaintext secrets → docker-compose.yml"

if [[ "${RELENV_OK}" == true ]]; then
    WORKDIR="${TMPROOT}/test-plain"
    mkdir -p "${WORKDIR}"

    # Use the current .tmp/reclass (already populated by sops_decrypt)
    run_apply_nosudo "${WORKDIR}" "${REPO_ROOT}/.tmp/reclass"

    COMPOSE="${WORKDIR}/compose/hig/docker-compose.yml"

    if [[ -f "${COMPOSE}" ]]; then
        ok "docker-compose.yml was generated"
    else
        ko "docker-compose.yml was NOT generated"
    fi

    if [[ -f "${COMPOSE}" ]] && grep -q "INFLUXDB_ADMIN_PASSWORD: s3cr3t_influxdb" "${COMPOSE}"; then
        ok "INFLUXDB_ADMIN_PASSWORD has the expected secret value"
    else
        ko "INFLUXDB_ADMIN_PASSWORD is missing or has the wrong value"
    fi

    if [[ -f "${COMPOSE}" ]] && grep -q "GF_SECURITY_ADMIN_PASSWORD: s3cr3t_grafana" "${COMPOSE}"; then
        ok "GF_SECURITY_ADMIN_PASSWORD has the expected secret value"
    else
        ko "GF_SECURITY_ADMIN_PASSWORD is missing or has the wrong value"
    fi

    if [[ -f "${COMPOSE}" ]] && ! grep -q "INFLUXDB_ADMIN_PASSWORD: root" "${COMPOSE}"; then
        ok "INFLUXDB_ADMIN_PASSWORD is not the insecure default 'root'"
    else
        ko "INFLUXDB_ADMIN_PASSWORD still has the insecure default value 'root'"
    fi
else
    skip "apply_nosudo plaintext tests" "relenv not available"
fi

# ── SECTION 2: SOPS encrypt → sops_decrypt → apply_nosudo ─────────────────
section "SOPS: encrypt example.yml → sops_decrypt → apply_nosudo"

if [[ "${RELENV_OK}" == true && "${SOPS_OK}" == true && "${AGE_OK}" == true ]]; then

    # 2a. Generate a fresh age key pair
    KEYFILE="${TMPROOT}/age-key.txt"
    age-keygen -o "${KEYFILE}" 2>/dev/null
    chmod 600 "${KEYFILE}"
    PUBKEY="$(grep "^# public key:" "${KEYFILE}" | awk '{print $NF}')"

    # Build a .sops.yaml using the fresh key
    SOPS_YAML="${TMPROOT}/.sops.yaml"
    sed "s|age1REPLACE_WITH_YOUR_PUBLIC_KEY|${PUBKEY}|" \
        "${REPO_ROOT}/.sops.yaml" > "${SOPS_YAML}"

    # 2b. Copy the reclass tree to an isolated staging dir and encrypt
    STAGING="${TMPROOT}/staging-reclass"
    cp -rL "${REPO_ROOT}/.tmp/reclass" "${STAGING}"

    ENCRYPTED_REGEX='(?i)(password|passwd|secret|token|credential|auth|\bkey)'

    SOPS_AGE_KEY_FILE="${KEYFILE}" sops --encrypt \
        --config "${SOPS_YAML}" \
        --age "${PUBKEY}" \
        --encrypted-regex "${ENCRYPTED_REGEX}" \
        --in-place "${STAGING}/nodes/example.yml" 2>/dev/null

    # 2c. Verify that the password keys are encrypted in the staged file
    ENCRYPTED_NODE="${STAGING}/nodes/example.yml"

    if grep -q "^sops:" "${ENCRYPTED_NODE}"; then
        ok "Encrypted example.yml contains sops metadata block"
    else
        ko "Encrypted example.yml is missing the sops metadata block"
    fi

    if grep -q "ENC\[" "${ENCRYPTED_NODE}"; then
        ok "Password values are encrypted (ENC[ marker present)"
    else
        ko "No ENC[ marker found — password values may be plaintext"
    fi

    # Exact key 'password' → value must be encrypted
    if ! grep -q "s3cr3t_influxdb" "${ENCRYPTED_NODE}"; then
        ok "Exact key 'password': plaintext 's3cr3t_influxdb' not visible"
    else
        ko "Exact key 'password': 's3cr3t_influxdb' is still in plaintext"
    fi

    if ! grep -q "s3cr3t_grafana" "${ENCRYPTED_NODE}"; then
        ok "Exact key 'password': plaintext 's3cr3t_grafana' not visible"
    else
        ko "Exact key 'password': 's3cr3t_grafana' is still in plaintext"
    fi

    # Compound key INFLUXDB_ADMIN_PASSWORD → key visible, value encrypted
    if grep -q "INFLUXDB_ADMIN_PASSWORD:" "${ENCRYPTED_NODE}"; then
        ok "Compound key 'INFLUXDB_ADMIN_PASSWORD' present (key in plaintext)"
    else
        ko "Compound key 'INFLUXDB_ADMIN_PASSWORD' missing from encrypted file"
    fi
    if ! grep -A1 "INFLUXDB_ADMIN_PASSWORD:" "${ENCRYPTED_NODE}" | grep -q "_param:influxdb_admin_password"; then
        ok "Compound key 'INFLUXDB_ADMIN_PASSWORD': value is encrypted"
    else
        ko "Compound key 'INFLUXDB_ADMIN_PASSWORD': value still in plaintext"
    fi

    # Compound key influxdb_admin_password → key visible, reference encrypted
    if grep -q "influxdb_admin_password:" "${ENCRYPTED_NODE}"; then
        ok "Compound key 'influxdb_admin_password' present (key in plaintext)"
    else
        ko "Compound key 'influxdb_admin_password' missing from encrypted file"
    fi
    if ! grep -A1 "influxdb_admin_password:" "${ENCRYPTED_NODE}" | grep -q 's3cr3t_influxdb'; then
        ok "Compound key 'influxdb_admin_password': value is encrypted"
    else
        ko "Compound key 'influxdb_admin_password': value still in plaintext"
    fi

    # Non-sensitive key must remain fully in plaintext
    if grep -q "nosudo:" "${ENCRYPTED_NODE}"; then
        ok "Non-sensitive key 'nosudo' remains in plaintext"
    else
        ko "Non-sensitive key 'nosudo' was incorrectly encrypted or removed"
    fi

    # 2d. Decrypt the staging reclass into a fresh decrypted dir
    DECRYPTED="${TMPROOT}/decrypted-reclass"
    cp -r "${STAGING}" "${DECRYPTED}"

    SOPS_AGE_KEY_FILE="${KEYFILE}" sops --decrypt \
        --config "${SOPS_YAML}" \
        "${DECRYPTED}/nodes/example.yml" \
        > "${DECRYPTED}/nodes/example.yml.tmp" 2>/dev/null \
        && mv "${DECRYPTED}/nodes/example.yml.tmp" \
              "${DECRYPTED}/nodes/example.yml"

    # 2e. Verify decrypted values
    DECRYPTED_NODE="${DECRYPTED}/nodes/example.yml"

    if grep -q "s3cr3t_influxdb" "${DECRYPTED_NODE}"; then
        ok "Decrypted example.yml contains 's3cr3t_influxdb'"
    else
        ko "Decrypted example.yml is missing 's3cr3t_influxdb'"
    fi

    if grep -q "s3cr3t_grafana" "${DECRYPTED_NODE}"; then
        ok "Decrypted example.yml contains 's3cr3t_grafana'"
    else
        ko "Decrypted example.yml is missing 's3cr3t_grafana'"
    fi

    if ! grep -q "^sops:" "${DECRYPTED_NODE}"; then
        ok "Decrypted example.yml has no residual sops metadata"
    else
        ko "Decrypted example.yml still contains sops metadata"
    fi

    # 2f. Run apply_nosudo against the decrypted reclass inventory
    WORKDIR2="${TMPROOT}/test-sops"
    mkdir -p "${WORKDIR2}"
    run_apply_nosudo "${WORKDIR2}" "${DECRYPTED}"

    COMPOSE2="${WORKDIR2}/compose/hig/docker-compose.yml"

    if [[ -f "${COMPOSE2}" ]]; then
        ok "docker-compose.yml generated after decrypt → apply_nosudo"
    else
        ko "docker-compose.yml NOT generated after decrypt → apply_nosudo"
    fi

    if [[ -f "${COMPOSE2}" ]] && grep -q "INFLUXDB_ADMIN_PASSWORD: s3cr3t_influxdb" "${COMPOSE2}"; then
        ok "Decrypted secret flows correctly into INFLUXDB_ADMIN_PASSWORD"
    else
        ko "INFLUXDB_ADMIN_PASSWORD does not contain the decrypted secret"
    fi

    if [[ -f "${COMPOSE2}" ]] && grep -q "GF_SECURITY_ADMIN_PASSWORD: s3cr3t_grafana" "${COMPOSE2}"; then
        ok "Decrypted secret flows correctly into GF_SECURITY_ADMIN_PASSWORD"
    else
        ko "GF_SECURITY_ADMIN_PASSWORD does not contain the decrypted secret"
    fi

else
    if [[ "${RELENV_OK}" != true ]]; then
        skip "SOPS encrypt/decrypt/apply tests" "relenv not available"
    else
        skip "SOPS encrypt/decrypt/apply tests" "sops/age not available"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
total=$((PASS + FAIL))
if [[ "${FAIL}" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All ${total} tests passed.${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}${FAIL} / ${total} tests failed.${RESET}"
    exit 1
fi
