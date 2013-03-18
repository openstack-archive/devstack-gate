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

PROJECTS="openstack-dev/devstack openstack-dev/grenade openstack/nova openstack/glance openstack/keystone openstack/python-novaclient openstack/python-keystoneclient openstack/python-quantumclient openstack/python-glanceclient openstack/python-openstackclient openstack/horizon openstack/quantum openstack/tempest openstack/cinder openstack/python-cinderclient openstack/swift openstack/python-swiftclient ${PROJECTS}"

# Set to 1 to run the Tempest test suite
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Set to 1 to run postgresql instead of mysql
export DEVSTACK_GATE_POSTGRES=${DEVSTACK_GATE_POSTGRES:-0}

# Set to 1 to run nova coverage with Tempest
export DEVSTACK_GATE_TEMPEST_COVERAGE=${DEVSTACK_GATE_TEMPEST_COVERAGE:-0}

# Set to 1 to run cinder instead of nova volume
# Only applicable to stable/folsom branch
export DEVSTACK_GATE_CINDER=${DEVSTACK_GATE_CINDER:-0}

# Set to 1 to enable Cinder secure delete.
# False by default to avoid dd problems on Precise.
# https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1023755
export DEVSTACK_CINDER_SECURE_DELETE=${DEVSTACK_CINDER_SECURE_DELETE:-0}

# Set to 1 to run quantum instead of nova network
# Only applicable to master branch
export DEVSTACK_GATE_QUANTUM=${DEVSTACK_GATE_QUANTUM:-0}

# Set to the name of the "old" branch to run grenade (eg "stable/folsom")
export DEVSTACK_GATE_GRENADE=${DEVSTACK_GATE_GRENADE:-""}

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
    PROJECTS="openstack-infra/devstack-gate $PROJECTS"
fi

export BASE=/opt/stack

# Most of the work of this script is done in functions so that we may
# easily redirect their stdout / stderr to log files.

