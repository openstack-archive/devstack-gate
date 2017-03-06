#!/bin/bash

# Script that is run on the devstack vm; configures and
# invokes devstack.

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

set -o errexit
set -o xtrace

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Prepare the environment
# -----------------------

# Import common functions
source $TOP_DIR/functions.sh
# Get access to iniset and friends

# NOTE(sdague): as soon as we put
# iniget into dsconf, we can remove this.
source $BASE/new/devstack/inc/ini-config

# redefine localrc_set to use dsconf
function localrc_set {
    local lcfile=$1
    local key=$2
    local value=$3
    $DSCONF setlc "$1" "$2" "$3"
}

echo $PPID > $WORKSPACE/gate.pid
source `dirname "$(readlink -f "$0")"`/functions.sh

# Need to set FIXED_RANGE for pre-ocata devstack
FIXED_RANGE=${DEVSTACK_GATE_FIXED_RANGE:-10.1.0.0/20}
IPV4_ADDRS_SAFE_TO_USE=${DEVSTACK_GATE_IPV4_ADDRS_SAFE_TO_USE:-${DEVSTACK_GATE_FIXED_RANGE:-10.1.0.0/20}}
FLOATING_RANGE=${DEVSTACK_GATE_FLOATING_RANGE:-172.24.5.0/24}
PUBLIC_NETWORK_GATEWAY=${DEVSTACK_GATE_PUBLIC_NETWORK_GATEWAY:-172.24.5.1}
# The next two values are used in multinode testing and are related
# to the floating range. For multinode test envs to know how to route
# packets to floating IPs on other hosts we put addresses on the compute
# node interfaces on a network that overlaps the FLOATING_RANGE. This
# automagically sets up routing in a sane way. By default we put floating
# IPs on 172.24.5.0/24 and compute nodes get addresses in the 172.24.4/23
# space. Note that while the FLOATING_RANGE should overlap the
# FLOATING_HOST_* space you should have enough sequential room starting at
# the beginning of your FLOATING_HOST range to give one IP address to each
# compute host without letting compute host IPs run into the FLOATING_RANGE.
# By default this lets us have 255 compute hosts (172.24.4.1 - 172.24.4.255).
FLOATING_HOST_PREFIX=${DEVSTACK_GATE_FLOATING_HOST_PREFIX:-172.24.4}
FLOATING_HOST_MASK=${DEVSTACK_GATE_FLOATING_HOST_MASK:-23}

# Get the smallest local MTU
LOCAL_MTU=$(ip link show | sed -ne 's/.*mtu \([0-9]\+\).*/\1/p' | sort -n | head -1)
# 50 bytes is overhead for vxlan (which is greater than GRE
# allowing us to use either overlay option with this MTU.
EXTERNAL_BRIDGE_MTU=$((LOCAL_MTU - 50))

function setup_ssh {
    # Copy the SSH key from /etc/nodepool/id_rsa{.pub} to the specified
    # directory on 'all' the nodes. 'all' the nodes consists of the primary
    # node and all of the subnodes.
    local path=$1
    local dest_file=${2:-id_rsa}
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m file \
        -a "path='$path' mode=0700 state=directory"
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m copy \
        -a "src=/etc/nodepool/id_rsa.pub dest='$path/authorized_keys' mode=0600"
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m copy \
        -a "src=/etc/nodepool/id_rsa.pub dest='$path/${dest_file}.pub' mode=0600"
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m copy \
        -a "src=/etc/nodepool/id_rsa dest='$path/${dest_file}' mode=0400"
}

function setup_nova_net_networking {
    local localrc=$1
    local primary_node=$2
    shift 2
    local sub_nodes=$@
    # We always setup multinode connectivity to work around an
    # issue with nova net configuring br100 to take over eth0
    # by default.
    # TODO (clarkb): figure out how to make bridge setup sane with ansible.
    ovs_vxlan_bridge "br_pub" $primary_node "True" 1 \
                    $FLOATING_HOST_PREFIX $FLOATING_HOST_MASK \
                    $sub_nodes
    ovs_vxlan_bridge "br_flat" $primary_node "False" 128 \
                    $sub_nodes
    localrc_set $localrc "FLAT_INTERFACE" "br_flat"
    localrc_set $localrc "PUBLIC_INTERFACE" "br_pub"
}

