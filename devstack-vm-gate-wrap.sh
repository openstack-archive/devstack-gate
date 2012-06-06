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
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Supply specific tests to Tempest in second argument
# For example, to execute only the server actions test,
# you would supply tempest.test.test_server_actions
export DEVSTACK_GATE_TEMPEST_TESTS=${DEVSTACK_GATE_TEMPEST_TESTS:-tempest}

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

cd $WORKSPACE

if [[ -e ~/workspace-cache/nova ]]; then
    mv ~/workspace-cache/* $WORKSPACE/
fi

ORIGINAL_GERRIT_PROJECT=GERRIT_PROJECT
ORIGINAL_GERRIT_BRANCH=GERRIT_BRANCH

for GERRIT_PROJECT in $PROJECTS
do
    echo "Setting up $GERRIT_PROJECT"
    SHORT_PROJECT=`basename $GERRIT_PROJECT`
    if [[ ! -e $SHORT_PROJECT ]]; then
	echo "  Need to clone"
	git clone https://review.openstack.org/p/$GERRIT_PROJECT
    fi
    cd $SHORT_PROJECT
    
    GERRIT_BRANCH=$ORIGINAL_GERRIT_BRANCH

    # See if this project has this branch, if not, use master
    git remote update || git remote update # attempt to work around bug #925790
    # Ensure that we don't have stale remotes around
    git remote prune origin
    if ! git branch -a |grep remotes/origin/$GERRIT_BRANCH>/dev/null; then
	GERRIT_BRANCH=master
    fi
    
    export GERRIT_BRANCH
    export GERRIT_PROJECT
    /usr/local/jenkins/slave_scripts/gerrit-git-prep.sh review.openstack.org

    cd $WORKSPACE
done

GERRIT_PROJECT=$ORIGINAL_GERRIT_PROJECT
GERRIT_BRANCH=$ORIGINAL_GERRIT_BRANCH

# Set GATE_SCRIPT_DIR to point to devstack-gate in the workspace so that
# we are testing the proposed change from this point forward.
GATE_SCRIPT_DIR=$WORKSPACE/devstack-gate

# Also, if we're testing devstack-gate, re-exec this script once so
# that we can test the new version of it.
if [[ $GERRIT_PROJECT == "openstack-ci/devstack-gate" ]] && [[ $RE_EXEC != "true" ]]; then
    export RE_EXEC="true"
    exec $GATE_SCRIPT_DIR/devstack-vm-gate-wrap.sh
fi

# Make sure headers for the currently running kernel are installed:
sudo apt-get install -y --force-yes linux-headers-`uname -r`

# Hpcloud provides no swap, but does have a partition mounted at /mnt 
# we can use:
if [ `cat /proc/meminfo | grep SwapTotal | awk '{ print $2; }'` -eq 0 ] &&
   [ -b /dev/vdb ]; then
    sudo umount /dev/vdb
    sudo mkswap /dev/vdb
    sudo swapon /dev/vdb
fi

# The vm template update job should cache some images in ~/files.
# Move them to where devstack expects:
if ls ~/cache/files/*; then
    mv ~/cache/files/* $WORKSPACE/devstack/files
fi

# Move the PIP cache into position:
sudo mkdir -p /var/cache/pip
sudo mv ~/cache/pip/* /var/cache/pip

# Start with a fresh syslog
sudo stop rsyslog
sudo mv /var/log/syslog /var/log/syslog-pre-devstack
sudo touch /var/log/syslog
sudo chown /var/log/syslog --ref /var/log/syslog-pre-devstack
sudo chmod /var/log/syslog --ref /var/log/syslog-pre-devstack
sudo chmod a+r /var/log/syslog
sudo start rsyslog

# Run the test
$GATE_SCRIPT_DIR/devstack-vm-gate.sh
RETVAL=$?

cd $WORKSPACE
# No matter what, archive logs
mkdir -p logs
rm -f logs/*

sudo cp /var/log/syslog $WORKSPACE/logs/syslog.txt
cp $WORKSPACE/screen-logs/* $WORKSPACE/logs/

# Make sure jenkins can read all the logs
sudo chown -R jenkins.jenkins $WORKSPACE/logs/
sudo chmod a+r $WORKSPACE/logs/

rename 's/\.log$/.txt/' $WORKSPACE/logs/*

# Remove duplicate logs
rm $WORKSPACE/logs/*.*.txt

exit $RETVAL
