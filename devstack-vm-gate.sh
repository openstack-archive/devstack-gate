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

echo $PPID > $WORKSPACE/gate.pid

function setup_localrc {
    LOCALRC_OLDNEW=$1;
    LOCALRC_BRANCH=$2;

    # Allow calling context to pre-populate the localrc file
    # with additional values
    if [[ -z $KEEP_LOCALRC ]] ; then
        rm -f localrc
    fi

    MY_ENABLED_SERVICES=`cd $BASE/new/devstack-gate && ./test-matrix.py -b $LOCALRC_BRANCH -f $DEVSTACK_GATE_FEATURE_MATRIX`

    # Allow optional injection of ENABLED_SERVICES from the calling context
    if [[ ! -z $ENABLED_SERVICES ]] ; then
        MY_ENABLED_SERVICES+=,$ENABLED_SERVICES
    fi

    if [[ "$DEVSTACK_GATE_CEPH" == "1" ]]; then
        echo "CINDER_ENABLED_BACKENDS=ceph:ceph" >>localrc
    fi

    # the exercises we *don't* want to test on for devstack
    SKIP_EXERCISES=boot_from_volume,bundle,client-env,euca

    if [[ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]]; then
        echo "Q_USE_DEBUG_COMMAND=True" >>localrc
        echo "NETWORK_GATEWAY=10.1.0.1" >>localrc
    fi

    if [[ "$DEVSTACK_GATE_NEUTRON_DVR" -eq "1" ]]; then
        echo "Q_DVR_MODE=dvr_snat" >>localrc
    fi

    if [[ "$LOCALRC_BRANCH" == "stable/havana" ]]; then
        # we don't want to enable services for grenade that don't have upgrade support
        # otherwise they can break grenade, especially when they are projects like
        # ceilometer which inject code in other projects
        if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
            SKIP_EXERCISES=${SKIP_EXERCISES},swift,client-args
        fi
    fi

    cat <<EOF >>localrc
DEST=$BASE/$LOCALRC_OLDNEW
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
ERROR_ON_CLONE=True
ENABLED_SERVICES=$MY_ENABLED_SERVICES
SKIP_EXERCISES=$SKIP_EXERCISES
SERVICE_HOST=127.0.0.1
# Screen console logs will capture service logs.
SYSLOG=False
SCREEN_LOGDIR=$BASE/$LOCALRC_OLDNEW/screen-logs
LOGFILE=$BASE/$LOCALRC_OLDNEW/devstacklog.txt
VERBOSE=True
FIXED_RANGE=10.1.0.0/20
FIXED_NETWORK_SIZE=4096
VIRT_DRIVER=$DEVSTACK_GATE_VIRT_DRIVER
SWIFT_REPLICAS=1
LOG_COLOR=False
PIP_USE_MIRRORS=False
USE_GET_PIP=1
# Don't reset the requirements.txt files after g-r updates
UNDO_REQUIREMENTS=False
CINDER_PERIODIC_INTERVAL=10
export OS_NO_CACHE=True
CEILOMETER_BACKEND=$DEVSTACK_GATE_CEILOMETER_BACKEND
EOF

    if [[ "$DEVSTACK_CINDER_SECURE_DELETE" -eq "0" ]]; then
        echo "CINDER_SECURE_DELETE=False" >>localrc
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]]; then
        echo "HEAT_CREATE_TEST_IMAGE=False" >>localrc
        # Use Fedora 20 for heat test image, it has heat-cfntools pre-installed
        echo "HEAT_FETCHED_TEST_IMAGE=Fedora-i386-20-20131211.1-sda" >>localrc
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]]; then
        echo "SKIP_EXERCISES=${SKIP_EXERCISES},volumes" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=m1.small" >>localrc
        echo "DEFAULT_INSTANCE_USER=root" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=m1.small" >>exerciserc
        echo "DEFAULT_INSTANCE_USER=root" >>exerciserc
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "ironic" ]]; then
        echo "VIRT_DRIVER=ironic" >>localrc
        echo "IRONIC_BAREMETAL_BASIC_OPS=True" >>localrc
        echo "IRONIC_VM_EPHEMERAL_DISK=1" >>localrc
        echo "IRONIC_VM_LOG_DIR=$BASE/$LOCALRC_OLDNEW/ironic-bm-logs" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=baremetal" >>localrc
        if [[ "$DEVSTACK_GATE_IRONIC_DRIVER" == "agent_ssh" ]]; then
            echo "SWIFT_ENABLE_TEMPURLS=True" >>localrc
            echo "IRONIC_ENABLED_DRIVERS=fake,agent_ssh,agent_ipmitool" >>localrc
            echo "IRONIC_BUILD_DEPLOY_RAMDISK=False" >>localrc
            echo "IRONIC_DEPLOY_DRIVER=agent_ssh" >>localrc
        fi
    fi

    if [[ "$DEVSTACK_GATE_VIRT_DRIVER" == "xenapi" ]]; then
        if [ ! $DEVSTACK_GATE_XENAPI_DOM0_IP -o ! $DEVSTACK_GATE_XENAPI_DOMU_IP -o ! $DEVSTACK_GATE_XENAPI_PASSWORD ]; then
            echo "XenAPI must have DEVSTACK_GATE_XENAPI_DOM0_IP, DEVSTACK_GATE_XENAPI_DOMU_IP and DEVSTACK_GATE_XENAPI_PASSWORD all set"
            exit 1
        fi
        cat >> localrc << EOF
