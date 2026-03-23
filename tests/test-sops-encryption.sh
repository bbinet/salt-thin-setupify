#!/usr/bin/env bash
# tests/test-sops-encryption.sh
#
# Integration tests for the SOPS/age encryption setup.
# Each test runs in an isolated temporary git repository.
#
# Usage:
#   bash tests/test-sops-encryption.sh
#   make test_sops

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colours & counters ────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'
PASS=0; FAIL=0

section() { echo ""; echo -e "${BOLD}=== $1 ===${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; ((PASS++)) || true; }
ko()      { echo -e "  ${RED}✗${RESET} $1"; ((FAIL++)) || true; }
skip()    { echo -e "  ${YELLOW}⊘${RESET} $1 (skipped: $2)"; }

# ── Temp workspace ────────────────────────────────────────────────────────
TMPROOT="$(mktemp -d /tmp/sops-test-XXXXXX)"
cleanup() { rm -rf "${TMPROOT}"; }
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────
ENCRYPTED_REGEX='(?i)(password|passwd|secret|token|credential|auth|\bkey)'

# Create an isolated git repo with a fresh age key, configured .sops.yaml,
# and copies of the project scripts. Prints the path to the age key file.
make_repo() {
    local dir="$1"
    mkdir -p "${dir}/reclass/nodes" "${dir}/scripts" "${dir}/hooks"
    git -C "${dir}" init -q
    git -C "${dir}" config user.email "test@example.com"
    git -C "${dir}" config user.name "Test"
    git -C "${dir}" config commit.gpgsign false

    # Copy scripts so REPO_ROOT resolves to ${dir} when they are run
    cp "${REPO_ROOT}/scripts/sops-setup.sh"               "${dir}/scripts/"
    cp "${REPO_ROOT}/scripts/rewrite-history-encrypt.sh"  "${dir}/scripts/"
    cp "${REPO_ROOT}/hooks/pre-commit"                    "${dir}/hooks/"

    local keyfile="${dir}/.age-key.txt"
    age-keygen -o "${keyfile}" 2>/dev/null
    chmod 600 "${keyfile}"

    local pubkey
    pubkey="$(grep "^# public key:" "${keyfile}" | awk '{print $NF}')"
    sed "s|age1REPLACE_WITH_YOUR_PUBLIC_KEY|${pubkey}|" \
        "${REPO_ROOT}/.sops.yaml" > "${dir}/.sops.yaml"

    # Dummy initial commit so the repo has a HEAD
    git -C "${dir}" commit -q --allow-empty -m "init"

    echo "${keyfile}"
}

# Encrypt a reclass YAML file using sops with an explicit config path
# (prevents sops from picking up .sops.yaml files from parent directories).
encrypt_file() {
    local keyfile="$1" relpath="$2" dir="$3"
    local pubkey
    pubkey="$(grep "^# public key:" "${keyfile}" | awk '{print $NF}')"
    SOPS_AGE_KEY_FILE="${keyfile}" sops --encrypt \
        --config "${dir}/.sops.yaml" \
        --age "${pubkey}" \
        --encrypted-regex "${ENCRYPTED_REGEX}" \
        --in-place "${dir}/${relpath}"
}

# ── SECTION 1: Prerequisites ──────────────────────────────────────────────
section "Prerequisites"

SOPS_OK=false; AGE_OK=false

if command -v sops &>/dev/null; then
    ok "sops installed: $(sops --version 2>&1 | head -1)"
    SOPS_OK=true
else
    ko "sops not found — run 'make sops_setup'"
fi

if command -v age &>/dev/null && command -v age-keygen &>/dev/null; then
    ok "age installed: $(age --version 2>&1 | head -1)"
    AGE_OK=true
else
    ko "age/age-keygen not found — run 'make sops_setup'"
fi

TOOLS_OK=false
[[ "${SOPS_OK}" == true && "${AGE_OK}" == true ]] && TOOLS_OK=true

# ── SECTION 2: sops-setup.sh ─────────────────────────────────────────────
section "sops-setup.sh"

if [[ "${AGE_OK}" == true ]]; then
    T="${TMPROOT}/test-setup"
    mkdir -p "${T}/scripts"
    cp "${REPO_ROOT}/scripts/sops-setup.sh" "${T}/scripts/"
    cp "${REPO_ROOT}/.sops.yaml" "${T}/.sops.yaml"
    keyfile="${T}/.age-key.txt"

    bash "${T}/scripts/sops-setup.sh" \
        --key-file "${keyfile}" \
        --sops-yaml "${T}/.sops.yaml" \
        >/dev/null 2>&1

    if [[ -f "${keyfile}" ]]; then
        ok "Key file generated"
    else
        ko "Key file not generated"
    fi

    if grep -q "^# public key: age1" "${keyfile}" 2>/dev/null; then
        ok "Key file contains a valid age public key"
    else
        ko "Key file missing public key comment"
    fi

    if ! grep -q "age1REPLACE_WITH_YOUR_PUBLIC_KEY" "${T}/.sops.yaml"; then
        ok ".sops.yaml placeholder replaced with real public key"
    else
        ko ".sops.yaml still has placeholder key"
    fi

    # Idempotency: second run must not regenerate the key
    first_key="$(grep "^# public key:" "${keyfile}" | awk '{print $NF}')"
    bash "${T}/scripts/sops-setup.sh" \
        --key-file "${keyfile}" \
        --sops-yaml "${T}/.sops.yaml" \
        >/dev/null 2>&1
    second_key="$(grep "^# public key:" "${keyfile}" | awk '{print $NF}')"
    if [[ "${first_key}" == "${second_key}" ]]; then
        ok "sops-setup.sh is idempotent (key unchanged on second run)"
    else
        ko "sops-setup.sh regenerated the key on second run"
    fi
else
    skip "sops-setup.sh" "age not available"
fi

# ── SECTION 3: Pre-commit hook — plaintext → encrypted ───────────────────
section "Pre-commit hook: plaintext file"

if [[ "${TOOLS_OK}" == true ]]; then
    T="${TMPROOT}/test-hook-plain"
    keyfile="$(make_repo "${T}")"
    cp "${T}/hooks/pre-commit" "${T}/.git/hooks/pre-commit"

    cat > "${T}/reclass/nodes/server.yml" <<'YAML'
parameters:
  myapp:
    hostname: my-server
    password: supersecret123
    port: 8080
YAML

    git -C "${T}" add reclass/
    SOPS_AGE_KEY_FILE="${keyfile}" git -C "${T}" commit -q -m "add server"

    committed="$(git -C "${T}" show HEAD:reclass/nodes/server.yml)"

    if echo "${committed}" | grep -q "ENC\["; then
        ok "Sensitive key 'password' was encrypted"
    else
        ko "Sensitive key 'password' was NOT encrypted"
    fi

    if echo "${committed}" | grep -q "supersecret123"; then
        ko "Plaintext password value is visible in committed file"
    else
        ok "Plaintext password value is not visible in committed file"
    fi

    if echo "${committed}" | grep -q "hostname: my-server"; then
        ok "Non-sensitive key 'hostname' left in plaintext"
    else
        ko "Non-sensitive key 'hostname' was incorrectly encrypted"
    fi

    if echo "${committed}" | grep -q "port: 8080"; then
        ok "Non-sensitive key 'port' left in plaintext"
    else
        ko "Non-sensitive key 'port' was incorrectly encrypted"
    fi

    if echo "${committed}" | grep -q "^sops:"; then
        ok "sops metadata block present in committed file"
    else
        ko "sops metadata block missing from committed file"
    fi
else
    skip "Pre-commit plaintext tests" "sops/age not available"
fi

# ── SECTION 4: Pre-commit hook — non-reclass files not touched ───────────
section "Pre-commit hook: files outside reclass/ are ignored"

if [[ "${TOOLS_OK}" == true ]]; then
    T="${TMPROOT}/test-hook-nonreclass"
    keyfile="$(make_repo "${T}")"
    cp "${T}/hooks/pre-commit" "${T}/.git/hooks/pre-commit"

    mkdir -p "${T}/config"
    printf "password: should-not-be-encrypted\n" > "${T}/config/settings.yml"

    git -C "${T}" add config/
    SOPS_AGE_KEY_FILE="${keyfile}" git -C "${T}" commit -q -m "add config"

    committed="$(git -C "${T}" show HEAD:config/settings.yml)"
    if echo "${committed}" | grep -q "ENC\["; then
        ko "File outside reclass/ was incorrectly encrypted"
    else
        ok "File outside reclass/ correctly left untouched"
    fi
else
    skip "Non-reclass file tests" "sops/age not available"
fi

# ── SECTION 5: Pre-commit hook — developer decrypts, adds field, re-commits
section "Pre-commit hook: developer decrypts, adds field, re-commits without re-encrypting"

if [[ "${TOOLS_OK}" == true ]]; then
    T="${TMPROOT}/test-hook-mixed"
    keyfile="$(make_repo "${T}")"
    cp "${T}/hooks/pre-commit" "${T}/.git/hooks/pre-commit"

    # Commit 1: properly encrypted file
    cat > "${T}/reclass/nodes/server.yml" <<'YAML'
parameters:
  myapp:
    password: first-secret
YAML
    encrypt_file "${keyfile}" "reclass/nodes/server.yml" "${T}"
    git -C "${T}" add reclass/
    SOPS_AGE_KEY_FILE="${keyfile}" git -C "${T}" commit -q -m "encrypted"

    # Developer decrypts, adds a new sensitive field, forgets to re-encrypt.
    # The result is a fully plaintext file (no sops: metadata) with both fields.
    SOPS_AGE_KEY_FILE="${keyfile}" sops --decrypt \
        "${T}/reclass/nodes/server.yml" > "${T}/reclass/nodes/server.yml.tmp" 2>/dev/null
    echo "    token: new-token-value" >> "${T}/reclass/nodes/server.yml.tmp"
    mv "${T}/reclass/nodes/server.yml.tmp" "${T}/reclass/nodes/server.yml"

    # Stage plaintext file — hook should encrypt both fields
    git -C "${T}" add reclass/
    SOPS_AGE_KEY_FILE="${keyfile}" git -C "${T}" commit -q -m "add token field"

    committed="$(git -C "${T}" show HEAD:reclass/nodes/server.yml)"

    if echo "${committed}" | grep -q "new-token-value"; then
        ko "New 'token' field still visible in plaintext after commit"
    else
        ok "New 'token' field was encrypted by the hook"
    fi

    if echo "${committed}" | grep -q "first-secret"; then
        ko "Original 'password' value is visible in plaintext after commit"
    else
        ok "Original 'password' value is not visible in plaintext after commit"
    fi

    decrypted="$(SOPS_AGE_KEY_FILE="${keyfile}" sops --decrypt \
        "${T}/reclass/nodes/server.yml" 2>/dev/null || true)"
    if echo "${decrypted}" | grep -q "first-secret" && \
       echo "${decrypted}" | grep -q "new-token-value"; then
        ok "Both fields decrypt correctly (values preserved)"
    else
        ko "One or both fields lost after re-encryption"
    fi
else
    skip "Hook re-commit tests" "sops/age not available"
fi

# ── SECTION 6: rewrite-history — dry-run ─────────────────────────────────
section "rewrite-history-encrypt.sh: --dry-run"

if [[ "${TOOLS_OK}" == true ]]; then
    T="${TMPROOT}/test-rewrite-dryrun"
    keyfile="$(make_repo "${T}")"

    cat > "${T}/reclass/nodes/server.yml" <<'YAML'
parameters:
  myapp:
    hostname: my-server
    password: plaintext-secret
YAML
    git -C "${T}" add .
    git -C "${T}" commit -q -m "add server with plaintext password"

    output="$(cd "${T}" && SOPS_AGE_KEY_FILE="${keyfile}" \
        bash scripts/rewrite-history-encrypt.sh --dry-run --yes 2>&1 || true)"

    if echo "${output}" | grep -q "would encrypt"; then
        ok "--dry-run detects plaintext password in history"
    else
        ko "--dry-run did not detect plaintext password"
    fi

    if echo "${output}" | grep -q "reclass/nodes/server.yml"; then
        ok "--dry-run identifies the correct file"
    else
        ko "--dry-run did not identify the correct file"
    fi

    # Repo must not have been modified
    if git -C "${T}" show HEAD:reclass/nodes/server.yml | grep -q "plaintext-secret"; then
        ok "--dry-run did not modify the repository"
    else
        ko "--dry-run unexpectedly modified the repository"
    fi
else
    skip "rewrite --dry-run tests" "sops/age not available"
fi

# ── SECTION 7: rewrite-history — actual rewrite ──────────────────────────
section "rewrite-history-encrypt.sh: actual rewrite"

if [[ "${TOOLS_OK}" == true ]]; then
    T="${TMPROOT}/test-rewrite"
    keyfile="$(make_repo "${T}")"

    # Commit 1 — plaintext secret
    cat > "${T}/reclass/nodes/server.yml" <<'YAML'
parameters:
  myapp:
    hostname: my-server
    password: secret-in-history
YAML
    git -C "${T}" add .
    git -C "${T}" commit -q -m "initial commit with password"

    # Commit 2 — adds a second sensitive field (both in plaintext)
    cat > "${T}/reclass/nodes/server.yml" <<'YAML'
parameters:
  myapp:
    hostname: my-server
    password: secret-in-history
    token: second-secret
YAML
    git -C "${T}" add .
    git -C "${T}" commit -q -m "add token field"

    cd "${T}" && SOPS_AGE_KEY_FILE="${keyfile}" \
        bash scripts/rewrite-history-encrypt.sh --yes 2>/dev/null
    cd "${REPO_ROOT}"

    # Check all commits for plaintext using a temp file (no process substitution)
    hashfile="${TMPROOT}/hashes7.txt"
    git -C "${T}" log --format="%H" > "${hashfile}"
    found_plaintext=false
    while IFS= read -r hash; do
        content="$(git -C "${T}" show "${hash}:reclass/nodes/server.yml" 2>/dev/null || true)"
        if echo "${content}" | grep -qE "secret-in-history|second-secret"; then
            found_plaintext=true
        fi
    done < "${hashfile}"

    if [[ "${found_plaintext}" == false ]]; then
        ok "No plaintext secrets found in any commit after rewrite"
    else
        ko "Plaintext secret still visible in history after rewrite"
    fi

    # HEAD must decrypt correctly and contain both values
    decrypted="$(SOPS_AGE_KEY_FILE="${keyfile}" sops --decrypt \
        "${T}/reclass/nodes/server.yml" 2>/dev/null || true)"
    if echo "${decrypted}" | grep -q "secret-in-history" && \
       echo "${decrypted}" | grep -q "second-secret"; then
        ok "Rewritten HEAD decrypts correctly (all values preserved)"
    else
        ko "Rewritten HEAD could not be decrypted or values are wrong"
    fi
else
    skip "rewrite actual tests" "sops/age not available"
fi

# ── SECTION 8: rewrite-history — multiple files across commits ───────────
section "rewrite-history-encrypt.sh: multiple files across commits"

if [[ "${TOOLS_OK}" == true ]]; then
    T="${TMPROOT}/test-rewrite-multi"
    keyfile="$(make_repo "${T}")"

    # Commit 1 — first node
    cat > "${T}/reclass/nodes/web.yml" <<'YAML'
parameters:
  web:
    password: web-secret
YAML
    git -C "${T}" add .
    git -C "${T}" commit -q -m "add web node"

    # Commit 2 — second node (new file)
    cat > "${T}/reclass/nodes/db.yml" <<'YAML'
parameters:
  db:
    password: db-secret
    token: db-token
YAML
    git -C "${T}" add .
    git -C "${T}" commit -q -m "add db node"

    cd "${T}" && SOPS_AGE_KEY_FILE="${keyfile}" \
        bash scripts/rewrite-history-encrypt.sh --yes 2>/dev/null
    cd "${REPO_ROOT}"

    hashfile="${TMPROOT}/hashes8.txt"
    git -C "${T}" log --format="%H" > "${hashfile}"
    found_plaintext=false
    while IFS= read -r hash; do
        for f in reclass/nodes/web.yml reclass/nodes/db.yml; do
            content="$(git -C "${T}" show "${hash}:${f}" 2>/dev/null || true)"
            if echo "${content}" | grep -qE "web-secret|db-secret|db-token"; then
                found_plaintext=true
            fi
        done
    done < "${hashfile}"

    if [[ "${found_plaintext}" == false ]]; then
        ok "No plaintext secrets across multiple files and commits after rewrite"
    else
        ko "Plaintext secret still visible in history after rewrite"
    fi

    # Both HEAD files must decrypt correctly
    web_ok=false; db_ok=false
    SOPS_AGE_KEY_FILE="${keyfile}" sops --decrypt \
        "${T}/reclass/nodes/web.yml" 2>/dev/null | grep -q "web-secret" && web_ok=true
    SOPS_AGE_KEY_FILE="${keyfile}" sops --decrypt \
        "${T}/reclass/nodes/db.yml" 2>/dev/null | grep -q "db-secret" && db_ok=true

    if [[ "${web_ok}" == true && "${db_ok}" == true ]]; then
        ok "Both files decrypt correctly at HEAD"
    else
        ko "One or more files could not be decrypted at HEAD"
    fi
else
    skip "Multi-file rewrite tests" "sops/age not available"
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
