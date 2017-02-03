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

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Prepare the environment
# -----------------------

# Import common functions
source $TOP_DIR/functions.sh

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
    cat <<EOF >>"$localrc"
FLAT_INTERFACE=br_flat
PUBLIC_INTERFACE=br_pub
EOF
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
    local localrc=$BASE/new/devstack/localrc
    local old_or_new="new"
    if [[ "$mode" == "grenade" ]]; then
        localrc=$BASE/new/grenade/devstack.localrc
        old_or_new="old"
    fi
    # set explicit paths on all conf files we're writing so that
    # current working directory doesn't introduce subtle bugs.
    local devstack_dir=$BASE/$old_or_new/devstack
    local sub_localrc=$devstack_dir/sub_localrc
    local localconf=$devstack_dir/local.conf

    set -x  # for now enabling debug and do not turn it off
    setup_localrc $old_or_new "$sub_localrc" "sub"

    local primary_node
    primary_node=$(cat /etc/nodepool/primary_node_private)
    local sub_nodes
    sub_nodes=$(cat /etc/nodepool/sub_nodes_private)
    if [[ "$DEVSTACK_GATE_NEUTRON" -ne '1' ]]; then
        setup_nova_net_networking $localrc $primary_node $sub_nodes
        cat <<EOF >>"$sub_localrc"
FLAT_INTERFACE=br_flat
PUBLIC_INTERFACE=br_pub
MULTI_HOST=True
EOF
        cat <<EOF >>"$localrc"
MULTI_HOST=True
EOF
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

        cat <<EOF >>"$sub_localrc"
HOST_TOPOLOGY=multinode
HOST_TOPOLOGY_ROLE=subnode
# NOTE(vsaienko) we assume for now that we using only 1 subnode,
# each subnode should have different switch name (bridge) as it is used
# by networking-generic-switch to uniquely identify switch.
IRONIC_VM_NETWORK_BRIDGE=sub1brbm
OVS_PHYSICAL_BRIDGE=sub1brbm
ENABLE_TENANT_TUNNELS=False
IRONIC_KEY_FILE="$BASE/new/.ssh/ironic_key"
EOF
        cat <<EOF >>"$localrc"
HOST_TOPOLOGY=multinode
HOST_TOPOLOGY_ROLE=primary
HOST_TOPOLOGY_SUBNODES="$sub_nodes"
IRONIC_KEY_FILE="$BASE/new/.ssh/ironic_key"
GENERIC_SWITCH_KEY_FILE="$BASE/new/.ssh/ironic_key"
ENABLE_TENANT_TUNNELS=False
EOF
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
        cp $sub_localrc /tmp/tmp_sub_localrc
        echo "HOST_IP=$NODE" >> /tmp/tmp_sub_localrc
        remote_copy_file /tmp/tmp_sub_localrc $NODE:$devstack_dir/localrc
        remote_copy_file $localconf $NODE:$localconf
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
        local localrc=$BASE/new/devstack/localrc
        if [[ "$mode" == "grenade" ]]; then
            localrc=$BASE/new/grenade/devstack.localrc
        fi
        setup_nova_net_networking "$localrc" "127.0.0.1"
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
        echo "USE_PYTHON3=$DEVSTACK_GATE_USE_PYTHON3" >>"$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_CEPH" == "1" ]]; then
        echo "CINDER_ENABLED_BACKENDS=ceph:ceph" >>"$localrc_file"
        echo "TEMPEST_STORAGE_PROTOCOL=ceph" >>"$localrc_file"
    fi

    # the exercises we *don't* want to test on for devstack
    SKIP_EXERCISES=boot_from_volume,bundle,client-env,euca

    if [[ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]]; then
        echo "Q_USE_DEBUG_COMMAND=True" >>"$localrc_file"
        echo "NETWORK_GATEWAY=10.1.0.1" >>"$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_NEUTRON_DVR" -eq "1" ]]; then
        if [[ "$DEVSTACK_GATE_TOPOLOGY" != "aio" ]] && [[ $role = sub ]]; then
            # The role for L3 agents running on compute nodes is 'dvr'
            echo "Q_DVR_MODE=dvr" >>"$localrc_file"
        else
            # The role for L3 agents running on controller nodes is 'dvr_snat'
            echo "Q_DVR_MODE=dvr_snat" >>"$localrc_file"
        fi
    fi

    cat <<EOF >>"$localrc_file"