function setup_multinode_connectivity {
    local mode=${1:-"devstack"}
    # Multinode setup variables:
    #
    # ``localrc`` - location to write localrc content on the primary
    # node. In grenade mode we write to the grenade template that is
    # copied into old and new.
    #
    # ``old_or_new`` - should the subnodes be computed on the old side
    # or new side. For grenade where we don't upgrade them, calculate
    # on the old side.
    local old_or_new="new"
    local localconf
    local devstack_dir
    if [[ "$mode" == "grenade" ]]; then
        localconf=$BASE/new/grenade/devstack.localrc
        old_or_new="old"
        devstack_dir=$BASE/$old_or_new/devstack
    else
        devstack_dir=$BASE/$old_or_new/devstack
        localconf=$devstack_dir/local.conf
    fi
    # set explicit paths on all conf files we're writing so that
    # current working directory doesn't introduce subtle bugs.
    local sub_localconf=$devstack_dir/sub_local.conf

    set -x  # for now enabling debug and do not turn it off
    setup_localrc $old_or_new "$sub_localconf" "sub"

    local primary_node
    primary_node=$(cat /etc/nodepool/primary_node_private)
    local sub_nodes
    sub_nodes=$(cat /etc/nodepool/sub_nodes_private)
    if [[ "$DEVSTACK_GATE_NEUTRON" -ne '1' ]]; then
        setup_nova_net_networking $localconf $primary_node $sub_nodes
        localrc_set $sub_localconf "FLAT_INTERFACE" "br_flat"
        localrc_set $sub_localconf "PUBLIC_INTERFACE" "br_pub"
        localrc_set $sub_localconf "MULTI_HOST" "True"
        # and on the master
        localrc_set $localconf "MULTI_HOST" "True"
    elif [[ "$DEVSTACK_GATE_NEUTRON_DVR" -eq '1' ]]; then
        ovs_vxlan_bridge "br-ex" $primary_node "True" 1 \
                        $FLOATING_HOST_PREFIX $FLOATING_HOST_MASK \
                        $sub_nodes
    fi

    if [[ "$DEVSTACK_GATE_IRONIC" -eq '1' ]]; then
        # NOTE(vsaienko) Ironic VMs will be connected to this bridge
        # in order to have access to VMs on another nodes.
        ovs_vxlan_bridge "br_ironic_vxlan" $primary_node "False" 128 \
            $sub_nodes

        localrc_set "$sub_localconf" "HOST_TOPOLOGY" "multinode"
        localrc_set "$sub_localconf" "HOST_TOPOLOGY_ROLE" "subnode"
        # NOTE(vsaienko) we assume for now that we using only 1 subnode,
        # each subnode should have different switch name (bridge) as it is used
        # by networking-generic-switch to uniquely identify switch.
        localrc_set "$sub_localconf" "IRONIC_VM_NETWORK_BRIDGE" "sub1brbm"
        localrc_set "$sub_localconf" "OVS_PHYSICAL_BRIDGE" "sub1brbm"
        localrc_set "$sub_localconf" "ENABLE_TENANT_TUNNELS" "False"
        localrc_set "$sub_localconf" "IRONIC_KEY_FILE" "$BASE/new/.ssh/ironic_key"

        localrc_set "$localconf" "HOST_TOPOLOGY" "multinode"
        localrc_set "$localconf" "HOST_TOPOLOGY_ROLE" "primary"
        localrc_set "$localconf" "HOST_TOPOLOGY_SUBNODES" "$sub_nodes"
        localrc_set "$localconf" "IRONIC_KEY_FILE" "$BASE/new/.ssh/ironic_key"
        localrc_set "$localconf" "GENERIC_SWITCH_KEY_FILE" "$BASE/new/.ssh/ironic_key"
        localrc_set "$localconf" "ENABLE_TENANT_TUNNELS" "False"
    fi

    echo "Preparing cross node connectivity"
    setup_ssh $BASE/new/.ssh
    setup_ssh ~root/.ssh
    # TODO (clarkb) ansiblify the /etc/hosts and known_hosts changes
    # set up ssh_known_hosts by IP and /etc/hosts
    for NODE in $sub_nodes; do
        ssh-keyscan $NODE >> /tmp/tmp_ssh_known_hosts
        echo $NODE `remote_command $NODE hostname | tr -d '\r'` >> /tmp/tmp_hosts
    done
    ssh-keyscan `cat /etc/nodepool/primary_node_private` >> /tmp/tmp_ssh_known_hosts
    echo `cat /etc/nodepool/primary_node_private` `hostname` >> /tmp/tmp_hosts
    cat /tmp/tmp_hosts | sudo tee --append /etc/hosts

    # set up ssh_known_host files based on hostname
    for HOSTNAME in `cat /tmp/tmp_hosts | cut -d' ' -f2`; do
        ssh-keyscan $HOSTNAME >> /tmp/tmp_ssh_known_hosts
    done

    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m copy \
            -a "src=/tmp/tmp_ssh_known_hosts dest=/etc/ssh/ssh_known_hosts mode=0444"

    for NODE in $sub_nodes; do
        remote_copy_file /tmp/tmp_hosts $NODE:/tmp/tmp_hosts
        remote_command $NODE "cat /tmp/tmp_hosts | sudo tee --append /etc/hosts > /dev/null"
        cp $sub_localconf /tmp/tmp_sub_localconf
        localrc_set /tmp/tmp_sub_localconf "HOST_IP" "$NODE"
        remote_copy_file /tmp/tmp_sub_localconf $NODE:$devstack_dir/local.conf
    done

    # NOTE(vsaienko) we need to have ssh connection among nodes to manage
    # VMs from ironic-conductor or setup networking from networking-generic-switch
    if [[ "$DEVSTACK_GATE_IRONIC" -eq '1' ]]; then
        echo "Copy ironic key among nodes"
        # NOTE(vsaienko) setup_ssh() set 700 to all parent directories when they doesn't
        # exist. Keep ironic keys in other directory than /opt/stack/data to avoid setting
        # 700 on /opt/stack/data
        setup_ssh $BASE/new/.ssh ironic_key
    fi
}

function setup_networking {
    local mode=${1:-"devstack"}
    # Neutron in single node setups does not need any special
    # sauce to function.
    if [[ "$DEVSTACK_GATE_TOPOLOGY" != "multinode" ]] && \
        [[ "$DEVSTACK_GATE_NEUTRON" -ne '1' ]]; then
        if [[ "$mode" == "grenade" ]]; then
            setup_nova_net_networking "$BASE/new/grenade/devstack.local.conf.base" "127.0.0.1"
            setup_nova_net_networking "$BASE/new/grenade/devstack.local.conf.target" "127.0.0.1"
        else
            setup_nova_net_networking "$BASE/new/devstack/local.conf" "127.0.0.1"
        fi
    elif [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]]; then
        setup_multinode_connectivity $mode
    fi
}

