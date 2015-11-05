#!/bin/bash

# Gate commits to several projects on a VM running those projects
# configured by devstack.

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

# Most of the work of this script is done in functions so that we may
# easily redirect their stdout / stderr to log files.

GIT_BASE=${GIT_BASE:-https://git.openstack.org}
GIT_BRANCH=${GIT_BRANCH:-master}

# sshd may have been compiled with a default path excluding */sbin
export PATH=$PATH:/usr/local/sbin:/usr/sbin

source $WORKSPACE/devstack-gate/functions.sh

start_timer

PROJECTS="openstack-infra/devstack-gate $PROJECTS"
PROJECTS="openstack-dev/devstack $PROJECTS"
PROJECTS="openstack-dev/grenade $PROJECTS"
PROJECTS="openstack-dev/pbr $PROJECTS"
PROJECTS="openstack-infra/tripleo-ci $PROJECTS"
PROJECTS="openstack/automaton $PROJECTS"
PROJECTS="openstack/ceilometer $PROJECTS"
PROJECTS="openstack/ceilometermiddleware $PROJECTS"
PROJECTS="openstack/cinder $PROJECTS"
PROJECTS="openstack/cliff $PROJECTS"
PROJECTS="openstack/debtcollector $PROJECTS"
PROJECTS="openstack/dib-utils $PROJECTS"
PROJECTS="openstack/diskimage-builder $PROJECTS"
PROJECTS="openstack/django_openstack_auth $PROJECTS"
PROJECTS="openstack/futurist $PROJECTS"
PROJECTS="openstack/glance $PROJECTS"
PROJECTS="openstack/glance_store $PROJECTS"
PROJECTS="openstack/heat $PROJECTS"
PROJECTS="openstack/heat-cfntools $PROJECTS"
PROJECTS="openstack/heat-templates $PROJECTS"
PROJECTS="openstack/horizon $PROJECTS"
PROJECTS="openstack/ironic $PROJECTS"
PROJECTS="openstack/ironic-lib $PROJECTS"
PROJECTS="openstack/ironic-python-agent $PROJECTS"
PROJECTS="openstack/keystone $PROJECTS"
PROJECTS="openstack/keystoneauth $PROJECTS"
PROJECTS="openstack/keystonemiddleware $PROJECTS"
PROJECTS="openstack/manila $PROJECTS"
PROJECTS="openstack/manila-ui $PROJECTS"
PROJECTS="openstack/zaqar $PROJECTS"
PROJECTS="openstack/neutron $PROJECTS"
PROJECTS="openstack/neutron-fwaas $PROJECTS"
PROJECTS="openstack/neutron-lbaas $PROJECTS"
PROJECTS="openstack/octavia $PROJECTS"
PROJECTS="openstack/neutron-vpnaas $PROJECTS"
PROJECTS="openstack/nova $PROJECTS"
PROJECTS="openstack/os-apply-config $PROJECTS"
PROJECTS="openstack/os-brick $PROJECTS"
PROJECTS="openstack/os-cloud-config $PROJECTS"
PROJECTS="openstack/os-collect-config $PROJECTS"
PROJECTS="openstack/os-net-config $PROJECTS"
PROJECTS="openstack/os-refresh-config $PROJECTS"
PROJECTS="openstack/oslo.cache $PROJECTS"
PROJECTS="openstack/oslo.concurrency $PROJECTS"
PROJECTS="openstack/oslo.config $PROJECTS"
PROJECTS="openstack/oslo.context $PROJECTS"
PROJECTS="openstack/oslo.db $PROJECTS"
PROJECTS="openstack/oslo.i18n $PROJECTS"
PROJECTS="openstack/oslo.log $PROJECTS"
PROJECTS="openstack/oslo.messaging $PROJECTS"
PROJECTS="openstack/oslo.middleware $PROJECTS"
PROJECTS="openstack/oslo.policy $PROJECTS"
PROJECTS="openstack/oslo.reports $PROJECTS"
PROJECTS="openstack/oslo.rootwrap $PROJECTS"
PROJECTS="openstack/oslo.utils $PROJECTS"
PROJECTS="openstack/oslo.serialization $PROJECTS"
PROJECTS="openstack/oslo.service $PROJECTS"
PROJECTS="openstack/oslo.versionedobjects $PROJECTS"
PROJECTS="openstack/oslo.vmware $PROJECTS"
PROJECTS="openstack/pycadf $PROJECTS"
PROJECTS="openstack/python-ceilometerclient $PROJECTS"
PROJECTS="openstack/python-cinderclient $PROJECTS"
PROJECTS="openstack/python-glanceclient $PROJECTS"
PROJECTS="openstack/python-heatclient $PROJECTS"
PROJECTS="openstack/python-ironicclient $PROJECTS"
PROJECTS="openstack/python-keystoneclient $PROJECTS"
PROJECTS="openstack/python-manilaclient $PROJECTS"
PROJECTS="openstack/python-zaqarclient $PROJECTS"
PROJECTS="openstack/python-neutronclient $PROJECTS"
PROJECTS="openstack/python-novaclient $PROJECTS"
PROJECTS="openstack/python-openstackclient $PROJECTS"
PROJECTS="openstack/python-saharaclient $PROJECTS"
PROJECTS="openstack/python-swiftclient $PROJECTS"
PROJECTS="openstack/python-troveclient $PROJECTS"
PROJECTS="openstack/requirements $PROJECTS"
PROJECTS="openstack/sahara $PROJECTS"
PROJECTS="openstack/sahara-dashboard $PROJECTS"
PROJECTS="openstack/stevedore $PROJECTS"
PROJECTS="openstack/swift $PROJECTS"
PROJECTS="openstack/taskflow $PROJECTS"
PROJECTS="openstack/tempest $PROJECTS"
PROJECTS="openstack/tempest-lib $PROJECTS"
PROJECTS="openstack/tooz $PROJECTS"
PROJECTS="openstack/tripleo-heat-templates $PROJECTS"
PROJECTS="openstack/tripleo-image-elements $PROJECTS"
PROJECTS="openstack/tripleo-incubator $PROJECTS"
PROJECTS="openstack/trove $PROJECTS"

# Remove duplicates as they result in errors when managing
# git state.
PROJECTS=$(echo $PROJECTS | tr '[:space:]' '\n' | sort -u)


export BASE=/opt/stack

# The URL from which to fetch ZUUL references
export ZUUL_URL=${ZUUL_URL:-http://zuul.openstack.org/p}

# The feature matrix to select devstack-gate components
export DEVSTACK_GATE_FEATURE_MATRIX=${DEVSTACK_GATE_FEATURE_MATRIX:-features.yaml}

# Set to 1 to install, configure and enable the Tempest test suite; more flags may be
# required to be set to customize the test run, e.g. DEVSTACK_GATE_TEMPEST_STRESS=1
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Set to 1, in conjunction with DEVSTACK_GATE_TEMPEST, will allow Tempest to be
# installed and configured, but the tests will be skipped
export DEVSTACK_GATE_TEMPEST_NOTESTS=${DEVSTACK_GATE_TEMPEST_NOTESTS:-0}

# Set to 1 to run the devstack exercises
export DEVSTACK_GATE_EXERCISES=${DEVSTACK_GATE_EXERCISES:-0}

# Set to 1 to run postgresql instead of mysql
export DEVSTACK_GATE_POSTGRES=${DEVSTACK_GATE_POSTGRES:-0}

# Set to 1 to use zeromq instead of rabbitmq (or qpid)
export DEVSTACK_GATE_ZEROMQ=${DEVSTACK_GATE_ZEROMQ:-0}

# Set to qpid to use qpid, or zeromq to use zeromq.
# Default set to rabbitmq
export DEVSTACK_GATE_MQ_DRIVER=${DEVSTACK_GATE_MQ_DRIVER:-"rabbitmq"}

# Set to 1 to run tempest stress tests
export DEVSTACK_GATE_TEMPEST_STRESS=${DEVSTACK_GATE_TEMPEST_STRESS:-0}

# This value must be provided when DEVSTACK_GATE_TEMPEST_STRESS is set.
export DEVSTACK_GATE_TEMPEST_STRESS_ARGS=${DEVSTACK_GATE_TEMPEST_STRESS_ARGS:-""}

# Set to 1 to run tempest heat slow tests
export DEVSTACK_GATE_TEMPEST_HEAT_SLOW=${DEVSTACK_GATE_TEMPEST_HEAT_SLOW:-0}

# Set to 1 to run tempest large ops test
export DEVSTACK_GATE_TEMPEST_LARGE_OPS=${DEVSTACK_GATE_TEMPEST_LARGE_OPS:-0}

# Set to 1 to run tempest smoke tests serially
export DEVSTACK_GATE_SMOKE_SERIAL=${DEVSTACK_GATE_SMOKE_SERIAL:-0}

# Set to 1 to explicitly disable tempest tenant isolation. Otherwise tenant isolation setting
# for tempest will be the one chosen by devstack.
export DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION=${DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION:-0}

# Set to 1 to enable Cinder secure delete.
# False by default to avoid dd problems on Precise.
# https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1023755
export DEVSTACK_CINDER_SECURE_DELETE=${DEVSTACK_CINDER_SECURE_DELETE:-0}

# Set to 1 to run neutron instead of nova network
# Only applicable to master branch
export DEVSTACK_GATE_NEUTRON=${DEVSTACK_GATE_NEUTRON:-0}

# Set to 1 to run neutron distributed virtual routing
export DEVSTACK_GATE_NEUTRON_DVR=${DEVSTACK_GATE_NEUTRON_DVR:-0}

# Set to 1 to run nova in cells mode instead of the default mode
export DEVSTACK_GATE_CELLS=${DEVSTACK_GATE_CELLS:-0}

# Set to 1 to run nova in with nova metadata server as a separate binary
export DEVSTACK_GATE_NOVA_API_METADATA_SPLIT=${DEVSTACK_GATE_NOVA_API_METADATA_SPLIT:-0}

# Set to 1 to run ironic baremetal provisioning service.
export DEVSTACK_GATE_IRONIC=${DEVSTACK_GATE_IRONIC:-0}

# Set to "agent_ssh" to run ironic with the ironic-python-agent driver
export DEVSTACK_GATE_IRONIC_DRIVER=${DEVSTACK_GATE_IRONIC_DRIVER:-pxe_ssh}

# Set to 0 to avoid building Ironic deploy ramdisks
export DEVSTACK_GATE_IRONIC_BUILD_RAMDISK=${DEVSTACK_GATE_IRONIC_BUILD_RAMDISK:-1}

# Set to 1 to run sahara
export DEVSTACK_GATE_SAHARA=${DEVSTACK_GATE_SAHARA:-0}

# Set to 1 to run trove
export DEVSTACK_GATE_TROVE=${DEVSTACK_GATE_TROVE:-0}

# Set to 0 to disable config_drive and use the metadata server instead
export DEVSTACK_GATE_CONFIGDRIVE=${DEVSTACK_GATE_CONFIGDRIVE:-1}

# Set to 1 to enable installing test requirements
export DEVSTACK_GATE_INSTALL_TESTONLY=${DEVSTACK_GATE_INSTALL_TESTONLY:-0}

# Set the number of threads to run tempest with
DEFAULT_CONCURRENCY=$(nproc)
if [ ${DEFAULT_CONCURRENCY} -gt 3 ] ; then
    DEFAULT_CONCURRENCY=$((${DEFAULT_CONCURRENCY} / 2))
fi
export TEMPEST_CONCURRENCY=${TEMPEST_CONCURRENCY:-${DEFAULT_CONCURRENCY}}

# are we pulling any libraries from git
export DEVSTACK_PROJECT_FROM_GIT=${DEVSTACK_PROJECT_FROM_GIT:-}

# The following variable is set for different directions of Grenade updating
# for a stable branch we want to both try to upgrade forward n => n+1 as
# well as upgrade from last n-1 => n.
#
# i.e. stable/juno:
#   pullup means stable/icehouse => stable/juno
#   forward means stable/juno => master (or stable/kilo if that's out)
#   partial-ncpu means stable/icehouse => stable/juno but keep nova
#       compute at stable/icehouse
#   partial-ironic means stable/icehouse => stable/juno but keep ironic
#       compute at stable/icehouse
#   sideways-ironic means stable/juno with nova baremetal =>
#       stable/juno with ironic
#   sideways-neutron means stable/juno with nova network =>
#       stable/juno with neutron
export DEVSTACK_GATE_GRENADE=${DEVSTACK_GATE_GRENADE:-}

# the branch name for selecting grenade branches
GRENADE_BASE_BRANCH=${OVERRIDE_ZUUL_BRANCH:-${ZUUL_BRANCH}}


if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
    # All grenade upgrades get tempest
    export DEVSTACK_GATE_TEMPEST=1

    # NOTE(sdague): Adjusting grenade branches for a release.
    #
    # When we get to the point of the release where we should adjust
    # the grenade branches, the order of doing so is important.
    #
    # 1. stable/foo on all projects in devstack
    # 2. stable/foo on devstack
    # 3. stable/foo on grenade
    # 4. adjust branches in devstack-gate
    #
    # The devstack-gate branch logic going last means that it will be
    # tested before thrust upon the jobs. For both the stable/kilo and
    # stable/liberty releases real release issues were found in this
    # process. So this should be done as early as possible.

    case $DEVSTACK_GATE_GRENADE in

        # sideways upgrades try to move between configurations in the
        # same release, typically used for migrating between services
        # or configurations.
        sideways-*)
            export GRENADE_OLD_BRANCH="$GRENADE_BASE_BRANCH"
            export GRENADE_NEW_BRANCH="$GRENADE_BASE_BRANCH"
            ;;

        # forward upgrades are an attempt to migrate up from an
        # existing stable branch to the next release.
        forward)
            if [[ "$GRENADE_BASE_BRANCH" == "stable/icehouse" ]]; then
                export GRENADE_OLD_BRANCH="stable/icehouse"
                export GRENADE_NEW_BRANCH="stable/juno"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/juno" ]]; then
                export GRENADE_OLD_BRANCH="stable/juno"
                export GRENADE_NEW_BRANCH="stable/kilo"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/kilo" ]]; then
                export GRENADE_OLD_BRANCH="stable/kilo"
                export GRENADE_NEW_BRANCH="stable/liberty"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/liberty" ]]; then
                export GRENADE_OLD_BRANCH="stable/liberty"
                export GRENADE_NEW_BRANCH="$GIT_BRANCH"
            fi
            ;;

        # partial upgrades are like normal upgrades except they leave
        # certain services behind. We use the base 4 operator ';&'
        # here to fall trhough to the next conditionals
        partial-*)
            if [[ "$DEVSTACK_GATE_GRENADE" == "partial-ncpu" ]]; then
                export DO_NOT_UPGRADE_SERVICES=[n-cpu]
            elif [[ "$DEVSTACK_GATE_GRENADE" == "partial-ironic" ]]; then
                export DO_NOT_UPGRADE_SERVICES=[ir-api,ir-cond]
            fi
            ;&

        # pullup upgrades are our normal upgrade test. Can you upgrade
        # to the current patch from the last stable.
        pullup)
            if [[ "$GRENADE_BASE_BRANCH" == "stable/juno" ]]; then
                export GRENADE_OLD_BRANCH="stable/icehouse"
                export GRENADE_NEW_BRANCH="stable/juno"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/kilo" ]]; then
                export GRENADE_OLD_BRANCH="stable/juno"
                export GRENADE_NEW_BRANCH="stable/kilo"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/liberty" ]]; then
                export GRENADE_OLD_BRANCH="stable/kilo"
                export GRENADE_NEW_BRANCH="stable/liberty"
            else # master
                export GRENADE_OLD_BRANCH="stable/liberty"
                export GRENADE_NEW_BRANCH="$GIT_BRANCH"
            fi
            ;;

        # If we got here, someone typoed a thing, and we should fail
        # explicitly so they don't accidentally pass in some what that
        # is unexpected.
        *)
            echo "Unsupported upgrade mode: $DEVSTACK_GATE_GRENADE"
            exit 1
            ;;
    esac
