#!/bin/bash

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

PROJECTS="openstack-dev/devstack openstack/nova openstack/glance openstack/keystone openstack/python-novaclient openstack/python-keystoneclient openstack/python-quantumclient openstack/python-glanceclient openstack/python-openstackclient openstack/horizon openstack/tempest openstack/cinder openstack/python-cinderclient openstack/swift openstack/python-swiftclient"

# Set to 1 to run the Tempest test suite
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Set the virtualization driver to: libvirt, openvz
export DEVSTACK_GATE_VIRT_DRIVER=${DEVSTACK_GATE_VIRT_DRIVER:-libvirt}

# See switch below for this -- it gets set to 1 when tempest
# is the project being gated.
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}

# Set this variable to skip updating the devstack-gate project itself.
# Useful in development so you can edit scripts in place and run them
# directly.  Do not set in production.
# Normally not set, and we do include devstack-gate with the rest of
# the projects.
if [ -z "$SKIP_DEVSTACK_GATE_PROJECT" ]; then
    PROJECTS="openstack-ci/devstack-gate $PROJECTS"
fi

export DEST=/opt/stack

# Most of the work of this script is done in functions so that we may
# easily redirect their stdout / stderr to log files.

function setup_workspace {
    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    # HPcloud stopped adding the hostname to /etc/hosts with their
    # precise images.

    HOSTNAME=`/bin/hostname`
    if ! grep $HOSTNAME /etc/hosts >/dev/null
    then
      echo "Need to add hostname to /etc/hosts"
      sudo bash -c 'echo "127.0.1.1 $HOSTNAME" >>/etc/hosts'
    fi

    sudo mkdir -p $DEST
    sudo chown -R jenkins:jenkins $DEST
    cd $DEST

    # The vm template update job should cache the git repos
    # Move them to where we expect:
    if ls ~/workspace-cache/*; then
      mv ~/workspace-cache/* $DEST
    fi

    for PROJECT in $PROJECTS
    do
      echo "Setting up $PROJECT"
      SHORT_PROJECT=`basename $PROJECT`
      if [[ ! -e $SHORT_PROJECT ]]; then
          echo "  Need to clone $SHORT_PROJECT"
          git clone https://review.openstack.org/p/$PROJECT
      fi
      cd $SHORT_PROJECT

      BRANCH=$ZUUL_BRANCH

      # See if this project has this branch, if not, use master
      git remote update || git remote update # attempt to work around bug #925790
      # Ensure that we don't have stale remotes around
      git remote prune origin
      if ! git branch -a |grep remotes/origin/$BRANCH>/dev/null; then
          BRANCH=master
      fi

      # See if Zuul prepared a ref for this project
      if git fetch https://review.openstack.org/p/$PROJECT $ZUUL_REF; then
	  # It's there, so check it out.
	  git checkout FETCH_HEAD
	  git reset --hard FETCH_HEAD
	  git clean -x -f -d -q
      else
	  if [ $PROJECT == $ZUUL_PROJECT ]; then
	      echo "Unable to find ref $ZUUL_REF for $PROJECT"
	      exit 1
	  fi
	  git checkout $BRANCH
	  git reset --hard
	  git clean -x -f -d -q
      fi

      cd $DEST
    done

    # Set GATE_SCRIPT_DIR to point to devstack-gate in the workspace so that
    # we are testing the proposed change from this point forward.
    GATE_SCRIPT_DIR=$DEST/devstack-gate

    # Disable detailed logging as we return to the main script
    set +o xtrace
}

function setup_host {
    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    # Make sure headers for the currently running kernel are installed:
    sudo apt-get install -y --force-yes linux-headers-`uname -r`

    # Hpcloud provides no swap, but does have a partition mounted at /mnt
    # we can use:
    if [ `cat /proc/meminfo | grep SwapTotal | awk '{ print $2; }'` -eq 0 ] && [ -b /dev/vdb ]; then
      sudo umount /dev/vdb
      sudo mkswap /dev/vdb
      sudo swapon /dev/vdb
    fi

    # The vm template update job should cache some images in ~/files.
    # Move them to where devstack expects:
    if ls ~/cache/files/*; then
      mv ~/cache/files/* $DEST/devstack/files
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

    # Create a stack user for devstack to run as, so that we can
    # revoke sudo permissions from that user when appropriate.
    sudo useradd -U -s /bin/bash -d $DEST -m stack
    TEMPFILE=`mktemp`
    echo "stack ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh

    # If we will be testing OpenVZ, make sure stack is a member of the vz group
    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
        sudo usermod -a -G vz stack
    fi

    # Disable detailed logging as we return to the main script
    set +o xtrace
}

function cleanup_host {
    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    cd $WORKSPACE
    # No matter what, archive logs

    sudo cp /var/log/syslog $WORKSPACE/logs/syslog.txt
    sudo cp $DEST/screen-logs/* $WORKSPACE/logs/

    # Make the devstack localrc available with the logs
    sudo cp $DEST/devstack/localrc $WORKSPACE/logs/localrc.txt

    # Make sure jenkins can read all the logs
    sudo chown -R jenkins:jenkins $WORKSPACE/logs/
    sudo chmod a+r $WORKSPACE/logs/

    rename 's/\.log$/.txt/' $WORKSPACE/logs/*

    # Remove duplicate logs
    rm $WORKSPACE/logs/*.*.txt

    # Save the tempest nosetests results
    sudo cp $DEST/tempest/nosetests*.xml $WORKSPACE/
    sudo chown jenkins:jenkins $WORKSPACE/nosetests*.xml
    sudo chmod a+r $WORKSPACE/nosetests*.xml

    # Disable detailed logging as we return to the main script
    set +o xtrace
}

# Make a directory to store logs
mkdir -p logs
rm -f logs/*

setup_workspace &> $WORKSPACE/logs/devstack-gate-setup-workspace.txt

# Also, if we're testing devstack-gate, re-exec this script once so
# that we can test the new version of it.
if [[ $ZUUL_PROJECT == "openstack-ci/devstack-gate" ]] && [[ $RE_EXEC != "true" ]]; then
    export RE_EXEC="true"
    echo "This build includes a change to the devstack gate; re-execing this script."
    exec $GATE_SCRIPT_DIR/devstack-vm-gate-wrap.sh
fi

echo "Triggered by: https://review.openstack.org/$ZUUL_CHANGE patchset $ZUUL_PATCHSET"
echo "Pipeline: $ZUUL_PIPELINE"

setup_host &> $WORKSPACE/logs/devstack-gate-setup-host.txt

# We want to run the full tempest test suite for
# new commits to Tempest, and the smoke test suite
# for commits to the core projects
if [[ $ZUUL_PROJECT == "openstack/tempest" ]]; then
  export DEVSTACK_GATE_TEMPEST_FULL=1
fi

# Run the test
$GATE_SCRIPT_DIR/devstack-vm-gate.sh
RETVAL=$?

cleanup_host &> $WORKSPACE/logs/devstack-gate-cleanup-host.txt

exit $RETVAL
