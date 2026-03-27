RELENV_VERSION=0.22.5
PYTHON_VERSION=3.11.14
SALT_VERSION=3007.3
ARCH=$(shell uname -m)
RELENV_TRIPLET=$(PYTHON_VERSION)-$(ARCH)-linux-gnu
RELENV_URL=https://github.com/saltstack/relenv/releases/download/v$(RELENV_VERSION)/$(RELENV_TRIPLET).tar.xz
RELENV_SHA256_x86_64  = 5aa9898ae07d5dc010a405ce0964c8847e09a0b0829c693ac57474948f2b6502
RELENV_SHA256_aarch64 = 96fbb208e9a567b769aa5cfa2f707aa8ff50b112bfc00384b63d4d135563130d
RELENV_SHA256         = $(RELENV_SHA256_$(ARCH))
HOST=$(shell hostname)
UID := $(shell id -u)
SUDO := $(shell test ${UID} -eq 0 || echo "sudo")
SALT=.tmp/relenv/bin/salt-call --retcode-passthrough -c ${CURDIR}
SALT_APPLY=${SALT} --state-output=changes state.apply
SOPS_AGE_KEY_FILE ?= ${HOME}/.config/sops/age/keys.txt

help:
	@echo "Available targets:"
	@echo "    deps pull relenv relenv_rm"
	@echo "    grains pillar salt apply_ext apply_formula"
	@echo "    apply apply_nosudo apply_sudo"
	@echo "    test_apply test_apply_nosudo test_apply_sudo"
	@echo "    test (or test-unit test-env test-makefile test-sops-encryption test-sops-apply)"
	@echo "    all (= deps pull apply_ext apply_formula apply_nosudo apply_sudo)"
	@echo ""
	@echo "SOPS/age encryption targets:"
	@echo "    sops_setup           install sops + age and generate age key pair"
	@echo "    sops_install_hook    install git pre-commit hook for auto-encryption"
	@echo "    sops_decrypt         decrypt reclass/classes/secret/ to .tmp/reclass/"
	@echo "    sops_encrypt         (re)encrypt all files in reclass/classes/secret/"
	@echo "    sops_history_encrypt rewrite git history to encrypt past commits"
	@echo "                         use DRY_RUN=1 to preview, SINCE=<ref> to limit scope"

deps:
	${SUDO} apt-get update && ${SUDO} apt-get install -y git wget xz-utils jq

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

# Download and extract relenv Python (only when the binary is missing)
.tmp/.relenv_extracted:
	mkdir -p .tmp
	@echo "==> Downloading relenv Python $(PYTHON_VERSION) for $(ARCH)..."
	wget -O .tmp/relenv.tar.xz $(RELENV_URL)
	@echo "==> Verifying download integrity..."
	@if [ -z "$(RELENV_SHA256)" ]; then \
		echo "ERROR: No known SHA256 for architecture $(ARCH). Add RELENV_SHA256_$(ARCH) to Makefile."; \
		exit 1; \
	fi
	@echo "$(RELENV_SHA256)  .tmp/relenv.tar.xz" | sha256sum -c -
	rm -rf .tmp/relenv && mkdir -p .tmp/relenv
	tar xJf .tmp/relenv.tar.xz -C .tmp/relenv/
	rm -f .tmp/relenv.tar.xz
	touch .tmp/.relenv_extracted

# Install pip packages (re-run whenever requirements.txt changes)
.tmp/.relenv_installed: .tmp/.relenv_extracted requirements.txt
	@echo "==> Installing salt $(SALT_VERSION)..."
	.tmp/relenv/bin/pip3 install --quiet "salt==$(SALT_VERSION)"
	@echo "==> Installing extra requirements..."
	.tmp/relenv/bin/pip3 install --quiet -r requirements.txt
	@echo "==> Removing packages incompatible with Python 3..."
	.tmp/relenv/bin/pip3 uninstall -y enum34 2>/dev/null || true
	@echo "==> Patching reclass for Python 3.10+ (collections.abc.Iterable)..."
	sed -i 's/isinstance(w, collections\.Iterable)/isinstance(w, collections.abc.Iterable)/g' \
		.tmp/relenv/lib/python*/site-packages/reclass/values/parser_funcs.py
	touch .tmp/.relenv_installed

relenv: .tmp/.relenv_installed .tmp/etc/salt/minion_id .tmp/reclass

.tmp/reclass:
	$(MAKE) sops_decrypt
relenv_rm:
	rm -rf .tmp/relenv .tmp/.relenv_extracted .tmp/.relenv_installed

salt: relenv
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter salt arguments below:\n${SALT} "; \
		read -r arg; \
	fi; \
	${SALT} $$arg
grains: relenv
	${SALT} grains.items
pillar: relenv
	${SALT} pillar.items
apply: relenv
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter state to apply:\n${SALT_APPLY} "; \
		read -r arg; \
	fi; \
	${SALT_APPLY} $$arg
apply_ext: relenv
	${SALT_APPLY} setupify.ext
apply_formula: relenv
	# this state should be run twice because jinja is not evaluated at runtime:
	# https://github.com/saltstack/salt/issues/38072
	${SALT_APPLY} setupify.formula
	${SALT_APPLY} setupify.formula
	${SALT} saltutil.sync_all
apply_nosudo: relenv
	${SALT_APPLY} setupify.nosudo