fi

# Set the virtualization driver to: libvirt, openvz, xenapi
export DEVSTACK_GATE_VIRT_DRIVER=${DEVSTACK_GATE_VIRT_DRIVER:-libvirt}

# See switch below for this -- it gets set to 1 when tempest
# is the project being gated.
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}

# Set to 1 to run all tempest tests
export DEVSTACK_GATE_TEMPEST_ALL=${DEVSTACK_GATE_TEMPEST_ALL:-0}

# Set to a regex to run tempest with a custom regex filter
export DEVSTACK_GATE_TEMPEST_REGEX=${DEVSTACK_GATE_TEMPEST_REGEX:-""}

# Set to 1 to run all-plugin tempest tests
export DEVSTACK_GATE_TEMPEST_ALL_PLUGINS=${DEVSTACK_GATE_TEMPEST_ALL_PLUGINS:-0}

# Set to 1 if running the openstack/requirements integration test
export DEVSTACK_GATE_REQS_INTEGRATION=${DEVSTACK_GATE_REQS_INTEGRATION:-0}

# Set to 1 if running the project is using libraries not specified
# in global requirements
export REQUIREMENTS_MODE=${REQUIREMENTS_MODE:-strict}

# Set to False to disable USE_CONSTRAINTS and run without known-good test pins.
export USE_CONSTRAINTS=${USE_CONSTRAINTS:-True}

