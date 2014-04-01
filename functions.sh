#!/bin/bash

# Copyright (C) 2011-2013 OpenStack Foundation
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

function function_exists {
    type $1 2>/dev/null | grep -q 'is a function'
}

# awk filter to timestamp the stream, including stderr merging
function tsfilter {
    $@ 2>&1 | awk '
    {
        cmd ="date +\"%Y-%m-%d %H:%M:%S.%3N | \""
        cmd | getline now
        close("date +\"%Y-%m-%d %H:%M:%S.%3N | \"")
        sub(/^/, now)
        print
        fflush()
    }'
}

# create the start timer for when the job began
function start_timer {
    START_TIME=`date +%s`
}

function remaining_time {
    local now=`date +%s`
    local elapsed=$(((now - START_TIME) / 60))
    REMAINING_TIME=$((DEVSTACK_GATE_TIMEOUT - elapsed - 5))
    echo "Job timeout set to: $REMAINING_TIME minutes"
}

# indent the output of a command 4 spaces, useful for distinguishing
# the output of a command from the command itself
function indent {
    $@ | (while read; do echo "    $REPLY"; done)
}

# Attempt to fetch a git ref for a project, if that ref is not empty
function git_fetch_at_ref {
    local project=$1
    local ref=$2
    if [ "$ref" != "" ]; then
        git fetch $ZUUL_URL/$project $ref
        return $?
    else
        # return failing
        return 1
    fi
}

function git_checkout {
    local project=$1
    local branch=$2
    local reset_branch=$branch

    if [[ "$branch" != "FETCH_HEAD" ]]; then
        reset_branch="remotes/origin/$branch"
    fi

    git checkout $branch
    git reset --hard $reset_branch
    if ! git clean -x -f -d -q ; then
        sleep 1
        git clean -x -f -d -q
    fi
}

function git_has_branch {
    local project=$1 # Project is here for test mocks
    local branch=$2

    if git branch -a |grep remotes/origin/$branch>/dev/null; then
        return 0
    else
        return 1
    fi
}

function git_prune {
    git remote prune origin
}

function git_remote_update {
    # Attempt a git remote update. Run for up to 5 minutes before killing.
    # If first SIGTERM does not kill the process wait a minute then SIGKILL.
    # If update fails try again for up to a total of 3 attempts.
    MAX_ATTEMPTS=3
    COUNT=0
    until timeout -k 1m 5m git remote update; do
        COUNT=$(($COUNT + 1))
        echo "git remote update failed."
        if [ $COUNT -eq $MAX_ATTEMPTS ]; then
            exit 1
        fi
        SLEEP_TIME=$((30 + $RANDOM % 60))
        echo "sleep $SLEEP_TIME before retrying."
        sleep $SLEEP_TIME
    done
}

function git_remote_set_url {
    git remote set-url $1 $2
}

function git_clone_and_cd {
    local project=$1
    local short_project=$2

    if [[ ! -e $short_project ]]; then
        echo "  Need to clone $short_project"
        git clone https://git.openstack.org/$project
    fi
    cd $short_project
}

function fix_etc_hosts {
    # HPcloud stopped adding the hostname to /etc/hosts with their
    # precise images.

    HOSTNAME=`/bin/hostname`
    if ! grep $HOSTNAME /etc/hosts >/dev/null; then
        echo "Need to add hostname to /etc/hosts"
        sudo bash -c 'echo "127.0.1.1 $HOSTNAME" >>/etc/hosts'
    fi

}

