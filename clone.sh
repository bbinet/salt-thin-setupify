#!/bin/bash

set -e

usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "    Available [options] are:"
  echo "      -h|--help"
  echo "      -d|--dir <path to the directory in which setupify will be cloned [.]>"
  echo "      -t|--targets <comma separated list of make targets to apply once cloned [deps]>"
  echo "                  (one of: deps thin apply_formula apply_nosudo apply_sudo all)"
  echo "      -i|--id <minion_id to set []>"
}

OPTS=`getopt -o hd:t:i: --long help,dir:,target:,id: -- "$@"`
if [ $? != 0 ]
then
    usage
    exit 1
fi

eval set -- "$OPTS"

# set default values
base_dir="."
make_targets="deps"
minion_id=""
while true ; do
    case "$1" in
        -h|--help) usage; exit 0; shift;;
        -d|--dir) base_dir=$2; shift 2;;
        -t|--target) make_targets=$2; shift 2;;
        -i|--id) minion_id=$2; shift 2;;
        --) shift; break;;
    esac
done
IFS=',' read -ra make_targets_arr <<< "$make_targets"

cd $base_dir

if [ -d "./setupify/.git" ] || [ -d "../setupify/.git" ]
then
  echo "Nothing to do, setupify directory already exists"
  exit 0
fi

mkdir -p /tmp/_setupify_
cat << EOF > /tmp/_setupify_/.deploy_key-id_rsa
-----BEGIN RSA PRIVATE KEY-----
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
-----END RSA PRIVATE KEY-----
EOF
cat << \EOF > /tmp/_setupify_/.git.sh
#!/bin/bash
/usr/bin/ssh -i /tmp/_setupify_/.deploy_key-id_rsa "$@"
EOF
chmod 400 /tmp/_setupify_/.deploy_key-id_rsa
chmod 700 /tmp/_setupify_/.git.sh

if ! grep -q github.com ~/.ssh/known_hosts
then
  mkdir -p -m 700 ~/.ssh/
  ssh-keyscan github.com >> ~/.ssh/known_hosts
fi
if ! grep -q bitbucket.org ~/.ssh/known_hosts
then
  mkdir -p -m 700 ~/.ssh/
  ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts
fi

GIT_SSH=/tmp/_setupify_/.git.sh git clone --branch master git@github.com:bbinet/salt-thin-setupify.git ./setupify
rm -fr /tmp/_setupify_/

chmod 400 setupify/.ssh/id_rsa
chmod 700 setupify/.ssh/git.sh

(cd setupify; minion_id="$minion_id" make ${make_targets_arr[@]})