# Set to 0 to disable clean logs enforcement (3rd party CI might want to do this
# until they get their driver cleaned up)
export DEVSTACK_GATE_CLEAN_LOGS=${DEVSTACK_GATE_CLEAN_LOGS:-1}

# Set this to the time in minutes that the gate test should be allowed
# to run before being aborted (default 60).
export DEVSTACK_GATE_TIMEOUT=${DEVSTACK_GATE_TIMEOUT:-60}

# Set to 1 to remove the stack users blanket sudo permissions forcing
# openstack services running as the stack user to rely on rootwrap rulesets
# instead of raw sudo. Do this to ensure rootwrap works. This is the default.
export DEVSTACK_GATE_REMOVE_STACK_SUDO=${DEVSTACK_GATE_REMOVE_STACK_SUDO:-1}

# Set to 1 to unstack immediately after devstack installation.  This
# is intended to be a stop-gap until devstack can support
# dependency-only installation.
export DEVSTACK_GATE_UNSTACK=${DEVSTACK_GATE_UNSTACK:-0}

# Set this to override the branch selected for testing (in
# single-branch checkouts; not used for grenade)
export OVERRIDE_ZUUL_BRANCH=${OVERRIDE_ZUUL_BRANCH:-$ZUUL_BRANCH}

# Set Ceilometer backend to override the default one. It could be mysql,
# postgresql, mongodb.
export DEVSTACK_GATE_CEILOMETER_BACKEND=${DEVSTACK_GATE_CEILOMETER_BACKEND:-mysql}