USE_SCREEN=False
DEST=$BASE/$localrc_oldnew
# move DATA_DIR outside of DEST to keep DEST a bit cleaner
DATA_DIR=$BASE/data
ACTIVE_TIMEOUT=90
BOOT_TIMEOUT=90
ASSOCIATE_TIMEOUT=60
TERMINATE_TIMEOUT=60
MYSQL_PASSWORD=secretmysql
DATABASE_PASSWORD=secretdatabase
RABBIT_PASSWORD=secretrabbit
ADMIN_PASSWORD=secretadmin
SERVICE_PASSWORD=secretservice
SERVICE_TOKEN=111222333444
SWIFT_HASH=1234123412341234
ROOTSLEEP=0
# ERROR_ON_CLONE should never be set to FALSE in gate jobs.
# Setting up git trees must be done by zuul
# because it needs specific git references directly from gerrit
# to correctly do testing. Otherwise you are not testing
# the code you have posted for review.
ERROR_ON_CLONE=True
# Since git clone can't be used for novnc in gates, force it to install the packages
NOVNC_FROM_PACKAGE=True
ENABLED_SERVICES=$MY_ENABLED_SERVICES
SKIP_EXERCISES=$SKIP_EXERCISES
# Screen console logs will capture service logs.
SYSLOG=False
SCREEN_LOGDIR=$BASE/$localrc_oldnew/screen-logs
LOGFILE=$BASE/$localrc_oldnew/devstacklog.txt
VERBOSE=True
FIXED_RANGE=$FIXED_RANGE
IPV4_ADDRS_SAFE_TO_USE=$IPV4_ADDRS_SAFE_TO_USE
FLOATING_RANGE=$FLOATING_RANGE
PUBLIC_NETWORK_GATEWAY=$PUBLIC_NETWORK_GATEWAY
FIXED_NETWORK_SIZE=4096
VIRT_DRIVER=$DEVSTACK_GATE_VIRT_DRIVER
SWIFT_REPLICAS=1
LOG_COLOR=False
# Don't reset the requirements.txt files after g-r updates
UNDO_REQUIREMENTS=False
CINDER_PERIODIC_INTERVAL=10
export OS_NO_CACHE=True
CEILOMETER_BACKEND=$DEVSTACK_GATE_CEILOMETER_BACKEND
LIBS_FROM_GIT=$DEVSTACK_PROJECT_FROM_GIT
# set this until all testing platforms have libvirt >= 1.2.11
# see bug #1501558
EBTABLES_RACE_FIX=True
EOF

    if [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]] && [[ $DEVSTACK_GATE_NEUTRON -eq "1" ]]; then
        # Reduce the MTU on br-ex to match the MTU of underlying tunnels
        echo "PUBLIC_BRIDGE_MTU=$EXTERNAL_BRIDGE_MTU" >>"$localrc_file"
    fi

    if [[ "$DEVSTACK_CINDER_SECURE_DELETE" -eq "0" ]]; then
        echo "CINDER_SECURE_DELETE=False" >>"$localrc_file"
    fi
    echo "CINDER_VOLUME_CLEAR=${DEVSTACK_CINDER_VOLUME_CLEAR}" >>"$localrc_file"

    if [[ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]]; then
        echo "HEAT_CREATE_TEST_IMAGE=False" >>"$localrc_file"
        # Use Fedora 20 for heat test image, it has heat-cfntools pre-installed
        echo "HEAT_FETCHED_TEST_IMAGE=Fedora-i386-20-20131211.1-sda" >>"$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "libvirt" ]]; then
        if [[ -n "$DEVSTACK_GATE_LIBVIRT_TYPE" ]]; then
            echo "LIBVIRT_TYPE=${DEVSTACK_GATE_LIBVIRT_TYPE}" >>localrc
        fi
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "ironic" ]]; then
        export TEMPEST_OS_TEST_TIMEOUT=${DEVSTACK_GATE_OS_TEST_TIMEOUT:-1200}
        echo "IRONIC_DEPLOY_DRIVER=$DEVSTACK_GATE_IRONIC_DRIVER" >>"$localrc_file"
        echo "IRONIC_BAREMETAL_BASIC_OPS=True" >>"$localrc_file"
        echo "IRONIC_VM_LOG_DIR=$BASE/$localrc_oldnew/ironic-bm-logs" >>"$localrc_file"
        echo "DEFAULT_INSTANCE_TYPE=baremetal" >>"$localrc_file"
        echo "BUILD_TIMEOUT=${DEVSTACK_GATE_TEMPEST_BAREMETAL_BUILD_TIMEOUT:-600}" >>"$localrc_file"
        echo "IRONIC_CALLBACK_TIMEOUT=600" >>"$localrc_file"
        echo "Q_AGENT=openvswitch" >>"$localrc_file"
        echo "Q_ML2_TENANT_NETWORK_TYPE=vxlan" >>"$localrc_file"
        if [[ "$DEVSTACK_GATE_IRONIC_BUILD_RAMDISK" -eq 0 ]]; then
            echo "IRONIC_BUILD_DEPLOY_RAMDISK=False" >>"$localrc_file"
        else
            echo "IRONIC_BUILD_DEPLOY_RAMDISK=True" >>"$localrc_file"
        fi
        if [[ -z "${DEVSTACK_GATE_IRONIC_DRIVER%%agent*}" ]]; then
            echo "SWIFT_ENABLE_TEMPURLS=True" >>"$localrc_file"
            echo "SWIFT_TEMPURL_KEY=secretkey" >>"$localrc_file"
            echo "IRONIC_ENABLED_DRIVERS=fake,agent_ssh,agent_ipmitool" >>"$localrc_file"
            # agent driver doesn't support ephemeral volumes yet
            echo "IRONIC_VM_EPHEMERAL_DISK=0" >>"$localrc_file"
            # agent CoreOS ramdisk is a little heavy
            echo "IRONIC_VM_SPECS_RAM=1024" >>"$localrc_file"
        else
            echo "IRONIC_ENABLED_DRIVERS=fake,pxe_ssh,pxe_ipmitool" >>"$localrc_file"
            echo "IRONIC_VM_EPHEMERAL_DISK=1" >>"$localrc_file"
        fi
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "xenapi" ]]; then
        if [ ! $DEVSTACK_GATE_XENAPI_DOM0_IP -o ! $DEVSTACK_GATE_XENAPI_DOMU_IP -o ! $DEVSTACK_GATE_XENAPI_PASSWORD ]; then
            echo "XenAPI must have DEVSTACK_GATE_XENAPI_DOM0_IP, DEVSTACK_GATE_XENAPI_DOMU_IP and DEVSTACK_GATE_XENAPI_PASSWORD all set"
            exit 1
        fi
        cat >> "$localrc_file" << EOF