function fix_disk_layout {
    # HPCloud and Rackspace performance nodes provide no swap, but do
    # have ephemeral disks we can use.  HPCloud also doesn't have
    # enough space on / for two devstack installs, so we partition the
    # disk and mount it on /opt, syncing the previous contents of /opt
    # over.
    if [ `grep SwapTotal /proc/meminfo | awk '{ print $2; }'` -eq 0 ]; then
        if [ -b /dev/vdb ]; then
            DEV='/dev/vdb'
        elif [ -b /dev/xvde ]; then
            DEV='/dev/xvde'
        fi
        if [ -n "$DEV" ]; then
            sudo umount ${DEV}
            sudo parted ${DEV} --script -- mklabel msdos
            sudo parted ${DEV} --script -- mkpart primary linux-swap 1 8192
            sudo parted ${DEV} --script -- mkpart primary ext2 8192 -1
            sudo mkswap ${DEV}1
            sudo mkfs.ext4 ${DEV}2
            sudo swapon ${DEV}1
            sudo mount ${DEV}2 /mnt
            sudo find /opt/ -mindepth 1 -maxdepth 1 -exec mv {} /mnt/ \;
            sudo umount /mnt
            sudo mount ${DEV}2 /opt
        fi
    fi
}

# Set up a project in accordance with the future state proposed by
# Zuul.
#
# Arguments:
#   project: The full name of the project to set up
#   branch: The branch to check out
#
# The branch argument should be the desired branch to check out.  If
# you have no other opinions, then you should supply ZUUL_BRANCH here.
# This is generally the branch corresponding with the change being
# tested.
#
# If you would like to check out a branch other than what ZUUL has
# selected, for example in order to check out the old or new branches
# for grenade, or an alternate branch to test client library
# compatibility, then supply that as the argument instead.  This
# function will try to check out the following (in order):
#
#   The zuul ref for the indicated branch
#   The zuul ref for the master branch
#   The tip of the indicated branch
#   The tip of the master branch
#
function setup_project {
    local project=$1
    local branch=$2
    local short_project=`basename $project`

    echo "Setting up $project @ $branch"
    git_clone_and_cd $project $short_project

    git_remote_set_url origin https://git.openstack.org/$project

    # Try the specified branch before the ZUUL_BRANCH.
    OVERRIDE_ZUUL_REF=$(echo $ZUUL_REF | sed -e "s,$ZUUL_BRANCH,$branch,")

    # Update git remotes
    git_remote_update
    # Ensure that we don't have stale remotes around
    git_prune
    # See if this project has this branch, if not, use master
    FALLBACK_ZUUL_REF=""
    if ! git_has_branch $project $branch; then
        FALLBACK_ZUUL_REF=$(echo $ZUUL_REF | sed -e "s,$branch,master,")
    fi

    # See if Zuul prepared a ref for this project
    if git_fetch_at_ref $project $OVERRIDE_ZUUL_REF || \
        git_fetch_at_ref $project $FALLBACK_ZUUL_REF; then

        # It's there, so check it out.
        git_checkout $project FETCH_HEAD
    else
        if git_has_branch $project $branch; then
            git_checkout $project $branch
        else
            git_checkout $project master
        fi
    fi
}

function re_exec_devstack_gate {
    export RE_EXEC="true"
    echo "This build includes a change to devstack-gate; re-execing this script."
    exec $WORKSPACE/devstack-gate/devstack-vm-gate-wrap.sh
}

function setup_workspace {
    local base_branch=$1
    local DEST=$2
    local xtrace=$(set +o | grep xtrace)

    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    fix_disk_layout

    sudo mkdir -p $DEST
    sudo chown -R jenkins:jenkins $DEST

    #TODO(jeblair): remove when this is no longer created by the image
    rm -fr ~/workspace-cache/

    # The vm template update job should cache the git repos
    # Move them to where we expect:
    echo "Using branch: $base_branch"
    for PROJECT in $PROJECTS; do
        cd $DEST
        if [ -d /opt/git/$PROJECT ]; then
            # Start with a cached git repo if possible
            rsync -a /opt/git/${PROJECT}/ `basename $PROJECT`
        fi
        setup_project $PROJECT $base_branch
    done
    # It's important we are back at DEST for the rest of the script
    cd $DEST

    # The vm template update job should cache some images in ~/cache.
    # Move them to where devstack expects:
    find ~/cache/files/ -mindepth 1 -maxdepth 1 -exec mv {} $DEST/devstack/files/ \;

    # Disable detailed logging as we return to the main script
    $xtrace
}

