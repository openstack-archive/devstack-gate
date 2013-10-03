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

# Most of the work of this script is done in functions so that we may
# easily redirect their stdout / stderr to log files.

function function_exists {
    type $1 2>/dev/null | grep -q 'is a function'
}

function setup_workspace {
    DEST=$1
    CHECKOUT_ZUUL=$2

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
        git clone https://git.openstack.org/$PROJECT
      fi
      cd $SHORT_PROJECT

      git remote set-url origin https://git.openstack.org/$PROJECT

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

      # See if we should check out a Zuul ref
      if [ $CHECKOUT_ZUUL -eq "1" ]; then
          # See if Zuul prepared a ref for this project
          if [ "$ZUUL_REF" != "" ] && \
              git fetch $ZUUL_URL/$PROJECT $ZUUL_REF; then
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
      else
          # We're ignoring Zuul refs
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
index_url = http://pypi.openstack.org/openstack
EOF
    cat <<EOF > /tmp/pip.conf
[global]
index-url = http://pypi.openstack.org/openstack
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
        sudo cp -a /var/log/mysql $WORKSPACE/logs/
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

    pip freeze > $WORKSPACE/logs/pip-freeze.txt

    # Process testr artifacts.
    if [ -f $BASE/new/tempest/.testrepository/0 ]; then
        sudo cp $BASE/new/tempest/.testrepository/0 $WORKSPACE/subunit_log.txt
        sudo python /usr/local/jenkins/slave_scripts/subunit2html.py $WORKSPACE/subunit_log.txt $WORKSPACE/testr_results.html
        sudo gzip -9 $WORKSPACE/subunit_log.txt
        sudo gzip -9 $WORKSPACE/testr_results.html
        sudo chown jenkins:jenkins $WORKSPACE/subunit_log.txt.gz $WORKSPACE/testr_results.html.gz
        sudo chmod a+r $WORKSPACE/subunit_log.txt.gz $WORKSPACE/testr_results.html.gz
    fi

    if [ -f $BASE/new/tempest/tempest.log ] ; then
        sudo cp $BASE/new/tempest/tempest.log $WORKSPACE/logs/tempest.log
    fi

    # Make sure jenkins can read all the logs
    sudo chown -R jenkins:jenkins $WORKSPACE/logs/
    sudo chmod a+r $WORKSPACE/logs/

    rename 's/\.log$/.txt/' $WORKSPACE/logs/*
    rename 's/(.*)/$1.txt/' $WORKSPACE/logs/sudoers.d/*
    rename 's/\.log$/.txt/' $WORKSPACE/logs/rabbitmq/*
    if [ -d $WORKSPACE/logs/mysql ]; then
        rename 's/\.log$/.txt/' $WORKSPACE/logs/mysql/*
    fi

    mv $WORKSPACE/logs/rabbitmq/startup_log \
       $WORKSPACE/logs/rabbitmq/startup_log.txt

    # Remove duplicate logs
    rm $WORKSPACE/logs/*.*.txt

    if [ -d $BASE/old ]; then
        rename 's/\.log$/.txt/' $WORKSPACE/logs/old/*
        rename 's/\.log$/.txt/' $WORKSPACE/logs/new/*
        rename 's/\.log$/.txt/' $WORKSPACE/logs/grenade/*
        rm $WORKSPACE/logs/old/*.*.txt
        rm $WORKSPACE/logs/new/*.*.txt
    fi

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

PROJECTS="openstack-dev/devstack $PROJECTS"
PROJECTS="openstack-dev/grenade $PROJECTS"
PROJECTS="openstack-dev/pbr $PROJECTS"
PROJECTS="openstack-infra/jeepyb $PROJECTS"
PROJECTS="openstack-infra/pypi-mirror $PROJECTS"
PROJECTS="openstack/ceilometer $PROJECTS"
PROJECTS="openstack/cinder $PROJECTS"
PROJECTS="openstack/glance $PROJECTS"
PROJECTS="openstack/heat $PROJECTS"
PROJECTS="openstack/horizon $PROJECTS"
PROJECTS="openstack/keystone $PROJECTS"
PROJECTS="openstack/neutron $PROJECTS"
PROJECTS="openstack/nova $PROJECTS"
PROJECTS="openstack/oslo.config $PROJECTS"
PROJECTS="openstack/oslo.messaging $PROJECTS"
PROJECTS="openstack/python-ceilometerclient $PROJECTS"
PROJECTS="openstack/python-cinderclient $PROJECTS"
PROJECTS="openstack/python-glanceclient $PROJECTS"
PROJECTS="openstack/python-heatclient $PROJECTS"
PROJECTS="openstack/python-keystoneclient $PROJECTS"
PROJECTS="openstack/python-neutronclient $PROJECTS"
PROJECTS="openstack/python-novaclient $PROJECTS"
PROJECTS="openstack/python-openstackclient $PROJECTS"
PROJECTS="openstack/python-swiftclient $PROJECTS"
PROJECTS="openstack/requirements $PROJECTS"
PROJECTS="openstack/swift $PROJECTS"
PROJECTS="openstack/tempest $PROJECTS"
PROJECTS="openstack/oslo.config $PROJECTS"
PROJECTS="openstack/oslo.messaging $PROJECTS"

# Set this variable to skip updating the devstack-gate project itself.
# Useful in development so you can edit scripts in place and run them
# directly.  Do not set in production.
# Normally not set, and we do include devstack-gate with the rest of
# the projects.
if [ -z "$SKIP_DEVSTACK_GATE_PROJECT" ]; then
    PROJECTS="openstack-infra/devstack-gate $PROJECTS"
fi

export BASE=/opt/stack

# Set GATE_SCRIPT_DIR to point to devstack-gate in the workspace so that
# we are testing the proposed change from this point forward.
GATE_SCRIPT_DIR=$BASE/new/devstack-gate

# The URL from which to fetch ZUUL references
export ZUUL_URL=${ZUUL_URL:-http://zuul.openstack.org/p}

# Make a directory to store logs
rm -rf logs
mkdir -p logs

setup_workspace $BASE/new 1 &> \
  $WORKSPACE/logs/devstack-gate-setup-workspace-new.txt

# Also, if we're testing devstack-gate, re-exec this script once so
# that we can test the new version of it.
if [[ $ZUUL_CHANGES =~ "openstack-infra/devstack-gate" ]] && [[ $RE_EXEC != "true" ]]; then
    export RE_EXEC="true"
    echo "This build includes a change to the devstack gate; re-execing this script."
    exec $GATE_SCRIPT_DIR/devstack-vm-gate-wrap.sh
fi

# Set to 1 to run the Tempest test suite
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Set to 1 to run the devstack exercises
export DEVSTACK_GATE_EXERCISES=${DEVSTACK_GATE_EXERCISES:-0}

# Set to 1 to run postgresql instead of mysql
export DEVSTACK_GATE_POSTGRES=${DEVSTACK_GATE_POSTGRES:-0}

# Set to 1 to use zeromq instead of rabbitmq (or qpid)
export DEVSTACK_GATE_ZEROMQ=${DEVSTACK_GATE_ZEROMQ:-0}

# Set to 1 to run nova coverage with Tempest
export DEVSTACK_GATE_TEMPEST_COVERAGE=${DEVSTACK_GATE_TEMPEST_COVERAGE:-0}

# Set to 1 to run tempest stress tests
export DEVSTACK_GATE_TEMPEST_STRESS=${DEVSTACK_GATE_TEMPEST_STRESS:-0}

# Set to 1 to run tempest heat slow tests
export DEVSTACK_GATE_TEMPEST_HEAT_SLOW=${DEVSTACK_GATE_TEMPEST_HEAT_SLOW:-0}

# Set to 1 to run tempest large ops test
export DEVSTACK_GATE_TEMPEST_LARGE_OPS=${DEVSTACK_GATE_TEMPEST_LARGE_OPS:-0}

# Set to 1 to explicitly enable tempest tenant isolation. Otherwise tenant isolation setting
# for tempest will be the one chosen by devstack.
export DEVSTACK_GATE_TEMPEST_ALLOW_TENANT_ISOLATION=${DEVSTACK_GATE_TEMPEST_ALLOW_TENANT_ISOLATION:-0}

export DEVSTACK_GATE_CINDER=${DEVSTACK_GATE_CINDER:-0}

# Set to 1 to enable Cinder secure delete.
# False by default to avoid dd problems on Precise.
# https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1023755
export DEVSTACK_CINDER_SECURE_DELETE=${DEVSTACK_CINDER_SECURE_DELETE:-0}

# Set to 1 to run neutron instead of nova network
# Only applicable to master branch
export DEVSTACK_GATE_NEUTRON=${DEVSTACK_GATE_NEUTRON:-0}

# Set to 1 to run nova in cells mode instead of the default mode
export DEVSTACK_GATE_CELLS=${DEVSTACK_GATE_CELLS:-0}

# Set to 1 to run grenade.
export DEVSTACK_GATE_GRENADE=${DEVSTACK_GATE_GRENADE:-0}

if [ "$DEVSTACK_GATE_GRENADE" -eq "1" ]; then
    export DEVSTACK_GATE_EXERCISES=1
    if [ "$ZUUL_BRANCH" == "stable/grizzly" ]; then
# Set to 1 to run cinder instead of nova volume
# Only applicable to stable/folsom branch
        export GRENADE_OLD_BRANCH="stable/folsom"
        export DEVSTACK_GATE_CINDER=1
    elif [ "$ZUUL_BRANCH" == "stable/havana" ]; then
        export GRENADE_OLD_BRANCH="stable/grizzly"
        export DEVSTACK_GATE_CINDER=1
        export DEVSTACK_GATE_TEMPEST=1
    else # master
        export GRENADE_OLD_BRANCH="stable/grizzly"
        export DEVSTACK_GATE_CINDER=1
        export DEVSTACK_GATE_TEMPEST=1
    fi
fi

if [ "$ZUUL_BRANCH" = "stable/grizzly" -o "$ZUUL_BRANCH" = "stable/folsom" ]; then
    export DEVSTACK_GATE_EXERCISES=1
fi

# Set the virtualization driver to: libvirt, openvz
export DEVSTACK_GATE_VIRT_DRIVER=${DEVSTACK_GATE_VIRT_DRIVER:-libvirt}

# See switch below for this -- it gets set to 1 when tempest
# is the project being gated.
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}

# Set to enable running full tempest with testr:
export DEVSTACK_GATE_TEMPEST_TESTR_FULL=${DEVSTACK_GATE_TEMPEST_TESTR_FULL:-0}

# Set to 1 to run all tempest tests
export DEVSTACK_GATE_TEMPEST_ALL=${DEVSTACK_GATE_TEMPEST_ALL:-0}

if ! function_exists "gate_hook"; then
  # the command we use to run the gate
  function gate_hook {
    $GATE_SCRIPT_DIR/devstack-vm-gate.sh
  }
fi

if [ "$DEVSTACK_GATE_GRENADE" -eq "1" ]; then
  ORIGBRANCH=$ZUUL_BRANCH
  ZUUL_BRANCH=$GRENADE_OLD_BRANCH
  setup_workspace $BASE/old 0 &> \
    $WORKSPACE/logs/devstack-gate-setup-workspace-old.txt
  ZUUL_BRANCH=$ORIGBRANCH
fi

echo "Triggered by: https://review.openstack.org/$ZUUL_CHANGE patchset $ZUUL_PATCHSET"
echo "Pipeline: $ZUUL_PIPELINE"
echo "IP configuration of this host:"
ip -f inet addr show

setup_host &> $WORKSPACE/logs/devstack-gate-setup-host.txt

# Run pre test hook if we have one
if function_exists "pre_test_hook"; then
  set -o xtrace
  pre_test_hook 2>&1 | tee $WORKSPACE/logs/devstack-gate-pre-test-hook.txt
  set +o xtrace
fi

# Run the gate function
gate_hook
RETVAL=$?

# Run post test hook if we have one
if [ $RETVAL -eq 0 ] && function_exists "post_test_hook"; then
  set -o xtrace -o pipefail
  post_test_hook 2>&1 | tee $WORKSPACE/logs/devstack-gate-post-test-hook.txt
  RETVAL=$?
  set +o xtrace +o pipefail
fi

cleanup_host &> $WORKSPACE/logs/devstack-gate-cleanup-host.txt

exit $RETVAL