SKIP_EXERCISES=${SKIP_EXERCISES},volumes
XENAPI_PASSWORD=${DEVSTACK_GATE_XENAPI_PASSWORD}
XENAPI_CONNECTION_URL=http://${DEVSTACK_GATE_XENAPI_DOM0_IP}
VNCSERVER_PROXYCLIENT_ADDRESS=${DEVSTACK_GATE_XENAPI_DOM0_IP}
VIRT_DRIVER=xenserver

# A separate xapi network is created with this name-label
FLAT_NETWORK_BRIDGE=vmnet

# A separate xapi network on eth4 serves the purpose of the public network
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
        # We need to disable ratelimiting when running
        # Tempest tests since so many requests are executed
        echo "API_RATE_LIMIT=False" >> localrc
        # Volume tests in Tempest require a number of volumes
        # to be created, each of 1G size. Devstack's default
        # volume backing file size is 10G.
        #
        # The 24G setting is expected to be enough even
        # in parallel run.
        echo "VOLUME_BACKING_FILE_SIZE=24G" >> localrc
        # in order to ensure glance http tests don't time out, we
        # specify the TEMPEST_HTTP_IMAGE address to be horrizon's
        # front page. Kind of hacky, but it works.
        echo "TEMPEST_HTTP_IMAGE=http://127.0.0.1/" >> localrc
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]]; then
        echo "TEMPEST_ALLOW_TENANT_ISOLATION=False" >>localrc
    fi

    if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
        echo "DATA_DIR=/opt/stack/data" >> localrc
        echo "SWIFT_DATA_DIR=/opt/stack/data/swift" >> localrc
        if [[ "$LOCALRC_OLDNEW" == "old" ]]; then
            echo "GRENADE_PHASE=base" >> localrc
        else
            echo "GRENADE_PHASE=target" >> localrc
        fi
    else
        # Grenade needs screen, so only turn this off if we aren't
        # running grenade.
        echo "USE_SCREEN=False" >>localrc
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -eq "1" ]]; then
        # NOTE(danms): Temporary transition to =NUM_RESOURCES
        echo "VIRT_DRIVER=fake" >> localrc
        echo "TEMPEST_LARGE_OPS_NUMBER=50" >>localrc
    elif [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -gt "1" ]]; then
        # use fake virt driver and 10 copies of nova-compute
        echo "VIRT_DRIVER=fake" >> localrc
        # To make debugging easier, disabled until bug 1218575 is fixed.
        # echo "NUMBER_FAKE_NOVA_COMPUTE=10" >>localrc
        echo "TEMPEST_LARGE_OPS_NUMBER=$DEVSTACK_GATE_TEMPEST_LARGE_OPS" >>localrc

    fi

    if [[ "$DEVSTACK_GATE_CONFIGDRIVE" -eq "1" ]]; then
        echo "FORCE_CONFIG_DRIVE=always" >>localrc
    else
        echo "FORCE_CONFIG_DRIVE=False" >>localrc
    fi
    if [[ "$DEVSTACK_GATE_KEYSTONE_V3" -eq "1" ]]; then
        # Run gate using only keystone v3
        # For now this is only injected in tempest configuration
        echo "TEMPEST_AUTH_VERSION=v3" >>localrc
    fi

    if [[ "$DEVSTACK_GATE_ENABLE_HTTPD_MOD_WSGI_SERVICES" -eq "0" ]]; then
        # Services that default to run under Apache + mod_wsgi will use alternatives
        # (e.g. Keystone under eventlet) if available. This will affect all services
        # that run under HTTPD (mod_wsgi) by default.
        echo "ENABLE_HTTPD_MOD_WSGI_SERVICES=False" >> localrc
    fi

    if [[ "$CEILOMETER_NOTIFICATION_TOPICS" ]]; then
        # Add specified ceilometer notification topics to localrc
        # Set to notifications,profiler to enable profiling
        echo "CEILOMETER_NOTIFICATION_TOPICS=$CEILOMETER_NOTIFICATION_TOPICS" >>localrc
    fi

    if [[ "$DEVSTACK_GATE_TEMPEST_NOVA_V3_API" -eq "1" ]]; then
        echo "TEMPEST_NOVA_API_V3=True" >> localrc
    fi
    if [[ "$DEVSTACK_GATE_INSTALL_TESTONLY" -eq "1" ]]; then
        # Sometimes we do want the test packages
        echo "INSTALL_TESTONLY_PACKAGES=True" >> localrc
    fi
}