# Discovers compute nodes (subnodes) and maps them to cells.
# NOTE(mriedem): We want to remove this if/when nova supports auto-registration
# of computes with cells, but that's not happening in Ocata.
function discover_hosts {
    # We have to run this on the primary node AFTER the subnodes have been
    # setup. Since discover_hosts is really only needed for Ocata, this checks
    # to see if the script exists in the devstack installation first.
    # NOTE(danms): This is ||'d with an assertion that the script does not exist,
    # so that if we actually failed the script, we'll exit nonzero here instead
    # of ignoring failures along with the case where there is no script.
    # TODO(mriedem): Would be nice to do this with wrapped lines.
    $ANSIBLE primary -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd $BASE/new/devstack/ && (test -f tools/discover_hosts.sh && sudo -H -u stack DSTOOLS_VERSION=$DSTOOLS_VERSION stdbuf -oL -eL ./tools/discover_hosts.sh) || (! test -f tools/discover_hosts.sh)" \
        &> "$WORKSPACE/logs/devstack-gate-discover-hosts.txt"
}

function setup_localrc {
    local localrc_oldnew=$1;
    local localrc_file=$2
    local role=$3

    # The branch we use to compute the feature matrix is pretty
    # straight forward. If it's a GRENADE job, we use the
    # GRENADE_OLD_BRANCH, otherwise the branch ZUUL has told is it's
    # running on.
    local branch_for_matrix=${GRENADE_OLD_BRANCH:-$OVERRIDE_ZUUL_BRANCH}

    # Allow calling context to pre-populate the localrc file
    # with additional values
    if [[ -z $KEEP_LOCALRC ]] ; then
        rm -f $localrc_file
    fi

    # are we being explicit or additive?
    if [[ ! -z $OVERRIDE_ENABLED_SERVICES ]]; then
        MY_ENABLED_SERVICES=${OVERRIDE_ENABLED_SERVICES}
    else
        # Install PyYaml for test-matrix.py
        if uses_debs; then
            if ! dpkg -s python-yaml > /dev/null; then
                apt_get_install python-yaml
            fi
        elif is_fedora; then
            if ! rpm --quiet -q "PyYAML"; then
                sudo yum install -y PyYAML
            fi
        fi

        local test_matrix_role='primary'
        if [[ $role = sub ]]; then
            test_matrix_role='subnode'
        fi

        MY_ENABLED_SERVICES=$(cd $BASE/new/devstack-gate && ./test-matrix.py -b $branch_for_matrix -f $DEVSTACK_GATE_FEATURE_MATRIX -r $test_matrix_role)
        local original_enabled_services=$(cd $BASE/new/devstack-gate && ./test-matrix.py -b $branch_for_matrix -f $DEVSTACK_GATE_FEATURE_MATRIX -r primary)
        echo "MY_ENABLED_SERVICES: ${MY_ENABLED_SERVICES}"
        echo "original_enabled_services: ${original_enabled_services}"

        # Allow optional injection of ENABLED_SERVICES from the calling context
        if [[ ! -z $ENABLED_SERVICES ]] ; then
            MY_ENABLED_SERVICES+=,$ENABLED_SERVICES
        fi
    fi

    if [[ ! -z $DEVSTACK_GATE_USE_PYTHON3 ]] ; then
        localrc_set $localrc_file "USE_PYTHON3" "$DEVSTACK_GATE_USE_PYTHON3"
    fi

    if [[ "$DEVSTACK_GATE_CEPH" == "1" ]]; then
        localrc_set $localrc_file "CINDER_ENABLED_BACKENDS" "ceph:ceph"
        localrc_set $localrc_file "TEMPEST_STORAGE_PROTOCOL" "ceph"
    fi

    # the exercises we *don't* want to test on for devstack
    SKIP_EXERCISES=boot_from_volume,bundle,client-env,euca

    if [[ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]]; then
        localrc_set $localrc_file "Q_USE_DEBUG_COMMAND" "True"
        localrc_set $localrc_file "NETWORK_GATEWAY" "10.1.0.1"
    fi

    if [[ "$DEVSTACK_GATE_NEUTRON_DVR" -eq "1" ]]; then
        if [[ "$DEVSTACK_GATE_TOPOLOGY" != "aio" ]] && [[ $role = sub ]]; then
            # The role for L3 agents running on compute nodes is 'dvr'
            localrc_set $localrc_file "Q_DVR_MODE" "dvr"
        else
            # The role for L3 agents running on controller nodes is 'dvr_snat'
            localrc_set $localrc_file "Q_DVR_MODE" "dvr_snat"
        fi
    fi

    localrc_set "$localrc_file" "USE_SCREEN" "False"
    localrc_set "$localrc_file" "DEST" "$BASE/$localrc_oldnew"
    # move DATA_DIR outside of DEST to keep DEST a bit cleaner
    localrc_set "$localrc_file" "DATA_DIR" "$BASE/data"
    localrc_set "$localrc_file" "ACTIVE_TIMEOUT" "90"
    localrc_set "$localrc_file" "BOOT_TIMEOUT" "90"
    localrc_set "$localrc_file" "ASSOCIATE_TIMEOUT" "60"
    localrc_set "$localrc_file" "TERMINATE_TIMEOUT" "60"
    localrc_set "$localrc_file" "MYSQL_PASSWORD" "secretmysql"
    localrc_set "$localrc_file" "DATABASE_PASSWORD" "secretdatabase"
    localrc_set "$localrc_file" "RABBIT_PASSWORD" "secretrabbit"
    localrc_set "$localrc_file" "ADMIN_PASSWORD" "secretadmin"
    localrc_set "$localrc_file" "SERVICE_PASSWORD" "secretservice"
    localrc_set "$localrc_file" "SERVICE_TOKEN" "111222333444"
    localrc_set "$localrc_file" "SWIFT_HASH" "1234123412341234"
    localrc_set "$localrc_file" "ROOTSLEEP" "0"
    # ERROR_ON_CLONE should never be set to FALSE in gate jobs.
    # Setting up git trees must be done by zuul
    # because it needs specific git references directly from gerrit
    # to correctly do testing. Otherwise you are not testing
    # the code you have posted for review.
    localrc_set "$localrc_file" "ERROR_ON_CLONE" "True"
    # Since git clone can't be used for novnc in gates, force it to install the packages
    localrc_set "$localrc_file" "NOVNC_FROM_PACKAGE" "True"
    localrc_set "$localrc_file" "ENABLED_SERVICES" "$MY_ENABLED_SERVICES"
    localrc_set "$localrc_file" "SKIP_EXERCISES" "$SKIP_EXERCISES"
    # Screen console logs will capture service logs.
    localrc_set "$localrc_file" "SYSLOG" "False"
    localrc_set "$localrc_file" "SCREEN_LOGDIR" "$BASE/$localrc_oldnew/screen-logs"
    localrc_set "$localrc_file" "LOGFILE" "$BASE/$localrc_oldnew/devstacklog.txt"
    localrc_set "$localrc_file" "VERBOSE" "True"
    localrc_set "$localrc_file" "FIXED_RANGE" "$FIXED_RANGE"
    localrc_set "$localrc_file" "IPV4_ADDRS_SAFE_TO_USE" "$IPV4_ADDRS_SAFE_TO_USE"
    localrc_set "$localrc_file" "FLOATING_RANGE" "$FLOATING_RANGE"
    localrc_set "$localrc_file" "PUBLIC_NETWORK_GATEWAY" "$PUBLIC_NETWORK_GATEWAY"
    localrc_set "$localrc_file" "FIXED_NETWORK_SIZE" "4096"
    localrc_set "$localrc_file" "VIRT_DRIVER" "$DEVSTACK_GATE_VIRT_DRIVER"
    localrc_set "$localrc_file" "SWIFT_REPLICAS" "1"
    localrc_set "$localrc_file" "LOG_COLOR" "False"
    # Don't reset the requirements.txt files after g-r updates
    localrc_set "$localrc_file" "UNDO_REQUIREMENTS" "False"
    localrc_set "$localrc_file" "CINDER_PERIODIC_INTERVAL" "10"
    localrc_set "$localrc_file" "export OS_NO_CACHE" "True"
    localrc_set "$localrc_file" "CEILOMETER_BACKEND" "$DEVSTACK_GATE_CEILOMETER_BACKEND"
    localrc_set "$localrc_file" "LIBS_FROM_GIT" "$DEVSTACK_PROJECT_FROM_GIT"
    # set this until all testing platforms have libvirt >= 1.2.11
    # see bug #1501558
    localrc_set "$localrc_file" "EBTABLES_RACE_FIX" "True"

    if [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]] && [[ $DEVSTACK_GATE_NEUTRON -eq "1" ]]; then
        # Reduce the MTU on br-ex to match the MTU of underlying tunnels
        localrc_set "$localrc_file" "PUBLIC_BRIDGE_MTU" "$EXTERNAL_BRIDGE_MTU"
    fi

    if [[ "$DEVSTACK_CINDER_SECURE_DELETE" -eq "0" ]]; then
        localrc_set "$localrc_file" "CINDER_SECURE_DELETE" "False"
    fi
    localrc_set "$localrc_file" "CINDER_VOLUME_CLEAR" "${DEVSTACK_CINDER_VOLUME_CLEAR}"

    if [[ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]]; then
        localrc_set "$localrc_file" "HEAT_CREATE_TEST_IMAGE" "False"
        # Use Fedora 20 for heat test image, it has heat-cfntools pre-installed
        localrc_set "$localrc_file" "HEAT_FETCHED_TEST_IMAGE" "Fedora-i386-20-20131211.1-sda"
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "libvirt" ]]; then
        if [[ -n "$DEVSTACK_GATE_LIBVIRT_TYPE" ]]; then
            localrc_set "$localrc_file" "LIBVIRT_TYPE" "${DEVSTACK_GATE_LIBVIRT_TYPE}"
        fi
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "ironic" ]]; then
        export TEMPEST_OS_TEST_TIMEOUT=${DEVSTACK_GATE_OS_TEST_TIMEOUT:-1200}
        localrc_set "$localrc_file" "IRONIC_DEPLOY_DRIVER" "$DEVSTACK_GATE_IRONIC_DRIVER"
        localrc_set "$localrc_file" "IRONIC_BAREMETAL_BASIC_OPS" "True"
        localrc_set "$localrc_file" "IRONIC_VM_LOG_DIR" "$BASE/$localrc_oldnew/ironic-bm-logs"
        localrc_set "$localrc_file" "DEFAULT_INSTANCE_TYPE" "baremetal"
        localrc_set "$localrc_file" "BUILD_TIMEOUT" "${DEVSTACK_GATE_TEMPEST_BAREMETAL_BUILD_TIMEOUT:-600}"
        localrc_set "$localrc_file" "IRONIC_CALLBACK_TIMEOUT" "600"
        localrc_set "$localrc_file" "Q_AGENT" "openvswitch"
        localrc_set "$localrc_file" "Q_ML2_TENANT_NETWORK_TYPE" "vxlan"
        if [[ "$DEVSTACK_GATE_IRONIC_BUILD_RAMDISK" -eq 0 ]]; then
            localrc_set "$localrc_file" "IRONIC_BUILD_DEPLOY_RAMDISK" "False"
        else
            localrc_set "$localrc_file" "IRONIC_BUILD_DEPLOY_RAMDISK" "True"
        fi
        if [[ -z "${DEVSTACK_GATE_IRONIC_DRIVER%%agent*}" ]]; then
            localrc_set "$localrc_file" "SWIFT_ENABLE_TEMPURLS" "True"
            localrc_set "$localrc_file" "SWIFT_TEMPURL_KEY" "secretkey"
            localrc_set "$localrc_file" "IRONIC_ENABLED_DRIVERS" "fake,agent_ssh,agent_ipmitool"
            # agent driver doesn't support ephemeral volumes yet
            localrc_set "$localrc_file" "IRONIC_VM_EPHEMERAL_DISK" "0"
            # agent CoreOS ramdisk is a little heavy
            localrc_set "$localrc_file" "IRONIC_VM_SPECS_RAM" "1024"
        else
            localrc_set "$localrc_file" "IRONIC_ENABLED_DRIVERS" "fake,pxe_ssh,pxe_ipmitool"
            localrc_set "$localrc_file" "IRONIC_VM_EPHEMERAL_DISK" "1"
        fi
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "xenapi" ]]; then
        if [ ! $DEVSTACK_GATE_XENAPI_DOM0_IP -o ! $DEVSTACK_GATE_XENAPI_DOMU_IP -o ! $DEVSTACK_GATE_XENAPI_PASSWORD ]; then
            echo "XenAPI must have DEVSTACK_GATE_XENAPI_DOM0_IP, DEVSTACK_GATE_XENAPI_DOMU_IP and DEVSTACK_GATE_XENAPI_PASSWORD all set"
            exit 1
        fi
        localrc_set "$localrc_file" "SKIP_EXERCISES" "${SKIP_EXERCISES},volumes"
        localrc_set "$localrc_file" "XENAPI_PASSWORD" "${DEVSTACK_GATE_XENAPI_PASSWORD}"
        localrc_set "$localrc_file" "XENAPI_CONNECTION_URL" "http://${DEVSTACK_GATE_XENAPI_DOM0_IP}"
        localrc_set "$localrc_file" "VNCSERVER_PROXYCLIENT_ADDRESS" "${DEVSTACK_GATE_XENAPI_DOM0_IP}"
        localrc_set "$localrc_file" "VIRT_DRIVER" "xenserver"

        # A separate xapi network is created with this name-label
        localrc_set "$localrc_file" "FLAT_NETWORK_BRIDGE" "vmnet"

        # A separate xapi network on eth4 serves the purpose of the public network.
        # This interface is added in Citrix's XenServer environment as an internal
        # interface
        localrc_set "$localrc_file" "PUBLIC_INTERFACE" "eth4"

        # The xapi network "vmnet" is connected to eth3 in domU
        # We need to explicitly specify these, as the devstack/xenserver driver
        # sets GUEST_INTERFACE_DEFAULT
        localrc_set "$localrc_file" "VLAN_INTERFACE" "eth3"
        localrc_set "$localrc_file" "FLAT_INTERFACE" "eth3"

        # Explicitly set HOST_IP, so that it will be passed down to xapi,
        # thus it will be able to reach glance
        localrc_set "$localrc_file" "HOST_IP" "${DEVSTACK_GATE_XENAPI_DOMU_IP}"
        localrc_set "$localrc_file" "SERVICE_HOST" "${DEVSTACK_GATE_XENAPI_DOMU_IP}"

        # Disable firewall
        localrc_set "$localrc_file" "XEN_FIREWALL_DRIVER" "nova.virt.firewall.NoopFirewallDriver"

        # Disable agent
        localrc_set "$localrc_file" "EXTRA_OPTS" "(\"xenapi_disable_agent=True\")"

        # Add a separate device for volumes
        localrc_set "$localrc_file" "VOLUME_BACKING_DEVICE" "/dev/xvdb"

        # Set multi-host config
        localrc_set "$localrc_file" "MULTI_HOST" "1"
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]]; then
        # Volume tests in Tempest require a number of volumes
        # to be created, each of 1G size. Devstack's default
        # volume backing file size is 10G.
        #
        # The 24G setting is expected to be enough even
        # in parallel run.
        localrc_set "$localrc_file" "VOLUME_BACKING_FILE_SIZE" "24G"
        # in order to ensure glance http tests don't time out, we
        # specify the TEMPEST_HTTP_IMAGE address that's in infra on a
        # service we need to be up for anything to work anyway.
        localrc_set "$localrc_file" "TEMPEST_HTTP_IMAGE" "http://git.openstack.org/static/openstack.png"
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]]; then
        localrc_set "$localrc_file" "TEMPEST_ALLOW_TENANT_ISOLATION" "False"
    fi

    if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
        if [[ "$localrc_oldnew" == "old" ]]; then
            localrc_set "$localrc_file" "GRENADE_PHASE" "base"
        else
            localrc_set "$localrc_file" "GRENADE_PHASE" "target"
        fi
        localrc_set "$localrc_file" "CEILOMETER_USE_MOD_WSGI" "False"
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -eq "1" ]]; then
        # NOTE(danms): Temporary transition to =NUM_RESOURCES
        localrc_set "$localrc_file" "VIRT_DRIVER" "fake"
        localrc_set "$localrc_file" "TEMPEST_LARGE_OPS_NUMBER" "50"
    elif [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -gt "1" ]]; then
        # use fake virt driver and 10 copies of nova-compute
        localrc_set "$localrc_file" "VIRT_DRIVER" "fake"
        # To make debugging easier, disabled until bug 1218575 is fixed.
        # echo "NUMBER_FAKE_NOVA_COMPUTE=10" >>"$localrc_file"
        localrc_set "$localrc_file" "TEMPEST_LARGE_OPS_NUMBER" "$DEVSTACK_GATE_TEMPEST_LARGE_OPS"

    fi

    if [[ "$DEVSTACK_GATE_CONFIGDRIVE" -eq "1" ]]; then
        localrc_set "$localrc_file" "FORCE_CONFIG_DRIVE" "True"
    else
        localrc_set "$localrc_file" "FORCE_CONFIG_DRIVE" "False"
    fi

    if [[ "$CEILOMETER_NOTIFICATION_TOPICS" ]]; then
        # Add specified ceilometer notification topics to localrc
        # Set to notifications,profiler to enable profiling
        localrc_set "$localrc_file" "CEILOMETER_NOTIFICATION_TOPICS" "$CEILOMETER_NOTIFICATION_TOPICS"
    fi

    if [[ "$DEVSTACK_GATE_INSTALL_TESTONLY" -eq "1" ]]; then
        # Sometimes we do want the test packages
        localrc_set "$localrc_file" "INSTALL_TESTONLY_PACKAGES" "True"
    fi

    if [[ "$DEVSTACK_GATE_TOPOLOGY" != "aio" ]]; then
        localrc_set "$localrc_file" "NOVA_ALLOW_MOVE_TO_SAME_HOST" "False"
        localrc_set "$localrc_file" "LIVE_MIGRATION_AVAILABLE" "True"
        localrc_set "$localrc_file" "USE_BLOCK_MIGRATION_FOR_LIVE_MIGRATION" "True"
        local primary_node=`cat /etc/nodepool/primary_node_private`
        localrc_set "$localrc_file" "SERVICE_HOST" "$primary_node"

        if [[ "$role" = sub ]]; then
            if [[ $original_enabled_services  =~ "qpid" ]]; then
                localrc_set "$localrc_file" "QPID_HOST" "$primary_node"
            fi
            if [[ $original_enabled_services =~ "rabbit" ]]; then
                localrc_set "$localrc_file" "RABBIT_HOST" "$primary_node"
            fi
            localrc_set "$localrc_file" "DATABASE_HOST" "$primary_node"
            if [[ $original_enabled_services =~ "mysql" ]]; then
                localrc_set "$localrc_file" "DATABASE_TYPE" "mysql"
            else
                localrc_set "$localrc_file" "DATABASE_TYPE" "postgresql"
            fi
            localrc_set "$localrc_file" "GLANCE_HOSTPORT" "$primary_node:9292"
            localrc_set "$localrc_file" "Q_HOST" "$primary_node"
            # Set HOST_IP in subnodes before copying localrc to each node
        else
            localrc_set "$localrc_file" "HOST_IP" "$primary_node"
        fi
    fi

    # If you specify a section of a project-config job with
    #
    #   local_conf:
    #      conf: |
    #          [[local|localrc]]
    #          foo=a
    #          [[post-config|$NEUTRON_CONF]]
    #          [DEFAULT]
    #          global_physnet_mtu = 1400
    #
    # Then that whole local.conf fragment will get carried through to
    # this special file, and we'll merge those values into *all*
    # local.conf files in the job. That includes subnodes, and new &
    # old in grenade.
    #
    # NOTE(sdague): the name of this file should be considered
    # internal only, and jobs should not write to it directly, they
    # should only use the project-config stanza.
    if [[ -e "/tmp/dg-local.conf" ]]; then
        $DSCONF merge_lc "$localrc_file" "/tmp/dg-local.conf"
    fi

    # a way to pass through arbitrary devstack config options so that
    # we don't need to add new devstack-gate options every time we
    # want to create a new config.
    if [[ "$role" = sub ]]; then
        # If we are in a multinode environment, we may want to specify 2
        # different sets of plugins
        if [[ -n "$DEVSTACK_SUBNODE_CONFIG" ]]; then
            $DSCONF setlc_raw "$localrc_file" "$DEVSTACK_SUBNODE_CONFIG"
        else
            if [[ -n "$DEVSTACK_LOCAL_CONFIG" ]]; then
                $DSCONF setlc_raw "$localrc_file" "$DEVSTACK_LOCAL_CONFIG"
            fi
        fi
    else
        if [[ -n "$DEVSTACK_LOCAL_CONFIG" ]]; then
            $DSCONF setlc_raw "$localrc_file" "$DEVSTACK_LOCAL_CONFIG"
        fi
    fi

}