function select_mirror {

    if [ "$DEVSTACK_GATE_REQS_INTEGRATION" -eq "0" ]; then

        ORG=$(dirname $ZUUL_PROJECT)
        SHORT_PROJECT=$(basename $ZUUL_PROJECT)
        $DEVSTACK_GATE_SELECT_MIRROR $ORG $SHORT_PROJECT

        sudo cp ~/.pydistutils.cfg ~root/.pydistutils.cfg
        sudo cp ~/.pydistutils.cfg ~stack/.pydistutils.cfg
        sudo chown stack:stack ~stack/.pydistutils.cfg
        sudo cp ~/.pydistutils.cfg ~tempest/.pydistutils.cfg
        sudo chown tempest:tempest ~tempest/.pydistutils.cfg

        sudo -u stack mkdir -p ~stack/.pip
        sudo -u root mkdir -p ~root/.pip
        sudo -u tempest mkdir -p ~tempest/.pip

        sudo -u root cp ~/.pip/pip.conf ~root/.pip/pip.conf
        sudo cp ~/.pip/pip.conf ~stack/.pip/pip.conf
        sudo chown stack:stack ~stack/.pip/pip.conf
        sudo cp ~/.pip/pip.conf ~tempest/.pip/pip.conf
        sudo chown tempest:tempest ~tempest/.pip/pip.conf
    fi
}

function enable_latest_libvirt {
    sudo apt-get update

    # Log the libvirtd info before we start
    date
    /usr/sbin/libvirtd --version
    ls -altr /usr/sbin/libvirtd

    # Upgrade just a few things we need
    sudo apt-get --force-yes -y install libvirt-bin python-libvirt

    # Stop the one that is running
    sudo service libvirt-bin stop

    # Fetch and install libvirt-0.9.8-2ubuntu18 our internal site. original binaries are from
    # @hallyn's site - http://people.canonical.com/~serge/libvirt-0.9.8-2ubuntu18/
    pushd /tmp
    REMOTE_URL=http://b64a126b01b637c4fdf4-11809a5fee9c1af804008df022f3a2d9.r93.cf2.rackcdn.com/
    wget $REMOTE_URL/libvirt-bin_0.9.8-2ubuntu17.18_amd64.deb
    wget $REMOTE_URL/libvirt0_0.9.8-2ubuntu17.18_amd64.deb
    wget $REMOTE_URL/python-libvirt_0.9.8-2ubuntu17.18_amd64.deb
    sudo dpkg -i *libvirt*.deb
    rm *libvirt*.deb
    popd

    # clean up old logs
    sudo rm /var/log/libvirt/libvirtd*.log

    # Log version/date etc of what we ended with
    date
    /usr/sbin/libvirtd --version
    ls -altr /usr/sbin/libvirtd

    # Start the one that we installed
    sudo service libvirt-bin start
}

