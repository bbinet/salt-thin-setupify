ifeq (, $(shell which python3.7 ))
    $(error "No python3.7 found in $(PATH), please run: apt install python3.7")
endif
THIN_VERSION=py3_3003_thin_tgz
THIN_MD5="0c14a7e4e8dcaf4c8b17eb7ed10f35c8"
THIN_RM := $(shell echo "${THIN_MD5}  .tmp/thin.tgz" | md5sum --check --status || echo thin_rm)
HOST=$(shell hostname)
UID := $(shell id -u)
SUDO := $(shell test ${UID} -eq 0 || echo "sudo")
SALT=python3.7 .tmp/thin/salt-call --retcode-passthrough -c ${CURDIR}
SALT_APPLY=${SALT} --state-output=changes state.apply
SOPS_AGE_KEY_FILE ?= ${HOME}/.config/sops/age/keys.txt

help:
	@echo "Available targets:"
	@echo "    deps pull thin thin_rm"
	@echo "    grains pillar salt apply_ext apply_formula"
	@echo "    apply apply_nosudo apply_sudo"
	@echo "    test_apply test_apply_nosudo test_apply_sudo"
	@echo "    all (= deps pull apply_ext apply_formula apply_nosudo apply_sudo)"
	@echo ""
	@echo "SOPS/age encryption targets:"
	@echo "    sops_setup           install sops + age and generate age key pair"
	@echo "    sops_install_hook    install git pre-commit hook for auto-encryption"
	@echo "    sops_decrypt         decrypt reclass/ secrets to .tmp/reclass/"
	@echo "    sops_encrypt         (re)encrypt all secrets in reclass/"
	@echo "    sops_history_encrypt rewrite git history to encrypt past commits"
	@echo "                         use DRY_RUN=1 to preview, SINCE=<ref> to limit scope"

deps:
	${SUDO} apt-get update && ${SUDO} apt-get install -y git wget python3-apt jq

pull:
	GIT_SSH=".ssh/git.sh" git pull

.tmp/etc/salt/minion_id:
	mkdir -p .tmp/etc/salt/
	echo "root: ${CURDIR}" > grains
	@noservices="$(noservices)"; \
	if [ "$$noservices" = "true" ]; then \
		echo "noservices: true" >> grains; \
	fi
	@minion_id="$(minion_id)"; \
	if [ -z "$$minion_id" ]; then \
		echo -n "Enter minion_id [${HOST}]: "; \
		read -r minion_id; \
	fi; \
	echo "$${minion_id:-${HOST}}" > .tmp/etc/salt/minion_id
.tmp/thin.tgz: ${THIN_RM}
	wget -O .tmp/thin.tgz https://github.com/bbinet/salt/releases/download/${THIN_VERSION}/thin.tgz
	rm -fr .tmp/thin && mkdir -p .tmp/thin && tar zxvf .tmp/thin.tgz -C .tmp/thin/
thin: .tmp/thin.tgz .tmp/etc/salt/minion_id
thin_rm:
	rm -f .tmp/thin.tgz

salt: thin
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter salt arguments below:\n${SALT} "; \
		read -r arg; \
	fi; \
	${SALT} $$arg
grains: thin
	${SALT} grains.items
pillar: thin
	${SALT} pillar.items
apply: thin
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter state to apply:\n${SALT_APPLY} "; \
		read -r arg; \
	fi; \
	${SALT_APPLY} $$arg
apply_ext: thin
	${SALT_APPLY} setupify.ext
apply_formula: thin
	# this state should be run twice because jinja is not evaluated at runtime:
	# https://github.com/saltstack/salt/issues/38072
	${SALT_APPLY} setupify.formula
	${SALT_APPLY} setupify.formula
	${SALT} saltutil.sync_all
apply_nosudo: thin
	${SALT_APPLY} setupify.nosudo
apply_sudo: thin
	${SUDO} ${SALT_APPLY} setupify.sudo