# The topology of the system determinates the service distribution
# among the nodes.
# aio: `all in one` just only one node used
# aiopcpu: `all in one plus compute` one node will be installed as aio
# the extra nodes will gets only limited set of services
# ctrlpcpu: `controller plus compute` One node will gets the controller type
# services without the compute type of services, the others gets,
# the compute style services several services can be common,
# the networking services also presents on the controller [WIP]
export DEVSTACK_GATE_TOPOLOGY=${DEVSTACK_GATE_TOPOLOGY:-aio}

# Set to a space-separated list of projects to prepare in the
# workspace, e.g. 'openstack-dev/devstack openstack/neutron'.
# Minimizing the number of targeted projects can reduce the setup cost
# for jobs that know exactly which repos they need.
export DEVSTACK_GATE_PROJECTS_OVERRIDE=${DEVSTACK_GATE_PROJECTS_OVERRIDE:-""}

# Set this to enable remote logging of the console via UDP packets to
# a specified ipv4 ip:port (note; not hostname -- ip address only).
# This can be extremely useful if a host is oopsing or dropping off
# the network amd you are not getting any useful logs from jenkins.
#
# To capture these logs, enable a netcat/socat type listener to
# capture UDP packets at the specified remote ip.  For example:
#
#  $ nc -v -u -l -p 6666 | tee save-output.log
# or
#  $ socat udp-recv:6666 - | tee save-output.log
#
# One further trick is to send interesting data to /dev/ksmg; this
# data will get out over the netconsole even if the main interfaces
# have been disabled, etc.  e.g.
#
#  $ ip addr | sudo tee /dev/ksmg
#
export DEVSTACK_GATE_NETCONSOLE=${DEVSTACK_GATE_NETCONSOLE:-""}
enable_netconsole