function setup_host {
    # Enabled detailed logging, since output of this function is redirected
    local xtrace=$(set +o | grep xtrace)
    set -o xtrace

    # This is necessary to keep sudo from complaining
    fix_etc_hosts

    # Detect OS type
    # Ubuntu has an lsb_release command which allows us to detect if it is Ubuntu
    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "libvirt" ]; then
        if lsb_release -i 2>/dev/null | grep -iq ubuntu
        then
            # Temporary work around to install a patched libvirt 0.9.8+
            enable_latest_libvirt
        fi
    fi

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

    # We set some home directories under $BASE, make sure it exists.
    sudo mkdir -p $BASE
    # Create a stack user for devstack to run as, so that we can
    # revoke sudo permissions from that user when appropriate.
    sudo useradd -U -s /bin/bash -d $BASE/new -m stack
    TEMPFILE=`mktemp`
    echo "stack ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh

    # Create a tempest user for tempest to run as, so that we can
    # revoke sudo permissions from that user when appropriate.
    # NOTE(sdague): we should try to get the state dump to be a
    # neutron API call in Icehouse to remove this.
    sudo useradd -U -s /bin/bash -m tempest
    TEMPFILE=`mktemp`
    echo "tempest ALL=(root) NOPASSWD:/sbin/ip" >$TEMPFILE
    echo "tempest ALL=(root) NOPASSWD:/sbin/iptables" >>$TEMPFILE
    echo "tempest ALL=(root) NOPASSWD:/usr/bin/ovsdb-client" >>$TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/51_tempest_sh

    # Future useradd calls should strongly consider also updating
    # ~/.pip/pip.conf and ~/.pydisutils.cfg in the select_mirror function if
    # tox/pip will be used at all.

    # If we will be testing OpenVZ, make sure stack is a member of the vz group
    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
        sudo usermod -a -G vz stack
    fi

    if [ -f $DEVSTACK_GATE_SELECT_MIRROR ] ; then
        select_mirror
    fi
    # Disable detailed logging as we return to the main script
    $xtrace
}

