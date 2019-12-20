THIN_VERSION=fluorine_thin_tgz
THIN_MD5="85ad5afedd1df48756ede8b2c6c76341"
THIN_RM := $(shell echo "${THIN_MD5}  .tmp/thin.tgz" | md5sum --check --status || echo thin_rm)
HOST=$(shell hostname)
UID := $(shell id -u)
SUDO := $(shell test ${UID} -eq 0 || echo "sudo")
SALT=python3 .tmp/thin/salt-call -c ${CURDIR}
SALT_APPLY=${SALT} --state-output=changes state.apply

help:
	@echo "Available targets:"
	@echo "    deps pull thin thin_rm"
	@echo "    grains pillar salt apply_ext apply_formula"
	@echo "    apply apply_nosudo apply_sudo"
	@echo "    test_apply test_apply_nosudo test_apply_sudo"
	@echo "    all (= deps pull apply_ext apply_formula apply_nosudo apply_sudo)"

deps:
	${SUDO} apt-get update && ${SUDO} apt-get install -y git wget python3 python3-apt jq

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

.PHONY: deps pull thin thin_rm grains pillar salt apply apply_ext apply_formula apply_nosudo apply_sudo test_apply test_apply_nosudo test_apply_sudo all
