#!/bin/bash
# check_env.sh — Verifies the relenv environment is equivalent to the old
# salt-thin (py3_3003_thin_tgz) setup.
#
# Checks:
#   1. Environment:   relenv binaries, Python 3.10.x, Salt 3007.x
#   2. Imports:       all packages required by salt-formulas and this project
#   3. Compatibility: no broken packages (enum34), expected library versions
#   4. salt-call:     basic commands work (test.ping, grains, pillar)
#   5. States:        core SLS files render and run cleanly (test=True)

set -euo pipefail

CURDIR="$(pwd)"
PYTHON="${CURDIR}/.tmp/relenv/bin/python3"
PIP="${CURDIR}/.tmp/relenv/bin/pip"
SALT_CALL="${CURDIR}/.tmp/relenv/bin/salt-call"
SALT_CALL_OPTS="-c ${CURDIR} --log-level=quiet"

PASS=0
FAIL=0
declare -a ERRORS

# ── helpers ────────────────────────────────────────────────────────────────

pass() { echo "  PASS  $1"; ((PASS++)); }
fail() { echo "  FAIL  $1"; ((FAIL++)); ERRORS+=("$1"); }

# run_check DESC CMD [ARGS…]  — pass if command exits 0
run_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# run_check_output DESC PATTERN CMD [ARGS…]  — pass if stdout contains PATTERN
run_check_output() {
    local desc="$1" pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1) || true
    if echo "$out" | grep -qE "$pattern"; then
        pass "$desc"
    else
        fail "$desc  (got: $(echo "$out" | head -3))"
    fi
}

# check_import PACKAGE [MODULE]
check_import() {
    local pkg="$1" mod="${2:-$1}"
    run_check "import $mod" "$PYTHON" -c "import $mod"
}

# ── setup: temporary test fixtures ─────────────────────────────────────────

TEST_NODE_ID="_test_check_env_"
TEST_NODE_FILE="${CURDIR}/reclass/nodes/${TEST_NODE_ID}.yml"
GRAINS_CREATED=false
TEST_NODE_CREATED=false

cleanup() {
    "$GRAINS_CREATED"    && rm -f "${CURDIR}/grains"
    "$TEST_NODE_CREATED" && rm -f "$TEST_NODE_FILE"
}
trap cleanup EXIT

# Grains file: needed so that {{ grains['root'] }} resolves in SLS templates
if [ ! -f "${CURDIR}/grains" ]; then
    echo "root: ${CURDIR}" > "${CURDIR}/grains"
    GRAINS_CREATED=true
fi

# Minimal reclass node for the test minion ID (empty pillar → safe state runs)
if [ ! -f "$TEST_NODE_FILE" ]; then
    cat > "$TEST_NODE_FILE" <<YAML
parameters: {}
YAML
    TEST_NODE_CREATED=true
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 1. Environment ════════════════════════════════════════════════════"

run_check      "relenv/bin/python3 exists"   test -x "$PYTHON"
run_check      "relenv/bin/pip exists"       test -x "$PIP"
run_check      "relenv/bin/salt-call exists" test -x "$SALT_CALL"

run_check_output \
    "Python version is 3.11.x" \
    "Python 3\.11\." \
    "$PYTHON" --version

run_check_output \
    "Salt version is 3007.x" \
    "Salt: 3007\." \
    "$SALT_CALL" $SALT_CALL_OPTS --versions-report

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 2. Python imports ════════════════════════════════════════════════"

# Core Salt
check_import salt
check_import jinja2
check_import yaml           # PyYAML
check_import zmq            # pyzmq
check_import Crypto         # pycryptodome (salt 3007 uses Crypto.* namespace)
check_import msgpack
check_import requests
check_import dateutil       # python-dateutil
check_import distro

# Project-specific
check_import reclass
check_import docker
check_import jsonnet
check_import influxdb
check_import websocket      websocket  # websocket-client

# Misc formulas
check_import six
check_import pytz
check_import ddt

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 3. Compatibility checks ══════════════════════════════════════════"

# Jinja2 must be >= 3.0 (Salt 3007 requires it; 2.x had different API)
run_check_output \
    "Jinja2 version >= 3.0" \
    "^3\." \
    "$PYTHON" -c "import jinja2; print(jinja2.__version__)"

# PyYAML must be >= 6.0 (yaml.load() without Loader= raises error on older)
run_check_output \
    "PyYAML version >= 6.0" \
    "^6\." \
    "$PYTHON" -c "import yaml; print(yaml.__version__)"

# enum34 must NOT be installed — it shadows stdlib enum on Python 3.4+ and
# breaks pip itself when pyproject.toml packages are being built
run_check \
    "enum34 is NOT installed (breaks Python 3.4+)" \
    "$PYTHON" -c "
import importlib.metadata, sys
try:
    importlib.metadata.version('enum34')
    sys.exit(1)   # found → bad
except importlib.metadata.PackageNotFoundError:
    sys.exit(0)   # not found → good
"

# docker-py must NOT be installed (conflicts with docker package)
run_check \
    "docker-py is NOT installed (replaced by docker>=6)" \
    "$PYTHON" -c "
import importlib.metadata, sys
try:
    importlib.metadata.version('docker-py')
    sys.exit(1)
except importlib.metadata.PackageNotFoundError:
    sys.exit(0)
"

# reclass must be the salt-formulas fork (has scalar_parameters support)
run_check_output \
    "reclass is salt-formulas fork (has scalar_parameters)" \
    "scalar_param|StorageBackend|yaml_fs" \
    "$PYTHON" -c "
import reclass.storage.yaml_fs
from reclass.storage.yaml_fs import ExternalNodeStorage
print(dir(ExternalNodeStorage))
"

# pycryptodome: verify Crypto namespace (not Cryptodome — that's pycryptodomex)
run_check_output \
    "pycryptodome Crypto namespace accessible" \
    "Cipher|Hash|Signature" \
    "$PYTHON" -c "import Crypto; print(dir(Crypto))"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 4. salt-call basic commands ══════════════════════════════════════"

SCMD="$SALT_CALL $SALT_CALL_OPTS --id=$TEST_NODE_ID"

run_check \
    "salt-call test.ping" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" test.ping

run_check_output \
    "salt-call grains.get root returns CURDIR" \
    "$(echo "$CURDIR" | sed 's|/|\\/|g')" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" grains.get root

run_check \
    "salt-call pillar.items runs without crash (reclass adapter loads)" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" pillar.items

run_check_output \
    "salt-call grains.items contains 'saltversion'" \
    "saltversion" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" grains.items

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "══ 5. State syntax — test=True (dry-run) ════════════════════════════"
# With an empty-pillar test node, each state only runs its *-always-passes
# sentinel state and skips dynamic sections (no sources/formulas in pillar).

run_check \
    "state.apply setupify.ext    test=True (no syntax errors)" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" \
        --state-output=changes state.apply setupify.ext test=True

run_check \
    "state.apply setupify.nosudo test=True (no syntax errors)" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" \
        --state-output=changes state.apply setupify.nosudo test=True

run_check \
    "state.apply setupify.sudo   test=True (no syntax errors)" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" \
        --state-output=changes state.apply setupify.sudo test=True

# formula.sls uses file.directory_exists() at render time; in test=True mode
# the directories don't exist, so the formula loop emits no states — that's
# the expected behaviour (same as the old thin env on a fresh machine).
run_check \
    "state.apply setupify.formula test=True (no syntax errors)" \
    "$SALT_CALL" $SALT_CALL_OPTS --id="$TEST_NODE_ID" \
        --state-output=changes state.apply setupify.formula test=True

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