if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
    if [[ "$DEVSTACK_GATE_GRENADE" == "sideways-ironic" ]]; then
        # Disable ironic when generating the "old" localrc.
        local tmp_DEVSTACK_GATE_IRONIC=$DEVSTACK_GATE_IRONIC
        local tmp_DEVSTACK_GATE_VIRT_DRIVER=$DEVSTACK_GATE_VIRT_DRIVER
        export DEVSTACK_GATE_IRONIC=0
        export DEVSTACK_GATE_VIRT_DRIVER="fake"
    fi
    if [[ "$DEVSTACK_GATE_GRENADE" == "sideways-neutron" ]]; then
        # Use nova network when generating "old" localrc.
        local tmp_DEVSTACK_GATE_NEUTRON=$DEVSTACK_GATE_NEUTRON
        export DEVSTACK_GATE_NEUTRON=0
    fi
    cd $BASE/old/devstack
    setup_localrc "old" "$GRENADE_OLD_BRANCH"

    if [[ "$DEVSTACK_GATE_GRENADE" == "sideways-ironic" ]]; then
        # Set ironic and virt driver settings to those initially set
        # by the job.
        export DEVSTACK_GATE_IRONIC=$tmp_DEVSTACK_GATE_IRONIC
        export DEVSTACK_GATE_VIRT_DRIVER=$tmp_DEVSTACK_GATE_VIRT_DRIVER
    fi
    if [[ "$DEVSTACK_GATE_GRENADE" == "sideways-neutron" ]]; then
        # Set neutron setting to that initially set by the job.
        export DEVSTACK_GATE_NEUTRON=$tmp_DEVSTACK_GATE_NEUTRON
    fi
    cd $BASE/new/devstack
    setup_localrc "new" "$GRENADE_OLD_BRANCH"

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
DO_NOT_UPGRADE_SERVICES=$DO_NOT_UPGRADE_SERVICES
TEMPEST_CONCURRENCY=$TEMPEST_CONCURRENCY
VERBOSE=False
EOF
    # Make the workspace owned by the stack user
    sudo chown -R stack:stack $BASE

    cd $BASE/new/grenade
    echo "Running grenade ..."
    echo "This takes a good 30 minutes or more"
    sudo -H -u stack stdbuf -oL -eL ./grenade.sh
    cd $BASE/new/devstack