apply_sudo: relenv
	${SUDO} ${SALT_APPLY} setupify.sudo
test_apply: relenv
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter state to test apply:\n${SALT_APPLY} "; \
		read -r arg; \
	fi; \
	${SALT_APPLY} $$arg test=True
test_apply_nosudo: relenv
	${SALT_APPLY} setupify.nosudo test=True
test_apply_sudo: relenv
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
# Only files under reclass/classes/secret/ are decrypted; all others are
# copied as plain YAML.
sops_decrypt:
	@rm -rf .tmp/reclass && mkdir -p .tmp/reclass
	@find reclass -mindepth 1 -type d | while read d; do \
		mkdir -p ".tmp/$${d}"; \
	done
	@find reclass -mindepth 1 -maxdepth 5 -type l | while read lnk; do \
		target="$$(readlink -f "$$lnk")"; \
		dest=".tmp/$${lnk}"; \
		mkdir -p "$$(dirname $${dest})"; \
		ln -sf "$$target" "$$dest"; \
	done
	@find reclass -name "*.yml" -o -name "*.yaml" | while read f; do \
		dest=".tmp/$${f}"; \
		mkdir -p "$$(dirname $${dest})"; \
		case "$${f}" in \
		reclass/classes/secret/*) \
			if grep -q "^sops:" "$${f}" 2>/dev/null; then \
				if ! command -v sops >/dev/null 2>&1; then \
					echo "sops not found but $${f} is encrypted. Run 'make sops_setup' first."; exit 1; \
				fi; \
				SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --decrypt "$${f}" > "$${dest}" || exit 1; \
				echo "  decrypted: $${f}"; \
			else \
				cp "$${f}" "$${dest}"; \
			fi; \
			;; \
		*) \
			cp "$${f}" "$${dest}"; \
			;; \
		esac; \
	done
	@echo "Reclass files ready in .tmp/reclass/"

# Encrypt (or re-encrypt) all YAML files in reclass/classes/secret/.
sops_encrypt:
	@if ! command -v sops >/dev/null 2>&1; then \
		echo "sops not found. Run 'make sops_setup' first."; exit 1; \
	fi
	@if grep -q "age1REPLACE_WITH_YOUR_PUBLIC_KEY" .sops.yaml 2>/dev/null; then \
		echo ".sops.yaml not configured. Run 'make sops_setup' first."; exit 1; \
	fi
	@if ! [ -d reclass/classes/secret ]; then \
		echo "No reclass/classes/secret/ directory found, nothing to encrypt."; exit 0; \
	fi
	@find reclass/classes/secret -name "*.yml" -o -name "*.yaml" | while read f; do \
		tmp_src=".tmp/$${f}"; \
		if [ -f "$${tmp_src}" ]; then \
			echo "  encrypting (from .tmp): $${f}"; \
			src="$${tmp_src}"; \
		elif grep -q "^sops:" "$${f}" 2>/dev/null; then \
			echo "  re-encrypting: $${f}"; \
			if ! SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --decrypt "$${f}" > "$${f}.plain" 2>/dev/null; then \
				rm -f "$${f}.plain"; \
				echo ""; \
				echo "ERROR: cannot re-encrypt $${f}"; \
				echo "To edit encrypted files:"; \
				echo "  1. make sops_decrypt"; \
				echo "  2. edit .tmp/reclass/classes/secret/..."; \
				echo "  3. make sops_encrypt"; \
				echo ""; \
				exit 1; \
			fi; \
			src="$${f}.plain"; \
		else \
			echo "  encrypting: $${f}"; \
			src="$${f}"; \
		fi; \
		if SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}" sops --encrypt "$${src}" > "$${f}.enc" 2>/dev/null; then \
			mv "$${f}.enc" "$${f}"; \
		else \
			rm -f "$${f}.enc"; \
			echo "ERROR: failed to encrypt $${f}"; \
			exit 1; \
		fi; \
		rm -f "$${f}.plain"; \
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

test_setup: .tmp/.relenv_installed
	.tmp/relenv/bin/pip3 install --quiet pytest

test-unit: test_setup
	@echo "══ Unit tests (pytest) ══════════════════════════════════════════════"
	.tmp/relenv/bin/python3 -m pytest scripts/tests/ -v

test-env: .tmp/.relenv_installed
	@echo "══ Environment checks ═══════════════════════════════════════════════"
	@bash tests/test-env.sh

test-makefile: .tmp/.relenv_installed
	@echo "══ Makefile checks ═════════════════════════════════════════════════"
	@bash tests/test-makefile.sh

test-sops-encryption:
	@echo "══ SOPS encryption tests ═══════════════════════════════════════════"
	@bash tests/test-sops-encryption.sh

test-sops-apply: .tmp/.relenv_installed
	@echo "══ SOPS apply tests ════════════════════════════════════════════════"
	@bash tests/test-sops-apply.sh

test: test-unit test-env test-makefile test-sops-encryption test-sops-apply

.PHONY: deps pull relenv relenv_rm grains pillar salt apply apply_ext apply_formula apply_nosudo apply_sudo test_apply test_apply_nosudo test_apply_sudo all sops_setup sops_install_hook sops_decrypt sops_encrypt sops_history_encrypt test_setup test-unit test-env test-makefile test-sops-encryption test-sops-apply test