if [ -n "$DEVSTACK_GATE_PROJECTS_OVERRIDE" ]; then
    PROJECTS=$DEVSTACK_GATE_PROJECTS_OVERRIDE
fi

if ! function_exists "gate_hook"; then
    # the command we use to run the gate
    function gate_hook {
        $BASE/new/devstack-gate/devstack-vm-gate.sh
    }
    export -f gate_hook
fi

echo "Triggered by: https://review.openstack.org/$ZUUL_CHANGE patchset $ZUUL_PATCHSET"
echo "Pipeline: $ZUUL_PIPELINE"
echo "Available disk space on this host:"
indent df -h

# Enable tracing while we transition to using ansible to run
# setup across multiple nodes.
set -x
# Install ansible
sudo -H pip install virtualenv
virtualenv /tmp/ansible
/tmp/ansible/bin/pip install ansible
export ANSIBLE=/tmp/ansible/bin/ansible

# Write inventory file with groupings
COUNTER=1
echo "[primary]" > "$WORKSPACE/inventory"
echo "localhost ansible_connection=local host_counter=$COUNTER" >> "$WORKSPACE/inventory"
echo "[subnodes]" >> "$WORKSPACE/inventory"
SUBNODES=$(cat /etc/nodepool/sub_nodes_private)
for SUBNODE in $SUBNODES ; do
    let COUNTER=COUNTER+1
    echo "$SUBNODE host_counter=$COUNTER" >> "$WORKSPACE/inventory"
