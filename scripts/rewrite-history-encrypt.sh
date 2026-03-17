#!/usr/bin/env bash
# scripts/rewrite-history-encrypt.sh
#
# Rewrites git history to encrypt SOPS/age secrets in reclass/ YAML files.
# Use this as a one-time migration when plaintext passwords were already
# committed to the repository.
#
# Usage:
#   ./scripts/rewrite-history-encrypt.sh [OPTIONS]
#
# Options:
#   --dry-run            Preview affected commits/files without modifying anything
#   --since <REF>        Only rewrite commits reachable from <REF> (e.g. a tag or SHA)
#   --key-file <PATH>    Path to age private key (default: $SOPS_AGE_KEY_FILE or
#                        ~/.config/sops/age/keys.txt)
#   --yes                Skip confirmation prompt
#
# WARNING: This rewrites git history. All collaborators must re-clone or
# rebase their local branches after this operation.
# A backup branch is created automatically before any changes.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DRY_RUN=false
YES=false
SINCE=""
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
SOPS_YAML="${REPO_ROOT}/.sops.yaml"
ENCRYPTED_REGEX="^(password|passwd|secret|token|api_key|private_key|pass|key|credential|auth)$"
SENSITIVE_GREP_REGEX='^\s*(password|passwd|secret|token|api_key|private_key|pass|key|credential|auth)\s*:\s*\S'

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)   DRY_RUN=true; shift ;;
        --since)     SINCE="$2"; shift 2 ;;
        --key-file)  AGE_KEY_FILE="$2"; shift 2 ;;
        --yes)       YES=true; shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
    command -v sops >/dev/null 2>&1  || die "sops not found. Run 'make sops_setup' first."
    command -v age  >/dev/null 2>&1  || die "age not found. Run 'make sops_setup' first."

    [[ -f "${AGE_KEY_FILE}" ]] \
        || die "Age private key not found at ${AGE_KEY_FILE}.\n       Run 'make sops_setup' or set SOPS_AGE_KEY_FILE."

    [[ -f "${SOPS_YAML}" ]] \
        || die ".sops.yaml not found. Run 'make sops_setup' first."

    grep -q "age1REPLACE_WITH_YOUR_PUBLIC_KEY" "${SOPS_YAML}" 2>/dev/null \
        && die ".sops.yaml still has the placeholder key. Run 'make sops_setup' first."

    [[ -z "$(git status --porcelain)" ]] \
        || die "Working directory has uncommitted changes.\n       Commit or stash them before rewriting history."
}

# Extract the age public key from the private key file
get_age_pubkey() {
    grep "^# public key:" "${AGE_KEY_FILE}" | awk '{print $NF}'
}

