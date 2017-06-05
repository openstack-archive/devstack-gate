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
    export REMAINING_TIME=$((DEVSTACK_GATE_TIMEOUT - elapsed - 5))
    echo "Job timeout set to: $REMAINING_TIME minutes"
    if [ ${REMAINING_TIME} -le 0 ]; then
        echo "Already timed out."
        exit 1
    fi
}

# Create a script to reproduce this build
function reproduce {
    local xtrace=$(set +o | grep xtrace)
    set +o xtrace

    JOB_PROJECTS=$1
    cat > $WORKSPACE/logs/reproduce.sh <<EOF
#!/bin/bash -xe
#
# Script to reproduce devstack-gate run.
#
# Prerequisites:
# - Fresh install of current Ubuntu LTS, with basic internet access.
#   Note we can and do run devstack-gate on other distros double check
#   where your job ran (will be recorded in console.html) to reproduce
#   as accurately as possible.
# - Must have python-all-dev, build-essential, git, libssl-dev, ntp, ntpdate
#   installed from apt, or their equivalents on other distros.
# - Must have virtualenv installed from pip
# - Must be run as root
#

exec 0</dev/null

EOF

    # first get all keys that match our filter and then output the whole line
    # that will ensure that multi-line env vars are set properly
    for KEY in $(printenv -0 | grep -z -Z '\(DEVSTACK\|GRENADE_PLUGINRC\|ZUUL\)' | sed -z -n 's/^\([^=]\+\)=.*/\1\n/p'); do
        echo "declare -x ${KEY}=\"${!KEY}\"" >> $WORKSPACE/logs/reproduce.sh
    done
    # If TEMPEST_CONCURRENCY has been explicitly set to 1, then save it in reproduce.sh
    if [ "${TEMPEST_CONCURRENCY}" -eq 1 ]; then
        echo "declare -x TEMPEST_CONCURRENCY=\"${TEMPEST_CONCURRENCY}\"" >> $WORKSPACE/logs/reproduce.sh
    fi
    if [ -n "$JOB_PROJECTS" ] ; then
        echo "declare -x PROJECTS=\"$JOB_PROJECTS\"" >> $WORKSPACE/logs/reproduce.sh
    fi
    for fun in pre_test_hook gate_hook post_test_hook ; do
        if function_exists $fun ; then
            declare -fp $fun >> $WORKSPACE/logs/reproduce.sh
        fi
    done

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
    $xtrace
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

function fix_disk_layout {
    # Don't attempt to fix disk layout more than once
    [[ -e /etc/fixed_disk_layout ]] && return 0 || sudo touch /etc/fixed_disk_layout

    # Ensure virtual machines from different providers all have at least 8GB of
    # swap.
    # Use an ephemeral disk if there is one or create and use a swapfile.
    # Rackspace also doesn't have enough space on / for two devstack installs,
    # so we partition the disk and mount it on /opt, syncing the previous
    # contents of /opt over.
    SWAPSIZE=8192
    swapcurrent=$(( $(grep SwapTotal /proc/meminfo | awk '{ print $2; }') / 1024 ))

    if [[ $swapcurrent -lt $SWAPSIZE ]]; then
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
            sudo parted ${DEV} --script -- mkpart primary linux-swap 1 ${SWAPSIZE}
            sudo parted ${DEV} --script -- mkpart primary ext2 8192 -1
            sudo mkswap ${DEV}1
            sudo mkfs.ext4 ${DEV}2
            sudo swapon ${DEV}1
            sudo mount ${DEV}2 /mnt
            sudo find /opt/ -mindepth 1 -maxdepth 1 -exec mv {} /mnt/ \;
            sudo umount /mnt
            sudo mount ${DEV}2 /opt

            # Sanity check
            grep -q ${DEV}1 /proc/swaps || exit 1
            grep -q ${DEV}2 /proc/mounts || exit 1
        else
            # If no ephemeral devices are available, use root filesystem
            # Don't use sparse device to avoid wedging when disk space and
            # memory are both unavailable.
            local swapfile='/root/swapfile'
            sudo touch ${swapfile}
            swapdiff=$(( $SWAPSIZE - $swapcurrent ))

            if sudo df -T ${swapfile} | grep -q ext ; then
                sudo fallocate -l ${swapdiff}M ${swapfile}
            else
                # Cannot fallocate on filesystems like XFS
                sudo dd if=/dev/zero of=${swapfile} bs=1M count=${swapdiff}
            fi
            sudo chmod 600 ${swapfile}
            sudo mkswap ${swapfile}
            sudo swapon ${swapfile}

            # Sanity check
            grep -q ${swapfile} /proc/swaps || exit 1
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
    sudo sysctl -w vm.swappiness=30
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

    if [ -d $cache_dir ]; then
        # copy them to where devstack expects with hardlinks to save space
        find $cache_dir -mindepth 1 -maxdepth 1 -exec cp -l {} $DEST/devstack/files/ \;
    fi

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

function process_stackviz {
    local project=$1
    local path_prefix=${2:-new}

    local stackviz_tarball=$BASE/cache/files/stackviz-latest.tar.gz
    if [ ! -f $stackviz_tarball ]; then
        echo "Unable to locate cached stackviz tarball, skipping."
        return
    fi

    local project_path=$BASE/$path_prefix/$project
    local log_path=$BASE/logs
    if [[ "$path_prefix" != "new" ]]; then
        log_path=$BASE/logs/$path_prefix
    fi
    local stackviz_path=/tmp/stackviz
    virtualenv $stackviz_path
    $stackviz_path/bin/pip install -U $stackviz_tarball

    # static html+js should be prebuilt during image creation
    cp -r $stackviz_path/share/stackviz-html $log_path/stackviz

    pushd $project_path
    if [ -f $log_path/dstat-csv_log.txt ]; then
        sudo testr last --subunit | $stackviz_path/bin/stackviz-export \
            --dstat $log_path/dstat-csv_log.txt \
            --env --stdin \
            $log_path/stackviz/data
    else
        sudo testr last --subunit | $stackviz_path/bin/stackviz-export \
            --env --stdin \
            $log_path/stackviz/data
    fi
    sudo chown -R $USER:$USER $log_path/stackviz
    # Compress the stackviz data as it is quite large.
    sudo find $log_path/stackviz -iname '*.json' -execdir gzip -9 {} \+
    popd
}

function save_file {
    local from=$1
    local to=$2
    if [[ -z "$to" ]]; then
        to=$(basename $from)
        if [[ "$to" != *.txt ]]; then
            to=${to/\./_}
            to="$to.txt"
        fi
    fi
    if [[ -f $from ]]; then
        sudo cp $from $BASE/logs/$to
    fi
}

function save_dir {
    local from=$1
    local to=$2
    if [[ -d $from ]]; then
        sudo cp -r $from $BASE/logs/$to
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

    # apache logs; including wsgi stuff like horizon, keystone, etc.
    if uses_debs; then
        local apache_logs=/var/log/apache2
    elif is_fedora; then
        local apache_logs=/var/log/httpd
    fi
    sudo cp -r ${apache_logs} $BASE/logs/apache

    # rabbitmq logs
    save_dir /var/log/rabbitmq

    # db logs
    if [ -d /var/log/postgresql ] ; then
        # Rename log so it doesn't have an additional '.' so it won't get
        # deleted
        sudo cp /var/log/postgresql/*log $BASE/logs/postgres.log
    fi
    save_file /var/log/mysql.err
    save_file /var/log/mysql.log

    # libvirt
    save_dir /var/log/libvirt

    # sudo config
    save_dir /etc/sudoers.d
    save_file /etc/sudoers

    # Archive config files
    # NOTE(mriedem): 'openstack' is added separately since it's not a project
    # but it is where clouds.yaml is stored in dsvm runs that use it.
    sudo mkdir $BASE/logs/etc/
    for PROJECT in $PROJECTS openstack; do
        proj=`basename $PROJECT`
        save_dir /etc/$proj etc/
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
        save_file $BASE/old/devstacklog.txt old/devstacklog.txt
        save_file $BASE/old/devstacklog.txt.summary old/devstacklog.summary.txt
        save_file $BASE/old/devstack/localrc old/localrc.txt
        save_file $BASE/old/devstack/local.conf old/local_conf.txt
        save_file $BASE/old/tempest/etc/tempest.conf old/tempest_conf.txt
        save_file $BASE/old/devstack/tempest.log old/verify_tempest_conf.log

        # Copy Ironic nodes console logs if they exist
        if [ -d $BASE/old/ironic-bm-logs ] ; then
            sudo mkdir -p $BASE/logs/old/ironic-bm-logs
            sudo cp $BASE/old/ironic-bm-logs/*.log $BASE/logs/old/ironic-bm-logs/
        fi

        # dstat CSV log
        save_file $BASE/old/dstat-csv.log old/

        # grenade logs
        save_file $BASE/new/grenade/localrc grenade_localrc.txt

        # grenade saved state files - resources created during upgrade tests
        # use this directory to dump arbitrary configuration/state files.
        if [ -d $BASE/save ]; then
            sudo mkdir -p $BASE/logs/grenade_save
            sudo cp -r $BASE/save/* $BASE/logs/grenade_save/
        fi

        # grenade pluginrc - external grenade plugins use this file to
        # communicate with grenade, capture for posterity
        save_file $BASE/new/grenade/pluginrc grenade_pluginrc.txt

        # grenade logs directly and uses similar timestampped files to
        # devstack.  So temporarily copy out & rename the latest log
        # files from the short-symlinks into grenade/, clean-up left
        # over time-stampped files and put the interesting logs back at
        # top-level for easy access
        sudo mkdir -p $BASE/logs/grenade
        save_file $BASE/logs/grenade.sh.log grenade/grenade.sh.log
        save_file $BASE/logs/grenade.sh.log.summary \
            grenade/grenade.sh.summary.log
        sudo rm $BASE/logs/grenade.sh.*
        sudo mv $BASE/logs/grenade/*.log $BASE/logs
        sudo rm -rf $BASE/logs/grenade
        save_file $BASE/new/grenade/javelin.log javelin.log

        NEWLOGPREFIX=new/
    else
        NEWLOGPREFIX=
    fi
    NEWLOGTARGET=$BASE/logs/$NEWLOGPREFIX
    find $BASE/new/screen-logs -type l -print0 | \
        xargs -0 -I {} sudo cp {} $NEWLOGTARGET/
    save_file $BASE/new/devstacklog.txt ${NEWLOGPREFIX}devstacklog.txt
    save_file $BASE/new/devstacklog.txt.summary ${NEWLOGPREFIX}devstacklog.summary.txt
    save_file $BASE/new/devstack/localrc ${NEWLOGPREFIX}localrc.txt
    save_file $BASE/new/devstack/local.conf ${NEWLOGPREFIX}local.conf.txt
    save_file $BASE/new/devstack/tempest.log ${NEWLOGPREFIX}verify_tempest_conf.log

    # Copy over any devstack systemd unit journals. Note, we will no
    # longer get separate new/old grenade logs when this happens.
    if which journalctl; then
        local jremote=""
        if uses_debs; then
            if ! dpkg -s "systemd-journal-remote" > /dev/null; then
                apt_get_install systemd-journal-remote
            fi
            jremote="/lib/systemd/systemd-journal-remote"
        elif is_fedora; then
            if ! rpm --quiet -q "systemd-journal-gateway"; then
                sudo yum install -y systemd-journal-gateway
            fi
            jremote="/usr/lib/systemd/systemd-journal-remote"
        fi


        local u=""
        local name=""
        for u in `sudo systemctl list-unit-files | grep devstack | awk '{print $1}'`; do
            name=$(echo $u | sed 's/devstack@/screen-/' | sed 's/\.service//')
            sudo journalctl -o short-precise --unit $u | sudo tee $BASE/logs/$name.txt > /dev/null
        done
        # export the journal in native format to make it downloadable
        # for later searching, makes a class of debugging much
        # easier.
        sudo journalctl -u 'devstack@*' -o export | \
            $jremote -o $BASE/logs/devstack.journal -
        # The journal contains everything running under systemd, we'll
        # build an old school version of the syslog with just the
        # kernel and sudo messages.
        sudo journalctl \
             -t kernel \
             -t sudo \
             --no-pager \
             --since="$(cat $BASE/log-start-timestamp.txt)" \
            | sudo tee $BASE/logs/syslog.txt > /dev/null
    else
        # assume rsyslog
        save_file /var/log/syslog
        save_file /var/log/kern.log
    fi

    # Copy failure files if they exist
    if [ $(ls $BASE/status/stack/*.failure | wc -l) -gt 0 ]; then
        sudo mkdir -p $BASE/logs/status
        sudo cp $BASE/status/stack/*.failure $BASE/logs/status/
    fi

    # Copy Ironic nodes console logs if they exist
    if [ -d $BASE/new/ironic-bm-logs ] ; then
        sudo mkdir -p $BASE/logs/ironic-bm-logs
        sudo cp -r $BASE/new/ironic-bm-logs/* $BASE/logs/ironic-bm-logs/
    fi

    # Copy tempest config file
    save_file $BASE/new/tempest/etc/tempest.conf ${NEWLOGPREFIX}tempest_conf.txt
    save_file $BASE/new/tempest/etc/accounts.yaml ${NEWLOGPREFIX}accounts_yaml.txt

    # Copy dstat CSV log if it exists
    save_file $BASE/new/dstat-csv.log

    sudo iptables-save > $WORKSPACE/iptables.txt
    df -h > $WORKSPACE/df.txt
    save_file $WORKSPACE/iptables.txt
    save_file $WORKSPACE/df.txt

    for py_ver in 2 3; do
        if [[ `which python${py_ver}` ]]; then
            python${py_ver} -m pip freeze > $WORKSPACE/pip${py_ver}-freeze.txt
            save_file $WORKSPACE/pip${py_ver}-freeze.txt
        fi
    done

    if [ `command -v dpkg` ]; then
        dpkg -l> $WORKSPACE/dpkg-l.txt
        gzip -9 dpkg-l.txt
        sudo mv $WORKSPACE/dpkg-l.txt.gz $BASE/logs/
    fi
    if [ `command -v rpm` ]; then
        rpm -qa | sort > $WORKSPACE/rpm-qa.txt
        gzip -9 rpm-qa.txt
        sudo mv $WORKSPACE/rpm-qa.txt.gz $BASE/logs/
    fi

    process_stackviz tempest

    process_testr_artifacts tempest
    process_testr_artifacts tempest old

    save_file $BASE/new/tempest/tempest.log tempest.log
    save_file $BASE/old/tempest/tempest.log old/tempest.log

    # ceph logs and config
    if [ -d /var/log/ceph ] ; then
        sudo cp -r /var/log/ceph $BASE/logs/
    fi
    save_file /etc/ceph/ceph.conf

    if [ -d /var/log/openvswitch ] ; then
        sudo cp -r /var/log/openvswitch $BASE/logs/
    fi

    # glusterfs logs and config
    if [ -d /var/log/glusterfs ] ; then
        sudo cp -r /var/log/glusterfs $BASE/logs/
    fi
    save_file /etc/glusterfs/glusterd.vol glusterd.vol

    # gzip and save any coredumps in /var/core
    if [ -d /var/core ]; then
        sudo gzip -r /var/core
        sudo cp -r /var/core $BASE/logs/
    fi

    # Make sure the current user can read all the logs and configs
    sudo chown -RL $USER:$USER $BASE/logs/
    # (note X not x ... execute/search only if the file is a directory
    # or already has execute permission for some user)
    sudo find $BASE/logs/ -exec chmod a+rX  {} \;
    # Remove all broken symlinks, which point to non existing files
    # They could be copied by rsync
    sudo find $BASE/logs/ -type l -exec test ! -e {} \; -delete

    # Collect all the deprecation related messages into a single file.
    # strip out date(s), timestamp(s), pid(s), context information and
    # remove duplicates as well so we have a limited set of lines to
    # look through. The fancy awk is used instead of a "sort | uniq -c"
    # to preserve the order in which we find the lines in a specific
    # log file.
    grep -i deprecat $BASE/logs/*.log $BASE/logs/apache/*.log | \
        sed -r 's/[0-9]{1,2}\:[0-9]{1,2}\:[0-9]{1,2}\.[0-9]{1,3}/ /g' | \
        sed -r 's/[0-9]{1,2}\:[0-9]{1,2}\:[0-9]{1,2}/ /g' | \
        sed -r 's/[0-9]{1,4}-[0-9]{1,2}-[0-9]{1,4}/ /g' |
        sed -r 's/\[.*\]/ /g' | \
        sed -r 's/\s[0-9]+\s/ /g' | \
        awk '{if ($0 in seen) {seen[$0]++} else {out[++n]=$0;seen[$0]=1}} END { for (i=1; i<=n; i++) print seen[out[i]]" :: " out[i] }' > $BASE/logs/deprecations.log

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
    find $BASE/logs/{apache_config,etc,sudoers.d} -type f -exec mv '{}' '{}'.txt \;

    # rabbitmq
    if [ -f $BASE/logs/rabbitmq/ ]; then
        find $BASE/logs/rabbitmq -type f -exec mv '{}' '{}'.txt \;
        for X in `find $BASE/logs/rabbitmq -type f` ; do
            mv "$X" "${X/@/_at_}"
        done
    fi

    # final memory usage and process list
    ps -eo user,pid,ppid,lwp,%cpu,%mem,size,rss,cmd > $BASE/logs/ps.txt

    # Compress all text logs
    sudo find $BASE/logs -iname '*.txt' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.dat' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.conf' -execdir gzip -9 {} \+
    sudo find $BASE/logs -iname '*.journal' -execdir xz --threads=0 {} \+

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
    local gw_mac=$(arp -n $default_gw | grep $default_gw | awk '{print $3}')
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
        echo "Unsupported platform, can't determine openvswitch service"
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
    # neutron uses 1:1000 with default devstack configuration, avoid overlap
    local additional_vni_offset=1000000
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
    sudo ip link set dev $bridge_name up
    for node_ip in $peer_ips; do
        offset=$(( offset+1 ))
        vni=$(( offset + additional_vni_offset ))
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
            options:key=${vni} \
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
            options:key=${vni} \
            options:local_ip=${node_ip}
        if [[ "$set_ips" == "True" ]] ; then
            if ! remote_command $node_ip sudo ip addr show dev ${bridge_name} | \
                grep -q ${pub_addr_prefix}.${offset}/${pub_addr_mask} ; then
                    remote_command $node_ip sudo ip addr add \
                        ${pub_addr_prefix}.${offset}/${pub_addr_mask} \
                        dev ${bridge_name}
            fi
        fi
        remote_command $node_ip sudo ip link set dev $bridge_name up
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

# Iniget imported from devstack
function iniget {
    $(source $BASE/new/devstack/inc/ini-config; iniget $@)
}
