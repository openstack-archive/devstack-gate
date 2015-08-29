#!/bin/bash -x

# Simulate what Jenkins does with the devstack-gate script.

NODE_IP_ADDR=$1

cat >$WORKSPACE/test-env.sh <<EOF
export WORKSPACE=/home/jenkins/workspace
export DEVSTACK_GATE_PREFIX=wip-
export DEVSTACK_GATE_TEMPEST=1
export ZUUL_BRANCH=master
export ZUUL_PROJECT=testing
export ZUUL_REF=refs/zuul/Ztest
export JOB_NAME=test
export BUILD_NUMBER=42
export GERRIT_CHANGE_NUMBER=1234
export GERRIT_PATCHSET_NUMBER=1
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}
export DEVSTACK_GATE_QUANTUM=${DEVSTACK_GATE_QUANTUM:-0}
export DEVSTACK_GATE_HEAT=${DEVSTACK_GATE_HEAT:-0}
export DEVSTACK_GATE_GRENADE=${DEVSTACK_GATE_GRENADE:-""}
EOF

rsync -az $WORKSPACE/ jenkins@$NODE_IP_ADDR:workspace-cache/
rsync -az $WORKSPACE/ jenkins@$NODE_IP_ADDR:workspace/
RETVAL=$?
if [ $RETVAL != 0 ]; then
    exit $RETVAL
fi

rm $WORKSPACE/test-env.sh
ssh -t jenkins@$NODE_IP_ADDR '. workspace/test-env.sh && cd workspace && ./devstack-gate/devstack-vm-gate-wrap.sh'
echo "done"
#RETVAL=$?
