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

SUDO="sudo"

# Distro check functions
function is_fedora {
    # note this is a little mis-named, we consider basically anything
    # using RPM as "is_fedora".  This includes centos7, fedora &
    # related distros like CloudOS and OracleLinux (note, we don't
    # support centos6 with this script -- we are assuming is_fedora
    # implies >=centos7 features such as systemd/journal, etc).
    #
    # This is KISS; if we need more fine-grained differentiation we
    # will handle it later.
    rpm -qf /etc/*-release >&/dev/null
}

function is_ubuntu {
    lsb_release -i 2>/dev/null | grep -iq "ubuntu"
}

function is_debian {
    # do not rely on lsb_release because it may be not installed by default
    cat /etc/*-release | grep ID 2>/dev/null | grep -iq "debian"
}

function uses_debs {
    # check if apt-get is installed, valid for debian based
    type "apt-get" 2>/dev/null
}

function function_exists {
    type $1 2>/dev/null | grep -q 'is a function'
}

function apt_get_install {
    # fetch the updates in a loop to ensure that we're update to
    # date. Only do this once per run. Give up to 5 minutes to succeed
    # here.
    if [[ -z "$APT_UPDATED" ]]; then
        if ! timeout 300 sh -c "while ! sudo apt-get update; do sleep 30; done"; then
            echo "Failed to update apt repos, we're dead now"
            exit 1
        fi
        APT_UPDATED=1
    fi

    sudo DEBIAN_FRONTEND=noninteractive apt-get --assume-yes install $@
}

function call_hook_if_defined {
    local hook_name=$1
    local filename=${2-$WORKSPACE/devstack-gate-$hook_name.txt}
    local save_dir=${3-$BASE/logs/}
    if function_exists $hook_name; then
        echo "Running $hook_name"
        xtrace=$(set +o | grep xtrace)
        set -o xtrace -o pipefail
        tsfilter $hook_name | tee $filename
        local ret_val=$?
        $SUDO mv $filename $save_dir
        set +o pipefail
        $xtrace
        return $ret_val
    fi
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
    # make sure we return the command status, not the awk status
    return ${PIPESTATUS[0]}
}

function _ping_check {
    local host=$1
    local times=${2:-20}
    echo "Testing ICMP connectivit to $host"
    ping -c $times $host
}

function _http_check {
    local url=$1
    local dl='wget --progress=bar -O /dev/null'
    if [[ `which curl` ]]; then
        dl='curl -# -o /dev/null'
    fi

    # do a pypi http fetch, to make sure that we're good
    for i in `seq 1 10`; do
        echo "HTTP check of $url - attempt #$i"
        $dl $url || /bin/true
    done
}

# do a few network tests to baseline how bad we are
function network_sanity_check {
    echo "Performing network sanity check..."
    PIP_CONFIG_FILE=/etc/pip.conf
    if [[ -f $PIP_CONFIG_FILE ]]; then
        line=$(cat $PIP_CONFIG_FILE|grep --max-count 1 index-url)
        pypi_url=${line#*=}
        pypi_host=$(echo $pypi_url|grep -Po '.*?//\K.*?(?=/)')

        _ping_check $pypi_host
        _http_check $pypi_url
    fi

    # rax ubuntu mirror
    _ping_check mirror.rackspace.com
    _http_check http://mirror.rackspace.com/ubuntu/dists/trusty/Release.gpg
}

# create the start timer for when the job began
function start_timer {
    # first make sure the time is right, so we don't go into crazy land
    # later if the system decides to apply an ntp date and we jump forward
    # 4 hrs (which has happened)
    if is_fedora; then
        local ntp_service='ntpd'
    elif uses_debs; then
        local ntp_service='ntp'
    else
        echo "Unsupported platform, can't determine ntp service"
        exit 1
    fi
    local default_ntp_server=$(
        grep ^server /etc/ntp.conf | head -1 | awk '{print $2}')
    local ntp_server=${NTP_SERVER:-$default_ntp_server}
    sudo service $ntp_service stop
    sudo /usr/sbin/ntpdate $ntp_server
    sudo service $ntp_service start
    sleep 1
    START_TIME=`date +%s`
}

function remaining_time {
    local now=`date +%s`
    local elapsed=$(((now - START_TIME) / 60))
    REMAINING_TIME=$((DEVSTACK_GATE_TIMEOUT - elapsed - 5))
    echo "Job timeout set to: $REMAINING_TIME minutes"
    if [ ${REMAINING_TIME} -le 0 ]; then
        echo "Already timed out."
        exit 1
    fi
}

# Create a script to reproduce this build
function reproduce {
    cat > $WORKSPACE/logs/reproduce.sh <<EOF
#!/bin/bash -xe

exec 0</dev/null

EOF

    export | grep '\(DEVSTACK\|ZUUL\)' >> $WORKSPACE/logs/reproduce.sh

    cat >> $WORKSPACE/logs/reproduce.sh <<EOF

mkdir -p workspace/$JOB_NAME
cd workspace/$JOB_NAME
export WORKSPACE=\`pwd\`

if [[ ! -e /usr/zuul-env ]]; then
  virtualenv /usr/zuul-env
  /usr/zuul-env/bin/pip install zuul
fi

cat > clonemap.yaml << IEOF
clonemap:
  - name: openstack-infra/devstack-gate
    dest: devstack-gate
IEOF

/usr/zuul-env/bin/zuul-cloner -m clonemap.yaml --cache-dir /opt/git git://git.openstack.org openstack-infra/devstack-gate

cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
./safe-devstack-vm-gate-wrap.sh

EOF

    chmod a+x $WORKSPACE/logs/reproduce.sh
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
    git_timed remote prune origin
}

function git_remote_update {
    git_timed remote update
}

# git can sometimes get itself infinitely stuck with transient network
# errors or other issues with the remote end.  This wraps git in a
# timeout/retry loop and is intended to watch over non-local git
# processes that might hang. Run for up to 5 minutes before killing.
# If first SIGTERM does not kill the process wait a minute then SIGKILL.
# If the git operation fails try again for up to a total of 3 attempts.
# usage: git_timed <git-command>
function git_timed {
    local max_attempts=3
    local count=0
    until timeout -k 1m 5m git "$@"; do
        count=$(($count + 1))
        echo "git $@ failed."
        if [ $count -eq $max_attempts ]; then
            echo "Max attempts reached for git $@; giving up."
            exit 1
        fi
        local sleep_time=$((30 + $RANDOM % 60))
        echo "sleep $sleep_time before retrying."
        sleep $sleep_time
    done
}

function git_remote_set_url {
    git remote set-url $1 $2
}

function git_clone_and_cd {
    local project=$1
    local short_project=$2
    local git_base=$3

    if [[ ! -e $short_project ]]; then
        echo "  Need to clone $short_project"
        git clone $git_base/$project
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
    # HPCloud and Rackspace performance nodes provide no swap, but do have
    # ephemeral disks we can use. For providers with no ephemeral disks, such
    # as OVH or Internap, create and use a sparse swapfile on the root
    # filesystem.
    # HPCloud also doesn't have enough space on / for two devstack installs,
    # so we partition the disk and mount it on /opt, syncing the previous
    # contents of /opt over.
    if [ `grep SwapTotal /proc/meminfo | awk '{ print $2; }'` -eq 0 ]; then
        if [ -b /dev/xvde ]; then
            DEV='/dev/xvde'
        else
            EPHEMERAL_DEV=$(blkid -L ephemeral0 || true)
            if [ -n "$EPHEMERAL_DEV" -a -b "$EPHEMERAL_DEV" ]; then
                DEV=$EPHEMERAL_DEV
            fi
        fi
        if [ -n "$DEV" ]; then
            # If an ephemeral device is available, use it
            local swap=${DEV}1
            local lvmvol=${DEV}2
            local optdev=${DEV}3
            if mount | grep ${DEV} > /dev/null; then
                echo "*** ${DEV} appears to already be mounted"
                echo "*** ${DEV} unmounting and reformating"
                sudo umount ${DEV}
            fi
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
        else
            # If no ephemeral devices are available, use root filesystem
            # Don't use sparse device to avoid wedging when disk space and
            # memory are both unavailable.
            local swapfile='/root/swapfile'
            sudo fallocate -l 8192M ${swapfile}
            sudo chmod 600 ${swapfile}
            sudo mkswap ${swapfile}
            sudo swapon ${swapfile}
        fi
    fi

    # dump vm settings for reference (Ubuntu 12 era procps can get
    # confused with certain proc trigger nodes that are write-only and
    # return a EPERM; ignore this)
    sudo sysctl vm || true

    # ensure a standard level of swappiness.  Some platforms
    # (rax+centos7) come with swappiness of 0 (presumably because the
    # vm doesn't come with swap setup ... but we just did that above),
    # which depending on the kernel version can lead to the OOM killer
    # kicking in on some processes despite swap being available;
    # particularly things like mysql which have very high ratio of
    # anonymous-memory to file-backed mappings.

    # make sure reload of sysctl doesn't reset this
    sudo sed -i '/vm.swappiness/d' /etc/sysctl.conf
    # This sets swappiness low; we really don't want to be relying on
    # cloud I/O based swap during our runs
    sudo sysctl -w vm.swappiness=10
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
#   The zuul ref for the project specific OVERRIDE_$PROJECT_PROJECT_BRANCH if specified
#   The zuul ref for the indicated branch
#   The zuul ref for the master branch
#   The tip of the project specific OVERRIDE_$PROJECT_PROJECT_BRANCH if specified
#   The tip of the indicated branch
#   The tip of the master branch
#
# If you would like to use a particular git base for a project other than
# GIT_BASE or https://git.openstack.org, for example in order to use
# a particular repositories for a third party CI, then supply that using
# variable OVERRIDE_${PROJECT}_GIT_BASE instead.
# (e.g. OVERRIDE_TEMPEST_GIT_BASE=http://example.com)
#
function setup_project {
    local project=$1
    local branch=$2
    local short_project=`basename $project`
    local git_base=${GIT_BASE:-https://git.openstack.org}
    # allow for possible project branch override
    local uc_project=`echo $short_project | tr [:lower:] [:upper:] | tr '-' '_' | sed 's/[^A-Z_]//'`
    local project_branch_var="\$OVERRIDE_${uc_project}_PROJECT_BRANCH"
    local project_branch=`eval echo ${project_branch_var}`
    if [[ "$project_branch" != "" ]]; then
        branch=$project_branch
    fi
    # allow for possible git_base override
    local project_git_base_var="\$OVERRIDE_${uc_project}_GIT_BASE"
    local project_git_base=`eval echo ${project_git_base_var}`
    if [[ "$project_git_base" != "" ]]; then
        git_base=$project_git_base
    fi

    echo "Setting up $project @ $branch"
    git_clone_and_cd $project $short_project $git_base

    git_remote_set_url origin $git_base/$project

    # Try the specified branch before the ZUUL_BRANCH.
    if [[ ! -z $ZUUL_BRANCH ]]; then
        OVERRIDE_ZUUL_REF=$(echo $ZUUL_REF | sed -e "s,$ZUUL_BRANCH,$branch,")
    else
        OVERRIDE_ZUUL_REF=""
    fi


    # Update git remotes
    git_remote_update
    # Ensure that we don't have stale remotes around
    git_prune
    # See if this project has this branch, if not, use master
    FALLBACK_ZUUL_REF=""
    if ! git_has_branch $project $branch; then
        FALLBACK_ZUUL_REF=$(echo $ZUUL_REF | sed -e "s,$branch,master,")
    fi

    if git_has_branch $project $branch; then
        git_checkout $project $branch
    else
        git_checkout $project master
    fi

    # See if Zuul prepared a ref for this project
    if git_fetch_at_ref $project $OVERRIDE_ZUUL_REF || \
        git_fetch_at_ref $project $FALLBACK_ZUUL_REF; then

        git config --global user.email "openstack@citrix.com"
        git config --global user.name "Citrix CI"

        # It's there, so merge it
        git merge FETCH_HEAD
    fi
}

function setup_workspace {
    local base_branch=$1
    local DEST=$2
    local xtrace=$(set +o | grep xtrace)
    local cache_dir=$BASE/cache/files/

    # Enabled detailed logging, since output of this function is redirected
    set -o xtrace

    if [ -z "$base_branch" ]; then
        echo "ERROR: setup_workspace: base_branch is an empty string!" >&2
        return 1
    fi

    fix_disk_layout

    sudo mkdir -p $DEST
    sudo chown -R $USER:$USER $DEST

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

    # Populate the cache for devstack (this will typically be vm images)
    #
    # If it's still in home, move it to /opt, this will make sure we
    # have the artifacts in the same filesystem as devstack.
    if [ -d ~/cache/files ]; then
        sudo mkdir -p $cache_dir
        sudo chown -R $USER:$USER $cache_dir
        find ~/cache/files/ -mindepth 1 -maxdepth 1 -exec mv {} $cache_dir \;
        rm -rf ~/cache/files/
    fi

    # copy them to where devstack expects with hardlinks to save space
    find $cache_dir -mindepth 1 -maxdepth 1 -exec cp -l {} $DEST/devstack/files/ \;

    # Disable detailed logging as we return to the main script
    $xtrace
}

function copy_mirror_config {
    # The pydistutils.cfg file is added by Puppet. Some CIs may not rely on
    # Puppet to do the base node installation
    if [ -f ~/.pydistutils.cfg ]; then
        sudo install -D -m0644 -o root -g root ~/.pydistutils.cfg ~root/.pydistutils.cfg

        sudo install -D -m0644 -o stack -g stack ~/.pydistutils.cfg ~stack/.pydistutils.cfg

        sudo install -D -m0644 -o tempest -g tempest ~/.pydistutils.cfg ~tempest/.pydistutils.cfg
    fi
}

function setup_host {
    # Enabled detailed logging, since output of this function is redirected
    local xtrace=$(set +o | grep xtrace)
    set -o xtrace

    echo "What's our kernel?"
    uname -a

    # capture # of cpus
    echo "NProc has discovered $(nproc) CPUs"
    cat /proc/cpuinfo

    # This is necessary to keep sudo from complaining
    fix_etc_hosts

    # We set some home directories under $BASE, make sure it exists.
    sudo mkdir -p $BASE

    # Start with a fresh syslog
    if uses_debs; then
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
    elif is_fedora; then
        # save timestamp and use journalctl to dump everything since
        # then at the end
        date +"%Y-%m-%d %H:%M:%S" | sudo tee $BASE/log-start-timestamp.txt
    fi

    # Create a stack user for devstack to run as, so that we can
    # revoke sudo permissions from that user when appropriate.
    sudo useradd -U -s /bin/bash -d $BASE/new -m stack
    # Use 755 mode on the user dir regarless to the /etc/login.defs setting
    sudo chmod 755 $BASE/new
    TEMPFILE=`mktemp`
    echo "stack ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh

    # Create user's ~/.cache directory with proper permissions, ensuring later
    # 'sudo pip install's do not create it owned by root.
    sudo mkdir -p $BASE/new/.cache
    sudo chown -R stack:stack $BASE/new/.cache

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
    # ~/.pydisutils.cfg in the copy_mirror_config
    # function if tox/pip will be used at all.

    # If we will be testing OpenVZ, make sure stack is a member of the vz group
    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
        sudo usermod -a -G vz stack
    fi

    # Ensure that all of the users have the openstack mirror config
    copy_mirror_config

    # perform network sanity check so that we can characterize the
    # state of the world
    network_sanity_check

    # Disable detailed logging as we return to the main script
    $xtrace
}

function archive_test_artifact {
    local filename=$1

    sudo gzip -9 $filename
    sudo chown $USER:$USER $filename.gz
    sudo chmod a+r $filename.gz
}

function process_testr_artifacts {
    local project=$1
    local path_prefix=${2:-new}

    local project_path=$BASE/$path_prefix/$project
    local repo_path=$project_path/.testrepository
    local log_path=$BASE/logs
    if [[ "$path_prefix" != "new" ]]; then
        log_path=$BASE/logs/$path_prefix
    fi

    if  [[ -f $BASE/devstack.subunit ]]; then
        sudo cp $BASE/devstack.subunit $log_path/testrepository.subunit
    fi

    # Check for an interrupted run first because 0 will always exist
    if [ -f $repo_path/tmp* ]; then
        # If testr timed out, collect temp file from testr
        sudo cat $repo_path/tmp* >> $WORKSPACE/tempest.subunit
        archive_test_artifact $WORKSPACE/tempest.subunit
    elif [ -f $repo_path/0 ]; then
        pushd $project_path
        sudo testr last --subunit > $WORKSPACE/tempest.subunit
        popd
    fi
    if [[ -f $log_path/testrepository.subunit ]] ; then
        if [[ -f $WORKSPACE/tempest.subunit ]] ; then
            sudo cat $WORKSPACE/tempest.subunit \
                | sudo tee -a $log_path/testrepository.subunit > /dev/null
        fi
        sudo /usr/os-testr-env/bin/subunit2html \
            $log_path/testrepository.subunit $log_path/testr_results.html
        archive_test_artifact $log_path/testrepository.subunit
        archive_test_artifact $log_path/testr_results.html
    fi
}

function cleanup_host {
    # TODO: clean this up to be errexit clean
    local errexit=$(set +o | grep errexit)
    set +o errexit

    # Enabled detailed logging, since output of this function is redirected
    local xtrace=$(set +o | grep xtrace)
    set -o xtrace

    cd $WORKSPACE

    # Sleep to give services a chance to flush their log buffers.
    sleep 2

    # No matter what, archive logs and config files
    if uses_debs; then
        sudo cp /var/log/syslog $BASE/logs/syslog.txt
        sudo cp /var/log/kern.log $BASE/logs/kern_log.txt
    elif is_fedora; then
        # the journal gives us syslog() and kernel output, so is like
        # a concatenation of the above.
        sudo journalctl --no-pager \
            --since="$(cat $BASE/log-start-timestamp.txt)" \
            | sudo tee $BASE/logs/syslog.txt > /dev/null
    fi

    # apache logs; including wsgi stuff like horizon, keystone, etc.
    if uses_debs; then
        local apache_logs=/var/log/apache2
    elif is_fedora; then
        local apache_logs=/var/log/httpd
    fi
    sudo cp -r ${apache_logs} $BASE/logs/apache

    # rabbitmq logs
    if [ -d /var/log/rabbitmq ]; then
        sudo cp -r /var/log/rabbitmq $BASE/logs
    fi

    # db logs
    if [ -d /var/log/postgresql ] ; then
        # Rename log so it doesn't have an additional '.' so it won't get
        # deleted
        sudo cp /var/log/postgresql/*log $BASE/logs/postgres.log
    fi
    if [ -f /var/log/mysql.err ] ; then
        sudo cp /var/log/mysql.err $BASE/logs/mysql_err.log
    fi
    if [ -f /var/log/mysql.log ] ; then
        sudo cp /var/log/mysql.log $BASE/logs/
    fi

    # libvirt
    if [ -d /var/log/libvirt ] ; then
        sudo cp -r /var/log/libvirt $BASE/logs/
        sudo cp -r /usr/share/libvirt/cpu_map.xml $BASE/logs/libvirt/cpu_map.xml
    fi

    # sudo config
    sudo cp -r /etc/sudoers.d $BASE/logs/
    sudo cp /etc/sudoers $BASE/logs/sudoers.txt

    # Archive config files
    sudo mkdir $BASE/logs/etc/
    for PROJECT in $PROJECTS; do
        proj=`basename $PROJECT`
        if [ -d /etc/$proj ]; then
            sudo cp -r /etc/$proj $BASE/logs/etc/
        fi
    done

    # Archive Apache config files
    sudo mkdir $BASE/logs/apache_config
    if uses_debs; then
        if [[ -d /etc/apache2/sites-enabled ]]; then
            sudo cp /etc/apache2/sites-enabled/* $BASE/logs/apache_config
        fi
    elif is_fedora; then
        if [[ -d /etc/apache2/httpd/conf.d ]]; then
            sudo cp /etc/httpd/conf.d/* $BASE/logs/apache_config
        fi
    fi

    # copy devstack log files
    if [ -d $BASE/old ]; then
        sudo mkdir -p $BASE/logs/old $BASE/logs/new

        # copy all log files, but note that devstack creates a shortened
        # symlink without timestamp (foo.log -> foo.2014-01-01-000000.log)
        # for each log to latest log. Thus we just copy the symlinks to
        # avoid excessively long file-names.
        find $BASE/old/screen-logs -type l -print0 | \
            xargs -0 -I {} sudo cp {} $BASE/logs/old
        sudo cp $BASE/old/devstacklog.txt $BASE/logs/old/
        sudo cp $BASE/old/devstack/localrc $BASE/logs/old/localrc.txt
        sudo cp $BASE/old/tempest/etc/tempest.conf $BASE/logs/old/tempest_conf.txt
        if -f [ $BASE/old/devstack/tempest.log ] ; then
            sudo cp $BASE/old/devstack/tempest.log $BASE/logs/old/verify_tempest_conf.log
        fi

        # dstat CSV log
        if [ -f $BASE/old/dstat-csv.log ]; then
            sudo cp $BASE/old/dstat-csv.log $BASE/logs/old/
        fi

        # grenade logs
        sudo cp $BASE/new/grenade/localrc $BASE/logs/grenade_localrc.txt

        # grenade saved state files - resources created during upgrade tests
        # use this directory to dump arbitrary configuration/state files.
        if [ -d $BASE/save ]; then
            sudo mkdir -p $BASE/logs/grenade_save
            sudo cp -r $BASE/save/* $BASE/logs/grenade_save/
        fi

        # grenade pluginrc - external grenade plugins use this file to
        # communicate with grenade, capture for posterity
        if -f [ $BASE/new/grenade/pluginrc ]; then
            sudo cp $BASE/new/grenade/pluginrc $BASE/logs/grenade_pluginrc.txt
        fi

        # grenade logs directly and uses similar timestampped files to
        # devstack.  So temporarily copy out & rename the latest log
        # files from the short-symlinks into grenade/, clean-up left
        # over time-stampped files and put the interesting logs back at
        # top-level for easy access
        sudo mkdir -p $BASE/logs/grenade
        sudo cp $BASE/logs/grenade.sh.log $BASE/logs/grenade/
        sudo cp $BASE/logs/grenade.sh.log.summary \
            $BASE/logs/grenade/grenade.sh.summary.log
        sudo rm $BASE/logs/grenade.sh.*
        sudo mv $BASE/logs/grenade/*.log $BASE/logs
        sudo rm -rf $BASE/logs/grenade
        if [ -f $BASE/new/grenade/javelin.log ] ; then
            sudo cp $BASE/new/grenade/javelin.log $BASE/logs/javelin.log
        fi

        NEWLOGTARGET=$BASE/logs/new
    else
        NEWLOGTARGET=$BASE/logs
    fi
    find $BASE/new/screen-logs -type l -print0 | \
        xargs -0 -I {} sudo cp {} $NEWLOGTARGET/
    sudo cp $BASE/new/devstacklog.txt $NEWLOGTARGET/
    sudo cp $BASE/new/devstack/localrc $NEWLOGTARGET/localrc.txt
    if [ -f $BASE/new/devstack/tempest.log ]; then
        sudo cp $BASE/new/devstack/tempest.log $NEWLOGTARGET/verify_tempest_conf.log
    fi

    # Copy failure files if they exist
    if [ $(ls $BASE/status/stack/*.failure | wc -l) -gt 0 ]; then
        sudo mkdir -p $BASE/logs/status
        sudo cp $BASE/status/stack/*.failure $BASE/logs/status/
    fi

    # Copy Ironic nodes console logs if they exist
    if [ -d $BASE/new/ironic-bm-logs ] ; then
        sudo mkdir -p $BASE/logs/ironic-bm-logs
        sudo cp $BASE/new/ironic-bm-logs/*.log $BASE/logs/ironic-bm-logs/
    fi

    # Copy tempest config file
    sudo cp $BASE/new/tempest/etc/tempest.conf $NEWLOGTARGET/tempest_conf.txt

    # Copy dstat CSV log if it exists
    if [ -f $BASE/new/dstat-csv.log ]; then
        sudo cp $BASE/new/dstat-csv.log $BASE/logs/
    fi

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

    process_testr_artifacts tempest
    process_testr_artifacts tempest old

    if [ -f $BASE/new/tempest/tempest.log ] ; then
        sudo cp $BASE/new/tempest/tempest.log $BASE/logs/tempest.log
    fi
    if [ -f $BASE/old/tempest/tempest.log ] ; then
        sudo cp $BASE/old/tempest/tempest.log $BASE/logs/old/tempest.log
    fi

    # ceph logs and config
    if [ -d /var/log/ceph ] ; then
        sudo cp -r /var/log/ceph $BASE/logs/
    fi
    if [ -f /etc/ceph/ceph.conf ] ; then
        sudo cp /etc/ceph/ceph.conf $BASE/logs/ceph_conf.txt
    fi

    if [ -d /var/log/openvswitch ] ; then
        sudo cp -r /var/log/openvswitch $BASE/logs/
    fi

    # Make sure the current user can read all the logs and configs
    sudo chown -R $USER:$USER $BASE/logs/
    sudo chmod a+r $BASE/logs/ $BASE/logs/etc

    # rename files to .txt; this is so that when displayed via
    # logs.openstack.org clicking results in the browser shows the
    # files, rather than trying to send it to another app or make you
    # download it, etc.

    # firstly, rename all .log files to .txt files
    for f in $(find $BASE/logs -name "*.log"); do
        sudo mv $f ${f/.log/.txt}
    done

    #rename all failure files to have .txt
    for f in $(find $BASE/logs/status -name "*.failure"); do
        sudo mv $f ${f/.failure/.txt}
    done

    # append .txt to all config files
    # (there are some /etc/swift .builder and .ring files that get
    # caught up which aren't really text, don't worry about that)
    find $BASE/logs/sudoers.d $BASE/logs/etc -type f -exec mv '{}' '{}'.txt \;

    # rabbitmq
    if [ -f $BASE/logs/rabbitmq/ ]; then
        find $BASE/logs/rabbitmq -type f -exec mv '{}' '{}'.txt \;
        for X in `find $BASE/logs/rabbitmq -type f` ; do
            mv "$X" "${X/@/_at_}"
        done
    fi

    # glusterfs logs and config
    if [ -d /var/log/glusterfs ] ; then
        sudo cp -r /var/log/glusterfs $BASE/logs/
    fi
    if [ -f /etc/glusterfs/glusterd.vol ] ; then
        sudo cp /etc/glusterfs/glusterd.vol $BASE/logs/
    fi

    # final memory usage and process list
    ps -eo user,pid,ppid,lwp,%cpu,%mem,size,rss,cmd > $BASE/logs/ps.txt

    # Compress all text logs
    sudo find $BASE/logs -iname '*.txt' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.dat' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.conf' -execdir gzip -9 {} \+

    # Disable detailed logging as we return to the main script
    $xtrace

    $errexit
}

function remote_command {
    local ssh_opts="-tt -o PasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectionAttempts=4"
    local dest_host=$1
    shift
    ssh $ssh_opts $dest_host "$@"
}

function remote_copy_dir {
    local dest_host=$1
    local src_dir=$2
    local dest_dir=$3
    remote_command "$dest_host"  mkdir -p "$dest_dir"
    rsync -avz "$src_dir" "${dest_host}:$dest_dir"
}

function remote_copy_file {
    local ssh_opts="-o PasswordAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectionAttempts=4"
    local src=$1
    local dest=$2
    shift
    scp $ssh_opts "$src" "$dest"
}

# enable_netconsole
function enable_netconsole {

    # do nothing if not set
    if [[ $DEVSTACK_GATE_NETCONSOLE = "" ]]; then
        return
    fi

    local remote_ip=$(echo $DEVSTACK_GATE_NETCONSOLE | awk -F: -e '{print $1}')
    local remote_port=$(echo $DEVSTACK_GATE_NETCONSOLE | awk -F: -e '{print $2}')

    # netconsole requires the device to send and the destitation MAC,
    # which is obviously on the same subnet.  The way to get packets
    # out to the world is specify the default gw as the remote
    # destination.
    local default_gw=$(ip route | grep default | awk '{print $3}')
    local gw_mac=$(arp $default_gw | grep $default_gw | awk '{print $3}')
    local gw_dev=$(ip route | grep default | awk '{print $5}')

    # turn up message output
    sudo dmesg -n 8

    sudo modprobe configfs
    sudo modprobe netconsole

    sudo mount none -t configfs /sys/kernel/config

    sudo mkdir /sys/kernel/config/netconsole/target1

    pushd /sys/kernel/config/netconsole/target1
    echo "$gw_dev" | sudo tee ./dev_name
    echo "$remote_ip" | sudo tee ./remote_ip
    echo "$gw_mac" | sudo tee ./remote_mac
    echo "$remote_port" | sudo tee ./remote_port
    echo 1 | sudo tee ./enabled
    popd
}


# This function creates an internal gre bridge to connect all external
# network bridges across the compute and network nodes.
# bridge_name: Bridge name on each host for logical l2 network
#              connectivity.
# host_ip: ip address of the bridge host which is reachable for all peer
#          the hub for all of our spokes.
# set_ips: Whether or not to set l3 addresses on our logical l2 network.
#          This can be helpful for setting up routing tables.
# offset: starting value for gre tunnel key and the ip addr suffix
# The next two parameters are only used if set_ips is "True".
# pub_addr_prefix: The IPv4 address three octet prefix used to give compute
#                  nodes non conflicting addresses on the pub_if_name'd
#                  network. Should be provided as X.Y.Z. Offset will be
#                  applied to this as well as the below mask to get the
#                  resulting address.
# pub_addr_mask: the CIDR mask less the '/' for the IPv4 addresses used
#                above.
# every additional parameter is considered as a peer host (spokes)
#
# For OVS troubleshooting needs:
#   http://www.yet.org/2014/09/openvswitch-troubleshooting/
#
function ovs_vxlan_bridge {
    if is_fedora; then
        local ovs_package='openvswitch'
        local ovs_service='openvswitch'
    elif uses_debs; then
        local ovs_package='openvswitch-switch'
        local ovs_service='openvswitch-switch'
    else
        echo "Unsupported platform, can't determine ntp service"
        exit 1
    fi
    local install_ovs_deps="source $BASE/new/devstack/functions-common; \
                            install_package ${ovs_package}; \
                            restart_service ${ovs_service}"
    local mtu=1450
    local bridge_name=$1
    local host_ip=$2
    local set_ips=$3
    local offset=$4
    if [[ "$set_ips" == "True" ]] ; then
        local pub_addr_prefix=$5
        local pub_addr_mask=$6
        shift 6
    else
        shift 4
    fi
    local peer_ips=$@
    eval $install_ovs_deps
    # create a bridge, just like you would with 'brctl addbr'
    # if the bridge exists, --may-exist prevents ovs from returning an error
    sudo ovs-vsctl --may-exist add-br $bridge_name
    # as for the mtu, look for notes on lp#1301958 in devstack-vm-gate.sh
    sudo ip link set mtu $mtu dev $bridge_name
    if [[ "$set_ips" == "True" ]] ; then
        echo "Set bridge: ${bridge_name}"
        if ! sudo ip addr show dev ${bridge_name} | grep -q \
            ${pub_addr_prefix}.${offset}/${pub_addr_mask} ; then
                sudo ip addr add ${pub_addr_prefix}.${offset}/${pub_addr_mask} \
                    dev ${bridge_name}
        fi
    fi
    for node_ip in $peer_ips; do
        (( offset++ ))
        # For reference on how to setup a tunnel using OVS see:
        #   http://openvswitch.org/support/config-cookbooks/port-tunneling/
        # The command below is equivalent to the sequence of ip/brctl commands
        # where an interface of vxlan type is created first, and then plugged into
        # the bridge; options are command specific configuration key-value pairs.
        #
        # Create the vxlan tunnel for the Controller/Network Node:
        #  This establishes a tunnel between remote $node_ip to local $host_ip
        #  uniquely identified by a key $offset
        sudo ovs-vsctl --may-exist add-port $bridge_name \
            ${bridge_name}_${node_ip} \
            -- set interface ${bridge_name}_${node_ip} type=vxlan \
            options:remote_ip=${node_ip} \
            options:key=${offset} \
            options:local_ip=${host_ip}
        # Now complete the vxlan tunnel setup for the Compute Node:
        #  Similarly this establishes the tunnel in the reverse direction
        remote_command $node_ip "$install_ovs_deps"
        remote_command $node_ip sudo ovs-vsctl --may-exist add-br $bridge_name
        remote_command $node_ip sudo ip link set mtu $mtu dev $bridge_name
        remote_command $node_ip sudo ovs-vsctl --may-exist add-port $bridge_name \
            ${bridge_name}_${host_ip} \
            -- set interface ${bridge_name}_${host_ip} type=vxlan \
            options:remote_ip=${host_ip} \
            options:key=${offset} \
            options:local_ip=${node_ip}
        if [[ "$set_ips" == "True" ]] ; then
            if ! remote_command $node_ip sudo ip addr show dev ${bridge_name} | \
                grep -q ${pub_addr_prefix}.${offset}/${pub_addr_mask} ; then
                    remote_command $node_ip sudo ip addr add \
                        ${pub_addr_prefix}.${offset}/${pub_addr_mask} \
                        dev ${bridge_name}
            fi
        fi
    done
}

# Timeout hook calls implemented as bash functions. Note this
# forks and execs a new bash in order to use the timeout utility
# which cannot operate on bash functions directly.
function with_timeout {
    local cmd=$@
    remaining_time
    timeout -s 9 ${REMAINING_TIME}m bash -c "source $WORKSPACE/devstack-gate/functions.sh && $cmd"
}

# Iniset imported from devstack
function iniset {
    $(source $BASE/new/devstack/inc/ini-config; iniset $@)
}