# This makes the stack user own the $BASE files and also changes the
# permissions on the logs directory so we can write to the logs when running
# devstack or grenade. This must be called AFTER setup_localrc.
function setup_access_for_stack_user {
    # Make the workspace owned by the stack user
    # It is not clear if the ansible file module can do this for us
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "chown -R stack:stack '$BASE'"
    # allow us to add logs
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "chmod 777 '$WORKSPACE/logs'"
}

if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
    cd $BASE/new/grenade
    setup_localrc "old" "devstack.local.conf.base" "primary"
    setup_localrc "new" "devstack.local.conf.target" "primary"

    cat <<EOF >$BASE/new/grenade/localrc
BASE_RELEASE=old
BASE_RELEASE_DIR=$BASE/\$BASE_RELEASE
BASE_DEVSTACK_DIR=\$BASE_RELEASE_DIR/devstack
BASE_DEVSTACK_BRANCH=$GRENADE_OLD_BRANCH
TARGET_RELEASE=new
TARGET_RELEASE_DIR=$BASE/\$TARGET_RELEASE
TARGET_DEVSTACK_DIR=\$TARGET_RELEASE_DIR/devstack
TARGET_DEVSTACK_BRANCH=$GRENADE_NEW_BRANCH
TARGET_RUN_SMOKE=False
SAVE_DIR=\$BASE_RELEASE_DIR/save
TEMPEST_CONCURRENCY=$TEMPEST_CONCURRENCY
OS_TEST_TIMEOUT=$DEVSTACK_GATE_OS_TEST_TIMEOUT
VERBOSE=False
PLUGIN_DIR=\$TARGET_RELEASE_DIR
EOF

    # Create a pass through variable that can add content to the
    # grenade pluginrc. Needed for grenade external plugins in gate
    # jobs.
    if [[ -n "$GRENADE_PLUGINRC" ]]; then
        echo "$GRENADE_PLUGINRC" >>$BASE/new/grenade/pluginrc
    fi

    if [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]]; then
        # ensure local.conf exists to remove conditional logic
        if [[ $DEVSTACK_GATE_NEUTRON -eq "1" ]]; then
            $DSCONF setlc_conf "devstack.local.conf.base" "post-config" "\$NEUTRON_CONF" \
                            "DEFAULT" "global_physnet_mtu" "$EXTERNAL_BRIDGE_MTU"
            $DSCONF setlc_conf "devstack.local.conf.target" "post-config" "\$NEUTRON_CONF" \
                            "DEFAULT" "global_physnet_mtu" "$EXTERNAL_BRIDGE_MTU"
        fi

        # build the post-stack.sh config, this will be run as stack user so no sudo required
        cat > $BASE/new/grenade/post-stack.sh <<EOF