SKIP_EXERCISES=${SKIP_EXERCISES},volumes
XENAPI_PASSWORD=${DEVSTACK_GATE_XENAPI_PASSWORD}
XENAPI_CONNECTION_URL=http://${DEVSTACK_GATE_XENAPI_DOM0_IP}
VNCSERVER_PROXYCLIENT_ADDRESS=${DEVSTACK_GATE_XENAPI_DOM0_IP}
VIRT_DRIVER=xenserver

# A separate xapi network is created with this name-label
FLAT_NETWORK_BRIDGE=vmnet

# A separate xapi network on eth4 serves the purpose of the public network.
# This interface is added in Citrix's XenServer environment as an internal
# interface
PUBLIC_INTERFACE=eth4

# The xapi network "vmnet" is connected to eth3 in domU
# We need to explicitly specify these, as the devstack/xenserver driver
# sets GUEST_INTERFACE_DEFAULT
VLAN_INTERFACE=eth3
FLAT_INTERFACE=eth3

# Explicitly set HOST_IP, so that it will be passed down to xapi,
# thus it will be able to reach glance
HOST_IP=${DEVSTACK_GATE_XENAPI_DOMU_IP}
SERVICE_HOST=${DEVSTACK_GATE_XENAPI_DOMU_IP}

# Disable firewall
XEN_FIREWALL_DRIVER=nova.virt.firewall.NoopFirewallDriver

