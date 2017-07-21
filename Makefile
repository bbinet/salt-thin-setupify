THIN_VERSION=nitrogen_thin_tgz
THIN_MD5="a54221abdf986ae7d776313552be1376"
THIN_RM := $(shell echo "${THIN_MD5}  .tmp/thin.tgz" | md5sum --check --status || echo thin_rm)
HOST=$(shell hostname)
UID := $(shell id -u)
SUDO := $(shell test ${UID} -eq 0 || echo "sudo")
SALT=python2.7 .tmp/thin/salt-call -c ${CURDIR}
SALT_APPLY=${SALT} --state-output=changes state.apply

help:
	@echo "Available targets: deps pull thin thin_rm grains pillar salt apply apply_formula apply_nosudo apply_sudo all"

deps:
	${SUDO} apt-get install -y git wget python2.7 python-apt jq

pull:
	GIT_SSH=".ssh/git.sh" git pull

.tmp/etc/salt/minion_id:
	mkdir -p .tmp/etc/salt/
	echo "root: ${CURDIR}" > grains
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

grains: thin
	${SALT} grains.items
pillar: thin
	${SALT} pillar.items
salt: thin
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter salt arguments below:\n${SALT} "; \
		read -r arg; \
	fi; \
	${SALT} $$arg
apply: thin
	@arg="$(arg)"; \
	if [ -z "$$arg" ]; then \
		echo -n "Enter state to apply:\n${SALT_APPLY} "; \
		read -r arg; \
	fi; \
	${SALT_APPLY} $$arg
apply_formula: thin
	# this state should be run twice because jinja is not evaluated at runtime:
	# https://github.com/saltstack/salt/issues/38072
	${SALT_APPLY} --log-level=quiet setupify.formula localconfig=.ignore_class_notfound
	${SALT_APPLY} --log-level=quiet setupify.formula localconfig=.ignore_class_notfound
apply_nosudo: thin
	${SALT_APPLY} setupify.nosudo
apply_sudo: thin
	${SUDO} ${SALT_APPLY} setupify.sudo

all: deps pull apply_formula apply_nosudo apply_sudo

.PHONY: deps pull thin thin_rm grains pillar salt apply apply_formula apply_nosudo apply_sudo all