done

# NOTE(clarkb): for simplicity we evaluate all bash vars in ansible commands
# on the node running these scripts, we do not pass through unexpanded
# vars to ansible shell commands. This may need to change in the future but
# for now the current setup is simple, consistent and easy to understand.

# Copy bootstrap to remote hosts
# It is in brackets for avoiding inheriting a huge environment variable
(export PROJECTS; export > "$WORKSPACE/test_env.sh")
$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m copy \
    -a "src='$WORKSPACE/devstack-gate' dest='$WORKSPACE'"
$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m copy \
    -a "src='$WORKSPACE/test_env.sh' dest='$WORKSPACE/test_env.sh'"

# Make a directory to store logs
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m file \
    -a "path='$WORKSPACE/logs' state=absent"
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m file \
    -a "path='$WORKSPACE/logs' state=directory"

# Run ansible to do setup_host on all nodes.
echo "Setting up the hosts"

# little helper that runs anything passed in under tsfilter
function run_command {
    local fn="$@"
    local cmd=""

    # note that we want to keep the tsfilter separate; it's a trap for
    # new-players that errexit isn't applied if we do "&& tsfilter
    # ..."  and thus we won't pick up any failures in the commands the
    # function runs.
    read -r -d '' cmd <<EOF
source '$WORKSPACE/test_env.sh'
source '$WORKSPACE/devstack-gate/functions.sh'
set -o errexit
tsfilter $fn
executable=/bin/bash
EOF

    echo "$cmd"
}

echo "... this takes a few seconds (logs at logs/devstack-gate-setup-host.txt.gz)"
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
    -a "$(run_command setup_host)" &> "$WORKSPACE/logs/devstack-gate-setup-host.txt"