function setup_workspace {
    DEST=$1
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

    # Hpcloud provides no swap, but does have a virtual disk mounted
    # at /mnt we can use.  It also doesn't have enough space on / for
    # two devstack installs, so we partition the vdisk:
    if [ `grep SwapTotal /proc/meminfo | awk '{ print $2; }'` -eq 0 ] && \
       [ -b /dev/vdb ]; then
      sudo umount /dev/vdb
      sudo parted /dev/vdb --script -- mklabel msdos
      sudo parted /dev/vdb --script -- mkpart primary linux-swap 0 8192
      sudo parted /dev/vdb --script -- mkpart primary ext2 8192 -1
      sudo mkswap /dev/vdb1
      sudo mkfs.ext4 /dev/vdb2
      sudo swapon /dev/vdb1
      sudo mount /dev/vdb2 /opt
    fi

    sudo mkdir -p $DEST
    sudo chown -R jenkins:jenkins $DEST
    cd $DEST

    # The vm template update job should cache the git repos
    # Move them to where we expect:
    if ls ~/workspace-cache/*; then
      rsync -a ~/workspace-cache/ $DEST/
    fi

    echo "Using branch: $ZUUL_BRANCH"
    for PROJECT in $PROJECTS
    do
      echo "Setting up $PROJECT"
      SHORT_PROJECT=`basename $PROJECT`
      if [[ ! -e $SHORT_PROJECT ]]; then
        echo "  Need to clone $SHORT_PROJECT"
        git clone https://review.openstack.org/p/$PROJECT
      fi
      cd $SHORT_PROJECT

      # TODO: remove; this is temporary to handle some project renames
      git remote set-url origin https://review.openstack.org/p/$PROJECT

      BRANCH=$ZUUL_BRANCH

      MAX_ATTEMPTS=3
      COUNT=0
      # Attempt a git remote update. Run for up to 5 minutes before killing.
      # If first SIGTERM does not kill the process wait a minute then SIGKILL.
      # If update fails try again for up to a total of 3 attempts.
      until timeout -k 1m 5m git remote update
      do
        COUNT=$(($COUNT + 1))
        echo "git remote update failed."
        if [ $COUNT -eq $MAX_ATTEMPTS ]
        then
          exit 1
        fi
        SLEEP_TIME=$((30 + $RANDOM % 60))
        echo "sleep $SLEEP_TIME before retrying."
        sleep $SLEEP_TIME
      done

      # Ensure that we don't have stale remotes around
      git remote prune origin
      # See if this project has this branch, if not, use master
      if ! git branch -a |grep remotes/origin/$BRANCH>/dev/null; then
        BRANCH=master
      fi

      # See if Zuul prepared a ref for this project
      if [ "$ZUUL_REF" != "" ] && \
          git fetch http://zuul.openstack.org/p/$PROJECT $ZUUL_REF; then
        # It's there, so check it out.
        git checkout FETCH_HEAD
        git reset --hard FETCH_HEAD
        git clean -x -f -d -q
      else
        if [ "$PROJECT" == "$ZUUL_PROJECT" ]; then
          echo "Unable to find ref $ZUUL_REF for $PROJECT"
          exit 1
        fi
        git checkout $BRANCH
        git reset --hard remotes/origin/$BRANCH
        git clean -x -f -d -q
      fi

      cd $DEST
    done

    # The vm template update job should cache some images in ~/files.
    # Move them to where devstack expects:
    if [ "$(ls ~/cache/files/* 2>/dev/null)" ]; then
      rsync -a ~/cache/files/ $DEST/devstack/files/
    fi

    # Disable detailed logging as we return to the main script
    set +o xtrace
}

function setup_host {
    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    # Make sure headers for the currently running kernel are installed:
    sudo apt-get install -y --force-yes linux-headers-`uname -r`

    # Move the PIP cache into position:
    sudo mkdir -p /var/cache/pip
    sudo mv ~/cache/pip/* /var/cache/pip

    # Start with a fresh syslog
    sudo stop rsyslog
    sudo mv /var/log/syslog /var/log/syslog-pre-devstack
    sudo mv /var/log/kern.log /var/log/kern_log-pre-devstack
    sudo touch /var/log/syslog
    sudo chown /var/log/syslog --ref /var/log/syslog-pre-devstack
    sudo chmod /var/log/syslog --ref /var/log/syslog-pre-devstack
    sudo chmod a+r /var/log/syslog
    sudo touch /var/log/kern.log
    sudo chown /var/log/kern.log --ref /var/log/kern_log-pre-devstack
    sudo chmod /var/log/kern.log --ref /var/log/kern_log-pre-devstack
    sudo chmod a+r /var/log/kern.log
    sudo start rsyslog

    # Create a stack user for devstack to run as, so that we can
    # revoke sudo permissions from that user when appropriate.
    sudo useradd -U -s /bin/bash -d $BASE/new -m stack
    TEMPFILE=`mktemp`
    echo "stack ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh

    # If we will be testing OpenVZ, make sure stack is a member of the vz group
    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
        sudo usermod -a -G vz stack
    fi

    cat <<EOF > /tmp/pydistutils.cfg
[easy_install]
index_url = http://pypi.openstack.org
EOF
    cat <<EOF > /tmp/pip.conf
[global]
index-url = http://pypi.openstack.org
EOF
    cp /tmp/pydistutils.cfg ~/.pydistutils.cfg
    cp /tmp/pydistutils.cfg ~stack/.pydistutils.cfg
    sudo cp /tmp/pydistutils.cfg ~root/.pydistutils.cfg
    mkdir -p ~/.pip
    mkdir -p ~stack/.pip
    sudo -u root mkdir -p ~root/.pip
    cp /tmp/pip.conf ~/.pip/pip.conf
    cp /tmp/pip.conf ~stack/.pip/pip.conf
    sudo -u root cp /tmp/pip.conf ~root/.pip/pip.conf

    # Disable detailed logging as we return to the main script
    set +o xtrace
}

function cleanup_host {
    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    cd $WORKSPACE
    # No matter what, archive logs

    # Sleep to give services a chance to flush their log buffers.
    sleep 2

    sudo cp /var/log/syslog $WORKSPACE/logs/syslog.txt
    sudo cp /var/log/kern.log $WORKSPACE/logs/kern_log.txt
    mkdir $WORKSPACE/logs/rabbitmq/
    sudo cp /var/log/rabbitmq/* $WORKSPACE/logs/rabbitmq/
    if [ -d /var/log/mysql ] ; then
        mkdir $WORKSPACE/logs/mysql/
        sudo cp /var/log/mysql/* $WORKSPACE/logs/mysql/
    fi
    mkdir $WORKSPACE/logs/sudoers.d/

    sudo cp /etc/sudoers.d/* $WORKSPACE/logs/sudoers.d/
    sudo cp /etc/sudoers $WORKSPACE/logs/sudoers.txt

    if [ -d $BASE/old ]; then
      mkdir -p $WORKSPACE/logs/old/
      mkdir -p $WORKSPACE/logs/new/
      mkdir -p $WORKSPACE/logs/grenade/
      sudo cp $BASE/old/screen-logs/* $WORKSPACE/logs/old/
      sudo cp $BASE/old/devstacklog.txt $WORKSPACE/logs/old/
      sudo cp $BASE/old/devstack/localrc $WORKSPACE/logs/old/localrc.txt
      sudo cp $BASE/logs/* $WORKSPACE/logs/
      sudo cp $BASE/new/grenade/localrc $WORKSPACE/logs/grenade/localrc.txt
      NEWLOGTARGET=$WORKSPACE/logs/new
    else
      NEWLOGTARGET=$WORKSPACE/logs
    fi
    sudo cp $BASE/new/screen-logs/* $NEWLOGTARGET/
    sudo cp $BASE/new/devstacklog.txt $NEWLOGTARGET/
    sudo cp $BASE/new/devstack/localrc $NEWLOGTARGET/localrc.txt

    sudo iptables-save > $WORKSPACE/logs/iptables.txt

    # Make sure jenkins can read all the logs
    sudo chown -R jenkins:jenkins $WORKSPACE/logs/
    sudo chmod a+r $WORKSPACE/logs/

    rename 's/\.log$/.txt/' $WORKSPACE/logs/*
    rename 's/(.*)/$1.txt/' $WORKSPACE/logs/sudoers.d/*
    rename 's/\.log$/.txt/' $WORKSPACE/logs/rabbitmq/*
    mv $WORKSPACE/logs/rabbitmq/startup_log \
       $WORKSPACE/logs/rabbitmq/startup_log.txt

    # Remove duplicate logs
    rm $WORKSPACE/logs/*.*.txt

    # Compress all text logs
    find $WORKSPACE/logs -iname '*.txt' -execdir gzip -9 {} \+
    find $WORKSPACE/logs -iname '*.dat' -execdir gzip -9 {} \+

    # Save the tempest nosetests results
    sudo cp $BASE/new/tempest/nosetests*.xml $WORKSPACE/
    sudo chown jenkins:jenkins $WORKSPACE/nosetests*.xml
    sudo chmod a+r $WORKSPACE/nosetests*.xml
    if [ $DEVSTACK_GATE_TEMPEST_COVERAGE -eq "1" ] ; then
        sudo mkdir $WORKSPACE/logs/coverage-report/
        sudo cp $BASE/new/tempest/coverage-report/* $WORKSPACE/logs/coverage-report/
    fi

    # Disable detailed logging as we return to the main script
    set +o xtrace
}

# Make a directory to store logs
rm -rf logs
mkdir -p logs

setup_workspace $BASE/new &> \
  $WORKSPACE/logs/devstack-gate-setup-workspace-new.txt

# Set GATE_SCRIPT_DIR to point to devstack-gate in the workspace so that
# we are testing the proposed change from this point forward.
GATE_SCRIPT_DIR=$BASE/new/devstack-gate

# Also, if we're testing devstack-gate, re-exec this script once so
# that we can test the new version of it.
if [[ $ZUUL_PROJECT == "openstack-infra/devstack-gate" ]] && [[ $RE_EXEC != "true" ]]; then
    export RE_EXEC="true"
    echo "This build includes a change to the devstack gate; re-execing this script."
    exec $GATE_SCRIPT_DIR/devstack-vm-gate-wrap.sh
fi

if [ "$DEVSTACK_GATE_GRENADE" ]; then
  ORIGBRANCH=$ZUUL_BRANCH
  ZUUL_BRANCH=$DEVSTACK_GATE_GRENADE
  setup_workspace $BASE/old &> \
    $WORKSPACE/logs/devstack-gate-setup-workspace-old.txt
  ZUUL_BRANCH=$ORIGBRANCH
fi

echo "Triggered by: https://review.openstack.org/$ZUUL_CHANGE patchset $ZUUL_PATCHSET"
echo "Pipeline: $ZUUL_PIPELINE"

setup_host &> $WORKSPACE/logs/devstack-gate-setup-host.txt

# Run the test
$GATE_SCRIPT_DIR/devstack-vm-gate.sh
RETVAL=$?

cleanup_host &> $WORKSPACE/logs/devstack-gate-cleanup-host.txt

exit $RETVAL