# Disable agent
EXTRA_OPTS=("xenapi_disable_agent=True")

# Add a separate device for volumes
VOLUME_BACKING_DEVICE=/dev/xvdb

# Set multi-host config
MULTI_HOST=1
EOF
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]]; then
        # Volume tests in Tempest require a number of volumes
        # to be created, each of 1G size. Devstack's default
        # volume backing file size is 10G.
        #
        # The 24G setting is expected to be enough even
        # in parallel run.
        echo "VOLUME_BACKING_FILE_SIZE=24G" >> "$localrc_file"
        # in order to ensure glance http tests don't time out, we
        # specify the TEMPEST_HTTP_IMAGE address that's in infra on a
        # service we need to be up for anything to work anyway.
        echo "TEMPEST_HTTP_IMAGE=http://git.openstack.org/static/openstack.png" >> "$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]]; then
        echo "TEMPEST_ALLOW_TENANT_ISOLATION=False" >>"$localrc_file"
    fi

    if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
        if [[ "$localrc_oldnew" == "old" ]]; then
            echo "GRENADE_PHASE=base" >> "$localrc_file"
        else
            echo "GRENADE_PHASE=target" >> "$localrc_file"
        fi
        # services deployed with mod wsgi cannot be upgraded or migrated
        # until https://launchpad.net/bugs/1365105 is resolved.
        case $GRENADE_NEW_BRANCH in
            "stable/icehouse")
                ;&
            "stable/juno")
                echo "KEYSTONE_USE_MOD_WSGI=False" >> "$localrc_file"
                ;;
            "stable/kilo")
                # while both juno and kilo can run under wsgi, they
                # can't run a code only upgrade because the
                # configuration assumes copying python files around
                # during config stage. This might be addressed by
                # keystone team later, hence separate comment and code
                # block.
                echo "KEYSTONE_USE_MOD_WSGI=False" >> "$localrc_file"
                ;;
        esac
        echo "CEILOMETER_USE_MOD_WSGI=False" >> "$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -eq "1" ]]; then
        # NOTE(danms): Temporary transition to =NUM_RESOURCES
        echo "VIRT_DRIVER=fake" >> "$localrc_file"
        echo "TEMPEST_LARGE_OPS_NUMBER=50" >>"$localrc_file"
    elif [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -gt "1" ]]; then
        # use fake virt driver and 10 copies of nova-compute
        echo "VIRT_DRIVER=fake" >> "$localrc_file"
        # To make debugging easier, disabled until bug 1218575 is fixed.
        # echo "NUMBER_FAKE_NOVA_COMPUTE=10" >>"$localrc_file"
        echo "TEMPEST_LARGE_OPS_NUMBER=$DEVSTACK_GATE_TEMPEST_LARGE_OPS" >>"$localrc_file"

    fi

    if [[ "$DEVSTACK_GATE_CONFIGDRIVE" -eq "1" ]]; then
        echo "FORCE_CONFIG_DRIVE=True" >>"$localrc_file"
    else
        echo "FORCE_CONFIG_DRIVE=False" >>"$localrc_file"
    fi

    if [[ "$CEILOMETER_NOTIFICATION_TOPICS" ]]; then
        # Add specified ceilometer notification topics to localrc
        # Set to notifications,profiler to enable profiling
        echo "CEILOMETER_NOTIFICATION_TOPICS=$CEILOMETER_NOTIFICATION_TOPICS" >>"$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_INSTALL_TESTONLY" -eq "1" ]]; then
        # Sometimes we do want the test packages
        echo "INSTALL_TESTONLY_PACKAGES=True" >> "$localrc_file"
    fi

    if [[ "$DEVSTACK_GATE_TOPOLOGY" != "aio" ]]; then
        echo "NOVA_ALLOW_MOVE_TO_SAME_HOST=False" >> "$localrc_file"
        echo "LIVE_MIGRATION_AVAILABLE=True" >> "$localrc_file"
        echo "USE_BLOCK_MIGRATION_FOR_LIVE_MIGRATION=True" >> "$localrc_file"
        local primary_node=`cat /etc/nodepool/primary_node_private`
        echo "SERVICE_HOST=$primary_node" >>"$localrc_file"

        if [[ "$role" = sub ]]; then
            if [[ $original_enabled_services  =~ "qpid" ]]; then
                echo "QPID_HOST=$primary_node" >>"$localrc_file"
            fi
            if [[ $original_enabled_services =~ "rabbit" ]]; then
                echo "RABBIT_HOST=$primary_node" >>"$localrc_file"
            fi
            echo "DATABASE_HOST=$primary_node" >>"$localrc_file"
            if [[ $original_enabled_services =~ "mysql" ]]; then
                echo "DATABASE_TYPE=mysql"  >>"$localrc_file"
            else
                echo "DATABASE_TYPE=postgresql"  >>"$localrc_file"
            fi
            echo "GLANCE_HOSTPORT=$primary_node:9292" >>"$localrc_file"
            echo "Q_HOST=$primary_node" >>"$localrc_file"
            # Set HOST_IP in subnodes before copying localrc to each node
        else
            echo "HOST_IP=$primary_node" >>"$localrc_file"
        fi
    fi

    # a way to pass through arbitrary devstack config options so that
    # we don't need to add new devstack-gate options every time we
    # want to create a new config.
    if [[ "$role" = sub ]]; then
        # If we are in a multinode environment, we may want to specify 2
        # different sets of plugins
        if [[ -n "$DEVSTACK_SUBNODE_CONFIG" ]]; then
            echo "$DEVSTACK_SUBNODE_CONFIG" >>"$localrc_file"
        else
            if [[ -n "$DEVSTACK_LOCAL_CONFIG" ]]; then
                echo "$DEVSTACK_LOCAL_CONFIG" >>"$localrc_file"
            fi
        fi
    else
        if [[ -n "$DEVSTACK_LOCAL_CONFIG" ]]; then
            echo "$DEVSTACK_LOCAL_CONFIG" >>"$localrc_file"
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
    cd $BASE/old/devstack
    setup_localrc "old" "localrc" "primary"

    cd $BASE/new/devstack
    setup_localrc "new" "localrc" "primary"

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
        touch local.conf
        if [[ $DEVSTACK_GATE_NEUTRON -eq "1" ]]; then
            echo -e "[[post-config|\$NEUTRON_CONF]]\n[DEFAULT]\nglobal_physnet_mtu=$EXTERNAL_BRIDGE_MTU" >> local.conf
        fi

        # get this in our base config
        cp local.conf $BASE/old/devstack

        # build the post-stack.sh config, this will be run as stack user so no sudo required
        cat > $BASE/new/grenade/post-stack.sh <<EOF
#!/bin/bash

set -x

$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "cd '$BASE/old/devstack' && stdbuf -oL -eL ./stack.sh"
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
    setup_localrc "new" "localrc" "primary"
    if [[ "$DEVSTACK_GATE_TOPOLOGY" == "multinode" ]]; then
        # ensure local.conf exists to remove conditional logic
        touch local.conf
        if [[ $DEVSTACK_GATE_NEUTRON -eq "1" ]]; then
            echo -e "[[post-config|\$NEUTRON_CONF]]\n[DEFAULT]\nglobal_physnet_mtu=$EXTERNAL_BRIDGE_MTU" >> local.conf
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
        iniset -sudo $BASE/new/tempest/etc/tempest.conf compute min_compute_nodes 2
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
