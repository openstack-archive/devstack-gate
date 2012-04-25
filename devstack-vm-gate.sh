#!/bin/bash -x

# Gate commits to several projects on a VM running those projects
# configured by devstack.

# Copyright (C) 2011-2012 OpenStack LLC.
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

PROJECTS="openstack-dev/devstack openstack/nova openstack/glance openstack/keystone openstack/python-novaclient openstack/python-keystoneclient openstack/python-quantumclient openstack/python-glanceclient openstack/horizon openstack/tempest"

# Set to 1 to run the Tempest test suite
DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Supply specific tests to Tempest in second argument
# For example, to execute only the server actions test,
# you would supply tempest.test.test_server_actions
DEVSTACK_GATE_TEMPEST_TESTS=${DEVSTACK_GATE_TEMPEST_TESTS:-tempest}

# Set this variable to skip updating the devstack-gate project itself.
# Useful in development so you can edit scripts in place and run them
# directly.  Do not set in production.
# Normally not set, and we do include devstack-gate with the rest of
# the projects.
if [ -z "$SKIP_DEVSTACK_GATE_PROJECT" ]; then
    PROJECTS="openstack-ci/devstack-gate $PROJECTS"
fi

# Set this variable to include tempest in the test run.
if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    PROJECTS="openstack/tempest $PROJECTS"
fi

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

$GATE_SCRIPT_DIR/devstack-vm-fetch.py oneiric > node_info.sh || exit $?
. node_info.sh

scp -C $GATE_SCRIPT_DIR/devstack-vm-gate-host.sh $NODE_IP_ADDR:
RETVAL=$?
if [ $RETVAL != 0 ]; then
    echo "Recording node run as failure."
    if [ -n "$RESULT_ID" ]; then
	$GATE_SCRIPT_DIR/devstack-vm-result.py $RESULT_ID failure
    fi
    echo "Deleting host"
    $GATE_SCRIPT_DIR/devstack-vm-delete.py $NODE_ID
    exit $RETVAL
fi

rsync -az --delete $WORKSPACE/ $NODE_IP_ADDR:workspace/
RETVAL=$?
if [ $RETVAL != 0 ]; then
    echo "Recording node run as failure."
    if [ -n "$RESULT_ID" ]; then
	$GATE_SCRIPT_DIR/devstack-vm-result.py $RESULT_ID failure
    fi
    echo "Deleting host"
    $GATE_SCRIPT_DIR/devstack-vm-delete.py $NODE_ID
    exit $RETVAL
fi

ssh $NODE_IP_ADDR ./devstack-vm-gate-host.sh $DEVSTACK_GATE_TEMPEST $DEVSTACK_GATE_TEMPEST_TESTS
RETVAL=$?
# No matter what, archive logs
scp -C -q $NODE_IP_ADDR:/var/log/syslog $WORKSPACE/logs/syslog.txt
scp -C -q $NODE_IP_ADDR:/opt/stack/screen-logs/* $WORKSPACE/logs/
rename 's/\.log$/.txt/' $WORKSPACE/logs/*
# Remove duplicate logs
rm $WORKSPACE/logs/*.*.txt
# Copy XUnit test results from tempest, if run.
if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
  scp -C -q $NODE_IP_ADDR:/opt/stack/tempest/nosetests.xml $WORKSPACE/tempest/
fi

# Now check whether the run was a success
if [ -n "$RESULT_ID" ]; then
    if [ $RETVAL = 0 ]; then
	echo "Recording node run as success."
        $GATE_SCRIPT_DIR/devstack-vm-result.py $RESULT_ID success
    else
	echo "Recording node run as failure."
	$GATE_SCRIPT_DIR/devstack-vm-result.py $RESULT_ID failure
    fi
fi

if [ $RETVAL = 0 ] && [ $ALWAYS_KEEP = 0 ]; then
    echo "Deleting host"
    $GATE_SCRIPT_DIR/devstack-vm-delete.py $NODE_ID
    exit $RETVAL
else
    #echo "Giving host to developer"
    #$GATE_SCRIPT_DIR/devstack-vm-give.py $NODE_ID
    exit $RETVAL
fi