if [ -n "$DEVSTACK_GATE_GRENADE" ]; then
    start=$(date +%s)
    echo "Setting up the new (migrate to) workspace"
    echo "... this takes 3 - 5 minutes (logs at logs/devstack-gate-setup-workspace-new.txt.gz)"
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
             -a "$(run_command setup_workspace '$GRENADE_NEW_BRANCH' '$BASE/new')" \
        &> "$WORKSPACE/logs/devstack-gate-setup-workspace-new.txt"
    echo "Setting up the old (migrate from) workspace ..."
    echo "... this takes 3 - 5 minutes (logs at logs/devstack-gate-setup-workspace-old.txt.gz)"
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "$(run_command setup_workspace '$GRENADE_OLD_BRANCH' '$BASE/old')" \
        &> "$WORKSPACE/logs/devstack-gate-setup-workspace-old.txt"
    end=$(date +%s)
    took=$((($end - $start) / 60))
    if [[ "$took" -gt 20 ]]; then
        echo "WARNING: setup of 2 workspaces took > 20 minutes, this is a very slow node."
    fi
else
    echo "Setting up the workspace"
    echo "... this takes 3 - 5 minutes (logs at logs/devstack-gate-setup-workspace-new.txt.gz)"
    start=$(date +%s)
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "$(run_command setup_workspace '$OVERRIDE_ZUUL_BRANCH' '$BASE/new')" \
        &> "$WORKSPACE/logs/devstack-gate-setup-workspace-new.txt"
    end=$(date +%s)
    took=$((($end - $start) / 60))
    if [[ "$took" -gt 10 ]]; then
        echo "WARNING: setup workspace took > 10 minutes, this is a very slow node."
    fi
fi

# relocate and symlink logs into $BASE to save space on the root filesystem
# TODO: make this more ansibley
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell -a "
if [ -d '$WORKSPACE/logs' -a \! -e '$BASE/logs' ]; then
    sudo mv '$WORKSPACE/logs' '$BASE/'
    ln -s '$BASE/logs' '$WORKSPACE/'
fi executable=/bin/bash"

# The DEVSTACK_GATE_SETTINGS variable may contain a path to a script that
# should be sourced after the environment has been set up.  This is useful for
# allowing projects to provide a script in their repo that sets some custom
# environment variables.
if [ -n "${DEVSTACK_GATE_SETTINGS}" ] ; then
    if [ -f "${DEVSTACK_GATE_SETTINGS}" ] ; then
        source ${DEVSTACK_GATE_SETTINGS}
    else
        echo "WARNING: DEVSTACK_GATE_SETTINGS file does not exist: '${DEVSTACK_GATE_SETTINGS}'"
    fi
fi

# Note that hooks should be multihost aware if necessary.
# devstack-vm-gate-wrap.sh will not automagically run the hooks on each node.
# Run pre test hook if we have one
with_timeout call_hook_if_defined "pre_test_hook"

# Run the gate function
echo "Running gate_hook"
with_timeout "gate_hook"
GATE_RETVAL=$?
RETVAL=$GATE_RETVAL

if [ $GATE_RETVAL -ne 0 ]; then
    echo "ERROR: the main setup script run by this job failed - exit code: $GATE_RETVAL"
    echo "    please look at the relevant log files to determine the root cause"
    echo "Running devstack worlddump.py"
    sudo $BASE/new/devstack/tools/worlddump.py -d $BASE/logs
fi

# Run post test hook if we have one
if [ $GATE_RETVAL -eq 0 ]; then
    # Run post_test_hook if we have one
    with_timeout call_hook_if_defined "post_test_hook"
    RETVAL=$?
fi

if [ $GATE_RETVAL -eq 137 ] && [ -f $WORKSPACE/gate.pid ] ; then
    echo "Job timed out"
    GATEPID=`cat $WORKSPACE/gate.pid`
    echo "Killing process group ${GATEPID}"
    sudo kill -s 9 -${GATEPID}
fi

echo "Cleaning up host"
echo "... this takes 3 - 4 minutes (logs at logs/devstack-gate-cleanup-host.txt.gz)"
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
    -a "$(run_command cleanup_host)" &> "$WORKSPACE/devstack-gate-cleanup-host.txt"
$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m synchronize \
    -a "mode=pull src='$BASE/logs/' dest='$BASE/logs/subnode-{{ host_counter }}'"
sudo mv $WORKSPACE/devstack-gate-cleanup-host.txt $BASE/logs/

exit $RETVAL
