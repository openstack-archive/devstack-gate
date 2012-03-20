#!/bin/bash -x

# Gate commits to several projects on a VM running those projects
# configured by devstack.

# Copyright (C) 2011 OpenStack LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.

PROJECTS="openstack-ci/devstack-gate openstack-dev/devstack openstack/nova openstack/glance openstack/keystone openstack/python-novaclient openstack/python-keystoneclient openstack/horizon"

# Set this to 1 to always keep the host around
ALWAYS_KEEP=${ALWAYS_KEEP:-0}

cd $WORKSPACE
mkdir -p logs
rm -f logs/*

for PROJECT in $PROJECTS
do
    echo "Setting up $PROJECT"
    SHORT_PROJECT=`basename $PROJECT`
    if [[ ! -e $SHORT_PROJECT ]]; then
	echo "  Need to clone"
	git clone https://review.openstack.org/p/$PROJECT
    fi
    cd $SHORT_PROJECT
    
    BRANCH=$GERRIT_BRANCH

    # See if this project has this branch, if not, use master
    git remote update
    # Ensure that we don't have stale remotes around
    git remote prune origin
    if ! git branch -a |grep remotes/origin/$GERRIT_BRANCH>/dev/null; then
	BRANCH=master
    fi
    git reset --hard
    git clean -x -f -d -q
    git checkout $BRANCH
    git reset --hard remotes/origin/$BRANCH
    git clean -x -f -d -q

    if [[ $GERRIT_PROJECT == $PROJECT ]]; then
        echo "  Merging proposed change"
        git fetch https://review.openstack.org/p/$PROJECT $GERRIT_REFSPEC
        git merge FETCH_HEAD
    else
        echo "  Updating from origin"
        git pull --ff-only origin $BRANCH
    fi
    cd $WORKSPACE
done

# Set GATE_SCRIPT_DIR to point to devstack-gate in the workspace so that
# we are testing the proposed change from this point forward.
GATE_SCRIPT_DIR=$WORKSPACE/devstack-gate

# Also, if we're testing devstack-gate, re-exec this script once so
# that we can test the new version of it.
if [[ $GERRIT_PROJECT == "openstack-ci/devstack-gate" ]] && [[ $RE_EXEC != "true" ]]; then
    export RE_EXEC="true"
    exec $GATE_SCRIPT_DIR/devstack-vm-gate.sh
fi

FETCH_OUTPUT=`$GATE_SCRIPT_DIR/devstack-vm-fetch.py` || exit $?
eval $FETCH_OUTPUT

scp -C $GATE_SCRIPT_DIR/devstack-vm-gate-host.sh $NODE_IP_ADDR:
RETVAL=$?
if [ $RETVAL != 0 ]; then
    echo "Deleting host"
    $GATE_SCRIPT_DIR/devstack-vm-delete.py $NODE_UUID
    exit $RETVAL
fi

rsync -az --delete $WORKSPACE/ $NODE_IP_ADDR:workspace/
RETVAL=$?
if [ $RETVAL != 0 ]; then
    echo "Deleting host"
    $GATE_SCRIPT_DIR/devstack-vm-delete.py $NODE_UUID
    exit $RETVAL
fi

ssh $NODE_IP_ADDR ./devstack-vm-gate-host.sh
RETVAL=$?
# No matter what, archive logs
scp -C -q $NODE_IP_ADDR:/var/log/syslog $WORKSPACE/logs/syslog.txt
scp -C -q $NODE_IP_ADDR:/opt/stack/screen-logs/* $WORKSPACE/logs/
rename 's/\.log$/.txt/' $WORKSPACE/logs/*
# Remove duplicate logs
rm $WORKSPACE/logs/*.*.txt

# Now check whether the run was a success
if [ $RETVAL = 0 ] && [ $ALWAYS_KEEP = 0 ]; then
    echo "Deleting host"
    $GATE_SCRIPT_DIR/devstack-vm-delete.py $NODE_UUID
    exit $RETVAL
else
    #echo "Giving host to developer"
    #$GATE_SCRIPT_DIR/devstack-vm-give.py $NODE_UUID
    exit $RETVAL
fi