test_apply: thin
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter state to test apply:\n${SALT_APPLY} "; \
		read -r arg; \
	fi; \
	${SALT_APPLY} $$arg test=True
test_apply_nosudo: thin
	${SALT_APPLY} setupify.nosudo test=True
test_apply_sudo: thin
	${SUDO} ${SALT_APPLY} setupify.sudo test=True

all: deps pull apply_ext apply_formula apply_nosudo apply_sudo

# ---------------------------------------------------------------------------
# SOPS + age targets
# ---------------------------------------------------------------------------

sops_setup:
	@bash scripts/sops-setup.sh --key-file "${SOPS_AGE_KEY_FILE}"

sops_install_hook:
	@cp hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed at .git/hooks/pre-commit"

# Decrypt encrypted reclass files to .tmp/reclass/ for use by salt-call.
# Files without sops metadata are copied as-is.
sops_decrypt:
	@if ! command -v sops >/dev/null 2>&1; then \
		echo "sops not found. Run 'make sops_setup' first."; exit 1; \
	fi
	@rm -rf .tmp/reclass && mkdir -p .tmp/reclass
	@find reclass -name "*.yml" -o -name "*.yaml" | while read f; do \
		dest=".tmp/$${f}"; \
		mkdir -p "$$(dirname $${dest})"; \
		if grep -q "^sops:" "$${f}" 2>/dev/null; then \
			SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --decrypt "$${f}" > "$${dest}"; \
			echo "  decrypted: $${f}"; \
		else \
			cp "$${f}" "$${dest}"; \
		fi; \
	done
	@echo "Reclass files ready in .tmp/reclass/"

# Encrypt (or re-encrypt) all reclass YAML files that contain sensitive keys.
sops_encrypt:
	@if ! command -v sops >/dev/null 2>&1; then \
		echo "sops not found. Run 'make sops_setup' first."; exit 1; \
	fi
	@if grep -q "age1REPLACE_WITH_YOUR_PUBLIC_KEY" .sops.yaml 2>/dev/null; then \
		echo ".sops.yaml not configured. Run 'make sops_setup' first."; exit 1; \
	fi
	@find reclass -name "*.yml" -o -name "*.yaml" | while read f; do \
		if grep -q "^sops:" "$${f}" 2>/dev/null; then \
			echo "  re-encrypting: $${f}"; \
			SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --encrypt --in-place "$${f}"; \
		elif grep -qE "^[[:space:]]+(password|passwd|secret|token|api_key|private_key|pass|key|credential|auth)[[:space:]]*:" "$${f}" 2>/dev/null; then \
			echo "  encrypting: $${f}"; \
			SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --encrypt --in-place "$${f}"; \
		fi; \
	done

# Rewrite git history to encrypt secrets committed in the past (one-time migration).
# Use --dry-run first to preview what would change, then run without it to apply.
# Options: DRY_RUN=1, SINCE=<ref>, KEY_FILE=<path>
sops_history_encrypt:
	@dry_run_flag=""; \
	since_flag=""; \
	yes_flag="--yes"; \
	if [ "$(DRY_RUN)" = "1" ]; then dry_run_flag="--dry-run"; yes_flag=""; fi; \
	if [ -n "$(SINCE)" ]; then since_flag="--since $(SINCE)"; fi; \
	SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" \
	bash scripts/rewrite-history-encrypt.sh \
		$${dry_run_flag} $${since_flag} $${yes_flag} \
		$(if $(KEY_FILE),--key-file $(KEY_FILE),)

test_sops:
	@bash tests/test-sops-encryption.sh

.PHONY: deps pull thin thin_rm grains pillar salt apply apply_ext apply_formula apply_nosudo apply_sudo test_apply test_apply_nosudo test_apply_sudo all sops_setup sops_install_hook sops_decrypt sops_encrypt sops_history_encrypt test_sops