#!/bin/bash

set -x

$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd '$BASE/old/devstack' && stdbuf -oL -eL ./stack.sh"

if [[ -e "$BASE/old/devstack/tools/discover_hosts.sh" ]]; then
    $BASE/old/devstack/tools/discover_hosts.sh
fi
EOF
        sudo chmod a+x $BASE/new/grenade/post-stack.sh
    fi

    setup_networking "grenade"

    setup_access_for_stack_user

    echo "Running grenade ..."
    echo "This takes a good 30 minutes or more"
    cd $BASE/new/grenade
    sudo -H -u stack DSTOOLS_VERSION=$DSTOOLS_VERSION stdbuf -oL -eL ./grenade.sh
    cd $BASE/new/devstack

else
    cd $BASE/new/devstack
    setup_localrc "new" "local.conf" "primary"
    if [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]]; then
        if [[ $DEVSTACK_GATE_NEUTRON -eq "1" ]]; then
            localconf_set "local.conf" "post-config" "\$NEUTRON_CONF" \
                            "DEFAULT" "global_physnet_mtu" "$EXTERNAL_BRIDGE_MTU"
        fi
    fi

    setup_networking

    setup_access_for_stack_user

    echo "Running devstack"
    echo "... this takes 10 - 15 minutes (logs in logs/devstacklog.txt.gz)"
    start=$(date +%s)
    $ANSIBLE primary -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd '$BASE/new/devstack' && sudo -H -u stack DSTOOLS_VERSION=$DSTOOLS_VERSION stdbuf -oL -eL ./stack.sh executable=/bin/bash" \
        &> "$WORKSPACE/logs/devstack-early.txt"
    if [ -d "$BASE/data/CA" ] && [ -f "$BASE/data/ca-bundle.pem" ] ; then
        # Sync any data files which include certificates to be used if
        # TLS is enabled
        $ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" --sudo -m file \
            -a "path='$BASE/data' state=directory owner=stack group=stack mode=0755"
        $ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" --sudo -m file \
            -a "path='$BASE/data/CA' state=directory owner=stack group=stack mode=0755"
        $ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" \
            --sudo -m synchronize \
            -a "mode=push src='$BASE/data/ca-bundle.pem' dest='$BASE/data/ca-bundle.pem'"
        sudo $ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" \
            --sudo -u $USER -m synchronize \
            -a "mode=push src='$BASE/data/CA' dest='$BASE/data'"
    fi
    # Run non controller setup after controller is up. This is necessary
    # because services like nova apparently expect to have the controller in
    # place before anything else.
    $ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd '$BASE/new/devstack' && sudo -H -u stack DSTOOLS_VERSION=$DSTOOLS_VERSION stdbuf -oL -eL ./stack.sh executable=/bin/bash" \
        &> "$WORKSPACE/logs/devstack-subnodes-early.txt"
    end=$(date +%s)
    took=$((($end - $start) / 60))
    if [[ "$took" -gt 20 ]]; then
        echo "WARNING: devstack run took > 20 minutes, this is a very slow node."
    fi

    # Discover the hosts on a cells v2 deployment.
    discover_hosts

    # provide a check that the right db was running
    # the path are different for fedora and red hat.
    if [[ -f /usr/bin/yum ]]; then
        POSTGRES_LOG_PATH="-d /var/lib/pgsql"
        MYSQL_LOG_PATH="-f /var/log/mysqld.log"
    else
        POSTGRES_LOG_PATH="-d /var/log/postgresql"
        MYSQL_LOG_PATH="-d /var/log/mysql"
    fi
    if [[ "$DEVSTACK_GATE_POSTGRES" -eq "1" ]]; then
        if [[ ! $POSTGRES_LOG_PATH ]]; then
            echo "Postgresql should have been used, but there are no logs"
            exit 1
        fi
    else
        if [[ ! $MYSQL_LOG_PATH ]]; then
            echo "Mysql should have been used, but there are no logs"
            exit 1
        fi
    fi
