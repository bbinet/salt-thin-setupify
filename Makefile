RELENV_VERSION=0.22.5
PYTHON_VERSION=3.11.14
SALT_VERSION=3007.*
ARCH=$(shell uname -m)
RELENV_TRIPLET=$(PYTHON_VERSION)-$(ARCH)-linux-gnu
RELENV_URL=https://github.com/saltstack/relenv/releases/download/v$(RELENV_VERSION)/$(RELENV_TRIPLET).tar.xz
HOST=$(shell hostname)
UID := $(shell id -u)
SUDO := $(shell test ${UID} -eq 0 || echo "sudo")
SALT=.tmp/relenv/bin/salt-call --retcode-passthrough -c ${CURDIR}
SALT_APPLY=${SALT} --state-output=changes state.apply

help:
	@echo "Available targets:"
	@echo "    deps pull relenv relenv_rm"
	@echo "    grains pillar salt apply_ext apply_formula"
	@echo "    apply apply_nosudo apply_sudo"
	@echo "    test_apply test_apply_nosudo test_apply_sudo"
	@echo "    check"
	@echo "    all (= deps pull apply_ext apply_formula apply_nosudo apply_sudo)"

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

# Sentinel file: rebuilt whenever requirements.txt changes
.tmp/.relenv_installed: requirements.txt
	mkdir -p .tmp
	@echo "==> Downloading relenv Python $(PYTHON_VERSION) for $(ARCH)..."
	wget -q -O - $(RELENV_URL).sha256 > .tmp/relenv.tar.xz.sha256
	wget -O .tmp/relenv.tar.xz $(RELENV_URL)
	@HASH=$$(awk '{print $$1}' .tmp/relenv.tar.xz.sha256); \
	echo "$$HASH  .tmp/relenv.tar.xz" | sha256sum --check
	rm -f .tmp/relenv.tar.xz.sha256
	rm -rf .tmp/relenv && mkdir -p .tmp/relenv
	tar xJf .tmp/relenv.tar.xz -C .tmp/relenv/
	rm -f .tmp/relenv.tar.xz
	@echo "==> Installing salt $(SALT_VERSION)..."
	.tmp/relenv/bin/pip install --quiet "salt==$(SALT_VERSION)"
	@echo "==> Installing extra requirements..."
	.tmp/relenv/bin/pip install --quiet -r requirements.txt
	touch .tmp/.relenv_installed

relenv: .tmp/.relenv_installed .tmp/etc/salt/minion_id
relenv_rm:
	rm -rf .tmp/relenv .tmp/.relenv_installed

check: .tmp/.relenv_installed
	@bash tests/check_env.sh

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

.PHONY: deps pull relenv relenv_rm check grains pillar salt apply apply_ext apply_formula apply_nosudo apply_sudo test_apply test_apply_nosudo test_apply_sudo all