# ---------------------------------------------------------------------------
# Dry-run: show affected commits without touching anything
# ---------------------------------------------------------------------------
run_dry_run() {
    bold "=== DRY RUN: scanning history for plaintext secrets ==="
    echo ""

    local ref_range="--all"
    [[ -n "${SINCE}" ]] && ref_range="${SINCE}..HEAD"

    local found_any=false
    local commit_count=0

    # Write git log to a temp file to avoid process substitution (< <(...)),
    # which requires /dev/fd and may not be available in all environments.
    local _dryrun_log
    _dryrun_log="$(mktemp /tmp/sops-dryrun-log-XXXXXX.txt)"
    git log --format="%H %s" ${ref_range} > "${_dryrun_log}"
    trap 'rm -f "${_dryrun_log}"' RETURN

    while IFS= read -r line; do
        local hash subject
        hash="${line%% *}"
        subject="${line#* }"

        # List reclass YAML files in this commit's tree
        local files
        files=$(git ls-tree -r --name-only "${hash}" 2>/dev/null \
                | grep -E '^reclass/.*\.ya?ml$' || true)

        [[ -z "${files}" ]] && continue

        local affected_files=()
        local affected_reasons=()
        while IFS= read -r f; do
            local content
            content=$(git show "${hash}:${f}" 2>/dev/null || true)
            [[ -z "${content}" ]] && continue

            if echo "${content}" | grep -q "^sops:" 2>/dev/null; then
                # Already has sops metadata: only flag if there are plaintext
                # sensitive fields (value is not ENC[...]) — the mixed state.
                local mixed_keys
                mixed_keys=$(echo "${content}" \
                    | grep -E "${SENSITIVE_GREP_REGEX}" \
                    | grep -v "ENC\[" \
                    | grep -oE "^\s*[a-z_]+" \
                    | tr -d ' ' || true)
                if [[ -n "${mixed_keys}" ]]; then
                    affected_files+=("${f}")
                    affected_reasons+=("mixed:${mixed_keys}")
                fi
            else
                # Fully plaintext: flag if any sensitive key present
                local plain_keys
                plain_keys=$(echo "${content}" \
                    | grep -oE "${SENSITIVE_GREP_REGEX}" \
                    | grep -oE "^\s*[a-z_]+" \
                    | tr -d ' ' || true)
                if [[ -n "${plain_keys}" ]]; then
                    affected_files+=("${f}")
                    affected_reasons+=("plaintext:${plain_keys}")
                fi
            fi
        done <<< "${files}"

        if [[ ${#affected_files[@]} -gt 0 ]]; then
            found_any=true
            (( commit_count++ )) || true
            yellow "Commit ${hash:0:8} — ${subject}"
            for i in "${!affected_files[@]}"; do
                local f="${affected_files[$i]}"
                local reason="${affected_reasons[$i]}"
                local kind="${reason%%:*}"
                local keys="${reason#*:}"
                if [[ "${kind}" == "mixed" ]]; then
                    echo "  would re-encrypt (mixed state — new plaintext field): ${f}"
                else
                    echo "  would encrypt: ${f}"
                fi
                echo "    keys: ${keys}"
            done
            echo ""
        fi
    done < "${_dryrun_log}"

    if [[ "${found_any}" == false ]]; then
        green "No plaintext secrets found in history. Nothing to do."
    else
        echo "---"
        yellow "${commit_count} commit(s) would be rewritten."
        echo ""
        echo "Run without --dry-run to apply the encryption."
    fi
}

# ---------------------------------------------------------------------------
# Main history rewrite
# ---------------------------------------------------------------------------
run_rewrite() {
    local age_pubkey
    age_pubkey="$(get_age_pubkey)"
    [[ -z "${age_pubkey}" ]] && die "Could not read age public key from ${AGE_KEY_FILE}"

    local backup_branch="backup/pre-sops-$(date +%Y%m%d-%H%M%S)"
    local current_branch
    current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD)"

    # Scope: --all branches/tags, or from a specific ref
    local filter_refs="--all"
    [[ -n "${SINCE}" ]] && filter_refs="--ancestry-path ${SINCE}..HEAD"

    # ---------------------------------------------------------------------------
    # Confirmation
    # ---------------------------------------------------------------------------
    if [[ "${YES}" == false ]]; then
        bold "=== SOPS/age history rewrite ==="
        echo ""
        echo "This will:"
        echo "  1. Create a backup branch: ${backup_branch}"
        echo "  2. Rewrite ALL matching commits to encrypt plaintext secrets in reclass/"
        echo "  3. Rewrite associated tags"
        echo ""
        yellow "WARNING: This modifies git history."
        yellow "After this operation, all collaborators must re-clone or run:"
        yellow "  git fetch origin && git reset --hard origin/<branch>"
        echo ""
        printf "Continue? [y/N] "
        read -r confirm
        [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
        echo ""
    fi

    # ---------------------------------------------------------------------------
    # Backup
    # ---------------------------------------------------------------------------
    git branch "${backup_branch}"
    green "Backup branch created: ${backup_branch}"

    # ---------------------------------------------------------------------------
    # Build the per-commit tree-filter script
    # Variable expansion happens here (outer shell), so $age_pubkey, etc. are
    # baked into the temp script. Inside the script, $f is the loop variable.
    # ---------------------------------------------------------------------------
    # Use a global (not local) variable so the EXIT trap can reference it
    # even after early exits triggered by set -e inside this function.
    _FILTER_SCRIPT="$(mktemp /tmp/sops-history-filter-XXXXXX.sh)"
    chmod +x "${_FILTER_SCRIPT}"
    trap 'rm -f "${_FILTER_SCRIPT:-}"' EXIT
    local filter_script="${_FILTER_SCRIPT}"

    cat > "${filter_script}" << 'FILTER_SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail
export SOPS_AGE_KEY_FILE="__AGE_KEY_FILE__"
AGE_PUBKEY="__AGE_PUBKEY__"
ENCRYPTED_REGEX="__ENCRYPTED_REGEX__"
SENSITIVE_GREP_REGEX='__SENSITIVE_GREP_REGEX__'

# Return 0 if the file has at least one sensitive key whose value is NOT ENC[...]
# i.e. a plaintext secret that still needs encrypting.
has_plaintext_secret() {
    local f="$1"
    grep -E "${SENSITIVE_GREP_REGEX}" "$f" 2>/dev/null | grep -qv "ENC\["
}

# Use a pipe instead of < <(...) to avoid requiring /dev/fd support.
# The || true ensures find's non-zero exit (e.g. when reclass/ does not yet
# exist in a commit) does not abort the script under set -euo pipefail.
{ find reclass \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null || true; } \
| while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    if grep -q "^sops:" "$f" 2>/dev/null; then
        # File already has sops metadata.
        # Check for the MIXED state: a later commit added a new plaintext
        # secret to a file that was previously encrypted.
        # Sops stores encrypted values as ENC[...]; any sensitive key whose
        # value does NOT match that pattern is a new, unencrypted field.
        if has_plaintext_secret "$f"; then
            # Decrypt to a temp file, then re-encrypt from scratch so the
            # new plaintext fields are included in the encryption.
            tmp="$(mktemp /tmp/sops-plain-$$.yml)"
            if SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" \
               sops --decrypt "$f" > "$tmp" 2>/tmp/sops-err-$$.txt; then
                cp "$tmp" "$f"
                if sops --encrypt \
                        --age "${AGE_PUBKEY}" \
                        --encrypted-regex "${ENCRYPTED_REGEX}" \
                        --in-place "$f" 2>>/tmp/sops-err-$$.txt; then
                    echo "  [+] re-encrypted (new plaintext field found): $f" >&2
                else
                    echo "  [!] sops re-encrypt error on $f: $(cat /tmp/sops-err-$$.txt)" >&2
                fi
            else
                echo "  [!] sops decrypt error on $f (different key?): $(cat /tmp/sops-err-$$.txt)" >&2
                echo "      File left as-is." >&2
            fi
            rm -f "$tmp" /tmp/sops-err-$$.txt
        fi
        # else: file fully encrypted, nothing to do.

    else
        # File has no sops metadata — fully plaintext.
        # Encrypt if it contains any sensitive key.
        if has_plaintext_secret "$f"; then
            if sops --encrypt \
                    --age "${AGE_PUBKEY}" \
                    --encrypted-regex "${ENCRYPTED_REGEX}" \
                    --in-place "$f" 2>/tmp/sops-err-$$.txt; then
                echo "  [+] encrypted: $f" >&2
            else
                echo "  [!] sops error on $f: $(cat /tmp/sops-err-$$.txt)" >&2
            fi
            rm -f /tmp/sops-err-$$.txt
        fi
    fi
done
FILTER_SCRIPT_EOF

    # Substitute the baked-in variables.
    # Python is used instead of sed because the regex values contain characters
    # (|, \s, \S) that would be misinterpreted as sed delimiters or escape
    # sequences in the replacement string.
    python3 -c "
import sys
path, key_file, pubkey, enc_re, grep_re = sys.argv[1:]
content = open(path).read()
content = content.replace('__AGE_KEY_FILE__',        key_file)
content = content.replace('__AGE_PUBKEY__',          pubkey)
content = content.replace('__ENCRYPTED_REGEX__',     enc_re)
content = content.replace('__SENSITIVE_GREP_REGEX__', grep_re)
open(path, 'w').write(content)
" "${filter_script}" \
      "${AGE_KEY_FILE}" \
      "${age_pubkey}" \
      "${ENCRYPTED_REGEX}" \
      "${SENSITIVE_GREP_REGEX}"

    # ---------------------------------------------------------------------------
    # Rewrite history
    # git filter-branch -f: force (overwrite existing refs/original/ if present)
    # --tree-filter: run our script after checking out each commit's tree
    # --tag-name-filter cat: rewrite tags to point to new commits
    # ---------------------------------------------------------------------------
    echo ""
    bold "Rewriting history... (this may take a while)"
    echo ""

    # FILTER_BRANCH_SQUELCH_WARNING suppresses the deprecation notice
    FILTER_BRANCH_SQUELCH_WARNING=1 \
    git filter-branch -f \
        --tree-filter "bash ${filter_script}" \
        --tag-name-filter cat \
        -- ${filter_refs}

    # ---------------------------------------------------------------------------
    # Cleanup refs/original (created by filter-branch as a safety net)
    # We keep the backup branch, so refs/original is redundant.
    # ---------------------------------------------------------------------------
    git for-each-ref --format="%(refname)" refs/original/ \
        | xargs -r git update-ref -d

    # ---------------------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------------------
    echo ""
    green "=== History rewrite complete ==="
    echo ""
    echo "Backup of original history: ${backup_branch}"
    echo "  To restore: git reset --hard ${backup_branch}"
    echo ""
    bold "Next steps:"
    echo ""
    echo "  1. Verify the rewrite looks correct:"
    echo "       git log --oneline"
    echo "       git show HEAD:reclass/nodes/<your-node>.yml"
    echo ""
    echo "  2. Push to remote (force push is required after history rewrite):"
    echo "       git push --force-with-lease origin --all"
    echo "       git push --force-with-lease origin --tags"
    echo ""
    yellow "  3. Notify all collaborators — they must reset their local copies:"
    yellow "       git fetch origin && git reset --hard origin/${current_branch}"
    echo ""
    echo "  4. Make sops_decrypt before running salt-call:"
    echo "       make sops_decrypt"
    echo ""
    echo "  5. When you're satisfied, delete the backup branch:"
    echo "       git branch -D ${backup_branch}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
check_prerequisites

if [[ "${DRY_RUN}" == true ]]; then
    run_dry_run
else
    run_rewrite
fi