fi

if [[ "$DEVSTACK_GATE_UNSTACK" -eq "1" ]]; then
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd '$BASE/new/devstack' && sudo -H -u stack ./unstack.sh"
fi

if [[ "$DEVSTACK_GATE_REMOVE_STACK_SUDO" -eq 1 ]]; then
    echo "Removing sudo privileges for devstack user"
    $ANSIBLE all --sudo -f 5 -i "$WORKSPACE/inventory" -m file \
        -a "path=/etc/sudoers.d/50_stack_sh state=absent"
fi

if [[ "$DEVSTACK_GATE_EXERCISES" -eq "1" ]]; then
    echo "Running devstack exercises"
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd '$BASE/new/devstack' && sudo -H -u stack ./exercise.sh"
fi

if [[ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]]; then
    # under tempest isolation tempest will need to write .tox dir, log files
    if [[ -d "$BASE/new/tempest" ]]; then
        sudo chown -R tempest:stack $BASE/new/tempest
    fi
    # Make sure tempest user can write to its directory for
    # lock-files.
    if [[ -d $BASE/data/tempest ]]; then
        sudo chown -R tempest:stack $BASE/data/tempest
    fi
    # ensure the cirros image files are accessible
    if [[ -d $BASE/new/devstack/files ]]; then
        sudo chmod -R o+rx $BASE/new/devstack/files
    fi

    # In the future we might want to increase the number of compute nodes.
    # This will ensure that multinode jobs consist of 2 nodes.
    # As a part of tempest configuration, it should be executed
    # before the DEVSTACK_GATE_TEMPEST_NOTESTS check, because the DEVSTACK_GATE_TEMPEST
    # guarantees that tempest should be configured, no matter should
    # tests be executed or not.
    if [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]]; then
        sudo $DSCONF iniset $BASE/new/tempest/etc/tempest.conf compute min_compute_nodes 2
    fi

    # if set, we don't need to run Tempest at all
    if [[ "$DEVSTACK_GATE_TEMPEST_NOTESTS" -eq "1" ]]; then
        exit 0
    fi

    # There are some parts of devstack that call the neutron api to verify the
    # extension. We should not ever trust this for gate testing. This checks to
    # ensure on master we always are using the default value. (on stable we hard
    # code a list of available extensions so we can't use this)
    neutron_extensions=$(iniget "$BASE/new/tempest/etc/tempest.conf" "neutron-feature-enabled" "api_extensions")
    if [[ $GIT_BRANCH == 'master' && ($neutron_extensions == 'all' || $neutron_extensions == '') ]] ; then
        echo "Devstack misconfugred tempest and changed the value of api_extensions"
        exit 1
    fi

    # From here until the end we rely on the fact that all the code fails if
    # something is wrong, to enforce exit on bad test results.
    set -o errexit

    if [[ "${TEMPEST_OS_TEST_TIMEOUT:-}" != "" ]] ; then
        TEMPEST_COMMAND="sudo -H -u tempest OS_TEST_TIMEOUT=$TEMPEST_OS_TEST_TIMEOUT tox"
    else
        TEMPEST_COMMAND="sudo -H -u tempest tox"
    fi
    cd $BASE/new/tempest
    if [[ "$DEVSTACK_GATE_TEMPEST_REGEX" != "" ]] ; then
        if [[ "$DEVSTACK_GATE_TEMPEST_ALL_PLUGINS" -eq "1" ]]; then
            echo "Running tempest with plugins and a custom regex filter"
            $TEMPEST_COMMAND -eall-plugin -- $DEVSTACK_GATE_TEMPEST_REGEX --concurrency=$TEMPEST_CONCURRENCY
            sudo -H -u tempest .tox/all-plugin/bin/tempest list-plugins
        else
            echo "Running tempest with a custom regex filter"
            $TEMPEST_COMMAND -eall -- $DEVSTACK_GATE_TEMPEST_REGEX --concurrency=$TEMPEST_CONCURRENCY
        fi
    elif [[ "$DEVSTACK_GATE_TEMPEST_ALL_PLUGINS" -eq "1" ]]; then
        echo "Running tempest all-plugins test suite"
        $TEMPEST_COMMAND -eall-plugin -- --concurrency=$TEMPEST_CONCURRENCY
        sudo -H -u tempest .tox/all-plugin/bin/tempest list-plugins
    elif [[ "$DEVSTACK_GATE_TEMPEST_ALL" -eq "1" ]]; then
        echo "Running tempest all test suite"
        $TEMPEST_COMMAND -eall -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]]; then
        echo "Running tempest full test suite serially"
        $TEMPEST_COMMAND -efull-serial
    elif [[ "$DEVSTACK_GATE_TEMPEST_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite"
        $TEMPEST_COMMAND -efull -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_TEMPEST_STRESS" -eq "1" ]] ; then
        echo "Running stress tests"
        $TEMPEST_COMMAND -estress -- $DEVSTACK_GATE_TEMPEST_STRESS_ARGS
    elif [[ "$DEVSTACK_GATE_SMOKE_SERIAL" -eq "1" ]] ; then
        echo "Running tempest smoke tests"
        $TEMPEST_COMMAND -esmoke-serial
    else
        echo "Running tempest smoke tests"
        $TEMPEST_COMMAND -esmoke -- --concurrency=$TEMPEST_CONCURRENCY
    fi

fi