else
    cd $BASE/new/devstack
    setup_localrc "new" "$OVERRIDE_ZUUL_BRANCH"

    # Make the workspace owned by the stack user
    sudo chown -R stack:stack $BASE

    echo "Running devstack"
    echo "... this takes 5 - 8 minutes (logs in logs/devstacklog.txt.gz)"
    start=$(date +%s)
    sudo -H -u stack stdbuf -oL -eL ./stack.sh > /dev/null
    end=$(date +%s)
    took=$[($end - $start) / 60]
    if [[ "$took" -gt 15 ]]; then
        echo "WARNING: devstack run took > 15 minutes, this is a very slow node."
    fi

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

echo "Removing sudo privileges for devstack user"
sudo rm /etc/sudoers.d/50_stack_sh

if [[ "$DEVSTACK_GATE_EXERCISES" -eq "1" ]]; then
    echo "Running devstack exercises"
    sudo -H -u stack ./exercise.sh
fi

if [[ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]]; then
    # under tempest isolation tempest will need to write .tox dir, log files
    if [[ -d "$BASE/new/tempest" ]]; then
        sudo chown -R tempest:stack $BASE/new/tempest
    fi
    # our lock files are in data, so we need to be able to write over there
    if [[ -d /opt/stack/data/tempest ]]; then
        sudo chown -R tempest:stack /opt/stack/data/tempest
    fi
    # ensure the cirros image files are accessible
    if [[ -d /opt/stack/new/devstack/files ]]; then
        sudo chmod -R o+rx /opt/stack/new/devstack/files
    fi

    # From here until the end we rely on the fact that all the code fails if
    # something is wrong, to enforce exit on bad test results.
    set -o errexit

    cd $BASE/new/tempest
    if [[ "$DEVSTACK_GATE_TEMPEST_REGEX" != "" ]] ; then
        echo "Running tempest with a custom regex filter"
        sudo -H -u tempest tox -eall -- --concurrency=$TEMPEST_CONCURRENCY $DEVSTACK_GATE_TEMPEST_REGEX
    elif [[ "$DEVSTACK_GATE_TEMPEST_ALL" -eq "1" ]]; then
        echo "Running tempest all test suite"
        sudo -H -u tempest tox -eall -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]]; then
        echo "Running tempest full test suite serially"
        sudo -H -u tempest tox -efull-serial
    elif [[ "$DEVSTACK_GATE_TEMPEST_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite"
        sudo -H -u tempest tox -efull -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_TEMPEST_TESTR_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite with testr"
        sudo -H -u tempest tox -etestr-full -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_TEMPEST_STRESS" -eq "1" ]] ; then
        echo "Running stress tests"
        sudo -H -u tempest tox -estress
    elif [[ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]] ; then
        echo "Running slow heat tests"
        sudo -H -u tempest tox -eheat-slow -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -ge "1" ]] ; then
        echo "Running large ops tests"
        sudo -H -u tempest tox -elarge-ops -- --concurrency=$TEMPEST_CONCURRENCY
    elif [[ "$DEVSTACK_GATE_SMOKE_SERIAL" -eq "1" ]] ; then
        echo "Running tempest smoke tests"
        sudo -H -u tempest tox -esmoke-serial
    else
        echo "Running tempest smoke tests"
        sudo -H -u tempest tox -esmoke -- --concurrency=$TEMPEST_CONCURRENCY
    fi

    if [[ "$DEVSTACK_GATE_CLEAN_LOGS" -eq "0" ]] ; then
        # if we don't want to enforce clean logs, just turn off
        # errexit on this final command
        set +o errexit
    fi

    echo "Running log checker"
    tools/check_logs.py -d $BASE/new/screen-logs


else
    # Jenkins expects at least one nosetests file.  If we're not running
    # tempest, then write a fake one that indicates the tests pass (since
    # we made it past exercise.sh.
    cat > $WORKSPACE/nosetests-fake.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?><testsuite name="nosetests" tests="0" errors="0" failures="0" skip="0"></testsuite>
EOF
fi