function cleanup_host {
    # Enabled detailed logging, since output of this function is redirected
    local xtrace=$(set +o | grep xtrace)
    set -o xtrace

    cd $WORKSPACE
    # No matter what, archive logs and config files

    # Sleep to give services a chance to flush their log buffers.
    sleep 2

    sudo cp /var/log/syslog $BASE/logs/syslog.txt
    sudo cp /var/log/kern.log $BASE/logs/kern_log.txt
    sudo cp /var/log/apache2/horizon_error.log $BASE/logs/horizon_error.log
    sudo mkdir $BASE/logs/rabbitmq/
    sudo cp /var/log/rabbitmq/* $BASE/logs/rabbitmq/
    if [ -d /var/log/libvirt ] ; then
        sudo cp /var/log/libvirt/libvirtd*.log $BASE/logs/
    fi
    sudo mkdir $BASE/logs/sudoers.d/

    sudo cp /etc/sudoers.d/* $BASE/logs/sudoers.d/
    sudo cp /etc/sudoers $BASE/logs/sudoers.txt

    # Archive config files
    sudo mkdir $BASE/logs/etc/
    for PROJECT in $PROJECTS; do
        proj=`basename $PROJECT`
        if [ -d /etc/$proj ]; then
            sudo cp -r /etc/$proj $BASE/logs/etc/
        fi
    done

    if [ -d $BASE/old ]; then
      sudo mkdir -p $BASE/logs/old $BASE/logs/new $BASE/logs/grenade
      sudo cp $BASE/old/screen-logs/* $BASE/logs/old/
      sudo cp $BASE/old/devstacklog.txt $BASE/logs/old/
      sudo cp $BASE/old/devstack/localrc $BASE/logs/old/localrc.txt
      sudo cp $BASE/old/tempest/etc/tempest.conf $BASE/logs/old/tempest_conf.txt
      sudo cp $BASE/new/grenade/localrc $BASE/logs/grenade/localrc.txt
      NEWLOGTARGET=$BASE/logs/new
    else
      NEWLOGTARGET=$BASE/logs
    fi
    sudo cp $BASE/new/screen-logs/* $NEWLOGTARGET/
    sudo cp $BASE/new/devstacklog.txt $NEWLOGTARGET/
    sudo cp $BASE/new/devstack/localrc $NEWLOGTARGET/localrc.txt

    # Copy tempest config file
    sudo cp $BASE/new/tempest/etc/tempest.conf $NEWLOGTARGET/tempest_conf.txt

    sudo iptables-save > $WORKSPACE/iptables.txt
    df -h > $WORKSPACE/df.txt
    pip freeze > $WORKSPACE/pip-freeze.txt
    sudo mv $WORKSPACE/iptables.txt $WORKSPACE/df.txt \
        $WORKSPACE/pip-freeze.txt $BASE/logs/

    if [ `command -v dpkg` ]; then
      dpkg -l> $WORKSPACE/dpkg-l.txt
      gzip -9 dpkg-l.txt
      sudo mv $WORKSPACE/dpkg-l.txt.gz $BASE/logs/
    fi
    if [ `command -v rpm` ]; then
      rpm -qa > $WORKSPACE/rpm-qa.txt
      gzip -9 rpm-qa.txt
      sudo mv $WORKSPACE/rpm-qa.txt.gz $BASE/logs/
    fi

    # Process testr artifacts.
    if [ -f $BASE/new/tempest/.testrepository/0 ]; then
        sudo cp $BASE/new/tempest/.testrepository/0 $BASE/logs/subunit_log.txt
        sudo python /usr/local/jenkins/slave_scripts/subunit2html.py $BASE/logs/subunit_log.txt $BASE/logs/testr_results.html
        sudo gzip -9 $BASE/logs/subunit_log.txt
        sudo gzip -9 $BASE/logs/testr_results.html
        sudo chown jenkins:jenkins $BASE/logs/subunit_log.txt.gz $BASE/logs/testr_results.html.gz
        sudo chmod a+r $BASE/logs/subunit_log.txt.gz $BASE/logs/testr_results.html.gz
    elif [ -f $BASE/new/tempest/.testrepository/tmp* ]; then
        # If testr timed out, collect temp file from testr
        sudo cp $BASE/new/tempest/.testrepository/tmp* $BASE/logs/subunit_log.txt
        sudo gzip -9 $BASE/logs/subunit_log.txt
        sudo chown jenkins:jenkins $BASE/logs/subunit_log.txt.gz
        sudo chmod a+r $BASE/logs/subunit_log.txt.gz
    fi

    if [ -f $BASE/new/tempest/tempest.log ] ; then
        sudo cp $BASE/new/tempest/tempest.log $BASE/logs/tempest.log
    fi

    sudo chown -R jenkins:jenkins $BASE/logs/etc/
    sudo chmod a+r $BASE/logs/etc/

    find $BASE/logs/etc/ -type f -exec rename 's/(.*)/$1.txt/' '{}' \;

    # Make sure jenkins can read all the logs and configs
    sudo chown -R jenkins:jenkins $BASE/logs/
    sudo chmod a+r $BASE/logs/

    rename 's/\.log$/.txt/' $BASE/logs/*
    rename 's/(.*)/$1.txt/' $BASE/logs/sudoers.d/*
    rename 's/\.log$/.txt/' $BASE/logs/rabbitmq/*

    sudo mv $BASE/logs/rabbitmq/startup_log \
       $BASE/logs/rabbitmq/startup_log.txt

    # Remove duplicate logs
    sudo rm $BASE/logs/*.*.txt

    if [ -d $BASE/old ]; then
        sudo rename 's/\.log$/.txt/' $BASE/logs/old/*
        sudo rename 's/\.log$/.txt/' $BASE/logs/new/*
        sudo rename 's/\.log$/.txt/' $BASE/logs/grenade/*
        sudo rm $BASE/logs/old/*.*.txt
        sudo rm $BASE/logs/new/*.*.txt
    fi

    # Compress all text logs
    sudo find $BASE/logs -iname '*.txt' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.dat' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.conf' -execdir gzip -9 {} \+

    # Save the tempest nosetests results
    sudo cp $BASE/new/tempest/nosetests*.xml $BASE/logs/
    sudo chown jenkins:jenkins $BASE/logs/nosetests*.xml
    sudo chmod a+r $BASE/logs/nosetests*.xml

    # Disable detailed logging as we return to the main script
    $xtrace
}
