#!/bin/bash
# check_makefile.sh — Verifies that all non-interactive Makefile targets work
# correctly using the 'example' reclass node (reclass/nodes/example.yml).
#
# Skipped targets (require network/SSH, interactive input, or apply real
# changes to the system):
#   deps        — requires apt-get / sudo
#   pull        — requires SSH access to git remote
#   apply*      — applies real state changes (use test_apply* for dry-run)
#   all         — wraps apply* + pull
#
# Note: apply_formula uses HTTPS git URLs (no SSH key required).

set -euo pipefail

CURDIR="$(pwd)"
PASS=0
FAIL=0
declare -a ERRORS

# ── helpers ────────────────────────────────────────────────────────────────

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); ERRORS+=("$1"); }
skip() { echo "  SKIP  $1"; }

# run_make DESC [make-args…]  — pass if make exits 0
run_make() {
    local desc="$1"; shift
    if make "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

# run_make_output DESC PATTERN [make-args…]  — pass if stdout contains PATTERN
run_make_output() {
    local desc="$1" pattern="$2"; shift 2
    local out
    out=$(make "$@" 2>&1) || true
    if echo "$out" | grep -qE "$pattern"; then
        pass "$desc"
    else
        fail "$desc  (got: $(echo "$out" | tail -3))"
    fi
}

# ── setup ──────────────────────────────────────────────────────────────────

TEST_NODE_ID="_test_makefile_"
TEST_NODE_FILE="${CURDIR}/reclass/nodes/${TEST_NODE_ID}.yml"
GRAINS_CREATED=false
MINION_ID_CREATED=false
TEST_NODE_CREATED=false

cleanup() {
    if "$GRAINS_CREATED";    then rm -f "${CURDIR}/grains"; fi
    if "$MINION_ID_CREATED"; then rm -rf "${CURDIR}/.tmp/etc"; fi
    if "$TEST_NODE_CREATED"; then rm -f "$TEST_NODE_FILE"; fi
}
trap cleanup EXIT

# grains file — required by SLS templates ({{ grains['root'] }})
if [ ! -f "${CURDIR}/grains" ]; then
    echo "root: ${CURDIR}" > "${CURDIR}/grains"
    GRAINS_CREATED=true
fi

# minion_id — always force 'example' so reclass uses reclass/nodes/example.yml
# regardless of the machine's hostname (which may be unresolvable or wrong)
mkdir -p "${CURDIR}/.tmp/etc/salt"
if [ ! -f "${CURDIR}/.tmp/etc/salt/minion_id" ]; then
    MINION_ID_CREATED=true
fi
echo "example" > "${CURDIR}/.tmp/etc/salt/minion_id"

# Minimal reclass node for test_apply* targets: empty setupify pillar so that
# nosudo/sudo/formula states only run their sentinel and don't try to include
# formula states that aren't installed yet
if [ ! -f "$TEST_NODE_FILE" ]; then
    echo "parameters: {}" > "$TEST_NODE_FILE"
    TEST_NODE_CREATED=true
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 0. Prerequisites ══════════════════════════════════════════════════"

if [ ! -f "${CURDIR}/.tmp/.relenv_installed" ]; then
    echo "  SKIP  relenv not installed — run 'make relenv minion_id=example' first"
    exit 0
fi
pass "relenv is installed"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 1. Informational target ═══════════════════════════════════════════"

run_make_output \
    "make help lists key targets" \
    "relenv|check|grains|pillar" \
    help

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 2. salt-call wrapper targets (minion_id=example) ══════════════════"

run_make_output \
    "make grains: saltversion grain present" \
    "saltversion" \
    grains minion_id=example

run_make_output \
    "make grains: root grain points to CURDIR" \
    "$(echo "$CURDIR" | sed 's|/|\\/|g')" \
    grains minion_id=example

run_make_output \
    "make pillar: setupify pillar rendered from reclass" \
    "setupify" \
    pillar minion_id=example

run_make_output \
    "make pillar: example.yml formula sources present" \
    "salt-formula-linux|salt-formula-docker" \
    pillar minion_id=example

run_make_output \
    "make salt arg=test.ping: returns True" \
    "True" \
    salt arg=test.ping minion_id=example

run_make_output \
    "make salt arg=grains.get:saltversion: returns 3007" \
    "3007" \
    "salt" "arg=grains.get saltversion" minion_id=example

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 3. test_apply targets — dry-run (minion_id=_test_makefile_) ══════════"
# Use the _test_makefile_ node (empty setupify pillar) so that nosudo/sudo/
# formula states only run their sentinel and don't try to include formula
# states that aren't installed yet (those would be set up by apply_formula).
echo "_test_makefile_" > "${CURDIR}/.tmp/etc/salt/minion_id"

run_make \
    "make test_apply arg=setupify.ext: no errors" \
    test_apply "arg=setupify.ext" minion_id="${TEST_NODE_ID}"

run_make \
    "make test_apply arg=setupify.nosudo: no errors" \
    test_apply "arg=setupify.nosudo" minion_id="${TEST_NODE_ID}"

run_make \
    "make test_apply arg=setupify.sudo: no errors" \
    test_apply "arg=setupify.sudo" minion_id="${TEST_NODE_ID}"

run_make \
    "make test_apply arg=setupify.formula: no errors" \
    test_apply "arg=setupify.formula" minion_id="${TEST_NODE_ID}"

run_make \
    "make test_apply_nosudo (empty pillar, no formulas needed): no errors" \
    test_apply_nosudo minion_id="${TEST_NODE_ID}"

run_make \
    "make test_apply_sudo (empty pillar, no formulas needed): no errors" \
    test_apply_sudo minion_id="${TEST_NODE_ID}"

# Restore example node for remaining sections
echo "example" > "${CURDIR}/.tmp/etc/salt/minion_id"

# ─── apply_formula + apply_nosudo with real example node ─────────────────────
# apply_formula clones git repos via SSH → requires ssh binary + SSH key.
# apply_nosudo includes formula states → requires apply_formula to have run.
# Both are skipped gracefully when prerequisites are absent.
echo ""
echo "══ 3b. apply_formula + apply_nosudo with example node ════════════════"

FORMULAS_DIR="${CURDIR}/states/_formulas"

# apply_formula clones the formula repos via HTTPS (no SSH key required)
run_make \
    "make apply_formula minion_id=example: clones formula repos" \
    apply_formula minion_id=example

# Formulas are considered installed only if actual SLS files are present
# (empty directories left by a failed apply_formula don't count)
FORMULAS_INSTALLED="$(find "$FORMULAS_DIR" -maxdepth 3 -name '*.sls' 2>/dev/null | head -1)"
if [ -n "$FORMULAS_INSTALLED" ]; then
    # dry-run first to catch state rendering errors before applying for real
    run_make \
        "make test_apply_nosudo minion_id=example: dry-run passes" \
        test_apply_nosudo minion_id=example

    if systemctl is-system-running >/dev/null 2>&1 || [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        run_make \
            "make test_apply_sudo minion_id=example: dry-run passes" \
            test_apply_sudo minion_id=example
    else
        skip "make test_apply_sudo minion_id=example — requires systemd (not running as PID 1)"
    fi

    # real apply
    run_make \
        "make apply_nosudo minion_id=example: applies nosudo states" \
        apply_nosudo minion_id=example

    # verify secrets appear correctly in the generated docker-compose.yml
    COMPOSE_FILE="${CURDIR}/compose/hig/docker-compose.yml"
    if [ -f "$COMPOSE_FILE" ]; then
        if grep -q "INFLUXDB_ADMIN_PASSWORD: s3cr3t_influxdb" "$COMPOSE_FILE"; then
            pass "compose/hig/docker-compose.yml: INFLUXDB_ADMIN_PASSWORD is correct"
        else
            fail "compose/hig/docker-compose.yml: INFLUXDB_ADMIN_PASSWORD missing or wrong"
        fi
        if grep -q "GF_SECURITY_ADMIN_PASSWORD: s3cr3t_grafana" "$COMPOSE_FILE"; then
            pass "compose/hig/docker-compose.yml: GF_SECURITY_ADMIN_PASSWORD is correct"
        else
            fail "compose/hig/docker-compose.yml: GF_SECURITY_ADMIN_PASSWORD missing or wrong"
        fi
    else
        fail "compose/hig/docker-compose.yml not generated by apply_nosudo"
    fi
else
    skip "make test_apply_nosudo minion_id=example — formulas not installed (run make apply_formula first)"
    skip "make test_apply_sudo   minion_id=example — formulas not installed (run make apply_formula first)"
    skip "make apply_nosudo      minion_id=example — formulas not installed (run make apply_formula first)"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 4. relenv checks (non-destructive) ═══════════════════════════════"
# Note: we no longer run relenv_rm + reinstall here to avoid destroying the
# existing environment and re-downloading ~31 MB on every test run.

if [ -x "${CURDIR}/.tmp/relenv/bin/python3" ] && \
   [ -x "${CURDIR}/.tmp/relenv/bin/salt-call" ] && \
   [ -f "${CURDIR}/.tmp/.relenv_installed" ]; then
    pass "relenv binaries and sentinel present"
else
    fail "relenv binaries or sentinel missing"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 5. Skipped targets ════════════════════════════════════════════════"
skip "make deps      — requires apt-get"
skip "make pull      — requires SSH access to git remote"
skip "make apply*    — applies real state changes (use test_apply* for dry-run)"
skip "make all       — wraps apply* + pull"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ Summary ══════════════════════════════════════════════════════════"
echo "   Passed: ${PASS}"
echo "   Failed: ${FAIL}"

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Failed checks:"
    for e in "${ERRORS[@]}"; do echo "   - $e"; done
    echo ""
    exit 1
fi

echo ""
echo "All checks passed."
exit 0
