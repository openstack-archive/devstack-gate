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

function setup_localrc() {
    LOCALRC_OLDNEW=$1;
    LOCALRC_BRANCH=$2;

    # Allow calling context to pre-populate the localrc file
    # with additional values
    if [ -z $KEEP_LOCALRC ] ; then
        rm -f localrc
    fi

    DEFAULT_ENABLED_SERVICES=g-api,g-reg,key,n-api,n-crt,n-obj,n-cpu,n-sch,horizon,mysql,rabbit,sysstat,dstat,pidstat
    DEFAULT_ENABLED_SERVICES+=,s-proxy,s-account,s-container,s-object,cinder,c-api,c-vol,c-sch,n-cond

    # Allow optional injection of ENABLED_SERVICES from the calling context
    if [ -z $ENABLED_SERVICES ] ; then
        MY_ENABLED_SERVICES=$DEFAULT_ENABLED_SERVICES
    else
        MY_ENABLED_SERVICES=$DEFAULT_ENABLED_SERVICES,$ENABLED_SERVICES
    fi

    if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
        MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,tempest
    fi

    # the exercises we *don't* want to test on for devstack
    SKIP_EXERCISES=boot_from_volume,bundle,client-env,euca

    if [ "$LOCALRC_BRANCH" == "stable/grizzly" ]; then
        SKIP_EXERCISES=${SKIP_EXERCISES},swift,client-args
        if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta
            echo "Q_USE_DEBUG_COMMAND=True" >>localrc
            echo "NETWORK_GATEWAY=10.1.0.1" >>localrc
        else
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-net
        fi
        if [ "$DEVSTACK_GATE_CELLS" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-cell
        fi
    elif [ "$LOCALRC_BRANCH" == "stable/havana" ]; then
        MY_ENABLED_SERVICES+=,c-bak
        # we don't want to enable services for grenade that don't have upgrade support
        # otherwise they can break grenade, especially when they are projects like
        # ceilometer which inject code in other projects
        if [ "$DEVSTACK_GATE_GRENADE" -eq "1" ]; then
            SKIP_EXERCISES=${SKIP_EXERCISES},swift,client-args
        else
            MY_ENABLED_SERVICES+=,heat,h-api,h-api-cfn,h-api-cw,h-eng
            MY_ENABLED_SERVICES+=,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api
        fi
        if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta,q-lbaas,q-vpn,q-fwaas,q-metering
            echo "Q_USE_DEBUG_COMMAND=True" >>localrc
            echo "NETWORK_GATEWAY=10.1.0.1" >>localrc
        else
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-net
        fi
        if [ "$DEVSTACK_GATE_CELLS" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-cell
        fi
    else # master
        MY_ENABLED_SERVICES+=,c-bak
        # we don't want to enable services for grenade that don't have upgrade support
        # otherwise they can break grenade, especially when they are projects like
        # ceilometer which inject code in other projects
        if [ "$DEVSTACK_GATE_GRENADE" -ne "1" ]; then
            MY_ENABLED_SERVICES+=,heat,h-api,h-api-cfn,h-api-cw,h-eng
            MY_ENABLED_SERVICES+=,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification
            MY_ENABLED_SERVICES+=trove,tr-api,tr-tmgr,tr-cond
        fi
        if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta,q-lbaas,q-vpn,q-fwaas,q-metering
            echo "Q_USE_DEBUG_COMMAND=True" >>localrc
            echo "NETWORK_GATEWAY=10.1.0.1" >>localrc
        else
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-net
        fi
        if [ "$DEVSTACK_GATE_NOVA_API_METADATA_SPLIT" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-api-meta
        fi
        if [ "$DEVSTACK_GATE_CELLS" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-cell
        fi
        if [ "$DEVSTACK_GATE_MARCONI" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,marconi-server
        fi
        if [ "$DEVSTACK_GATE_IRONIC" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,ir-api,ir-cond
        fi
        if [ "$DEVSTACK_GATE_SAHARA" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,sahara
        fi
    fi

    cat <<EOF >>localrc
DEST=$BASE/$LOCALRC_OLDNEW
ACTIVE_TIMEOUT=90
BOOT_TIMEOUT=90
ASSOCIATE_TIMEOUT=60
TERMINATE_TIMEOUT=60
MYSQL_PASSWORD=secret
DATABASE_PASSWORD=secret
RABBIT_PASSWORD=secret
ADMIN_PASSWORD=secret
SERVICE_PASSWORD=secret
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
FIXED_RANGE=10.1.0.0/24
FIXED_NETWORK_SIZE=256
VIRT_DRIVER=$DEVSTACK_GATE_VIRT_DRIVER
SWIFT_REPLICAS=1
LOG_COLOR=False
PIP_USE_MIRRORS=False
USE_GET_PIP=1
# Don't reset the requirements.txt files after g-r updates
UNDO_REQUIREMENTS=False
CINDER_PERIODIC_INTERVAL=10
CEILOMETER_PIPELINE_INTERVAL=15
export OS_NO_CACHE=True
EOF

    if [ "$DEVSTACK_CINDER_SECURE_DELETE" -eq "0" ]; then
        echo "CINDER_SECURE_DELETE=False" >>localrc
    fi

    if [ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]; then
        echo "HEAT_CREATE_TEST_IMAGE=False" >>localrc
        # Use Fedora 20 for heat test image, it has heat-cfntools pre-installed
        echo "HEAT_FETCHED_TEST_IMAGE=Fedora-i386-20-20131211.1-sda" >>localrc
    fi

    if [ "$DEVSTACK_GATE_POSTGRES" -eq "1" ]; then
        cat <<\EOF >>localrc
disable_service mysql
enable_service postgresql
EOF
    fi

    if [ "$DEVSTACK_GATE_MQ_DRIVER" == "zeromq" ]; then
        echo "disable_service rabbit" >>localrc
        echo "enable_service zeromq" >>localrc
    elif [ "$DEVSTACK_GATE_MQ_DRIVER" == "qpid" ]; then
        echo "disable_service rabbit" >>localrc
        echo "enable_service qpid" >>localrc
    fi

    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
        echo "SKIP_EXERCISES=${SKIP_EXERCISES},volumes" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=m1.small" >>localrc
        echo "DEFAULT_INSTANCE_USER=root" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=m1.small" >>exerciserc
        echo "DEFAULT_INSTANCE_USER=root" >>exerciserc
    fi

    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "ironic" ]; then
        echo "VIRT_DRIVER=ironic" >>localrc
        echo "IRONIC_BAREMETAL_BASIC_OPS=True" >>localrc
    fi

    if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
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

    if [ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]; then
        echo "TEMPEST_ALLOW_TENANT_ISOLATION=False" >>localrc
    fi

    if [ "$DEVSTACK_GATE_GRENADE" -eq "1" ]; then
        echo "DATA_DIR=/opt/stack/data" >> localrc
        echo "SWIFT_DATA_DIR=/opt/stack/data/swift" >> localrc
        if [ "$LOCALRC_OLDNEW" == "old" ]; then
            echo "GRENADE_PHASE=base" >> localrc
        else
            echo "GRENADE_PHASE=target" >> localrc
        fi
    else
        # Grenade needs screen, so only turn this off if we aren't
        # running grenade.
        echo "USE_SCREEN=False" >>localrc
    fi

    if [ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -eq "1" ]; then
        # use fake virt driver and 10 copies of nova-compute
        echo "VIRT_DRIVER=fake" >> localrc
        # To make debugging easier, disabled until bug 1218575 is fixed.
        # echo "NUMBER_FAKE_NOVA_COMPUTE=10" >>localrc
        echo "TEMPEST_LARGE_OPS_NUMBER=50" >>localrc
    fi

    if [ "$DEVSTACK_GATE_CONFIGDRIVE" -eq "1" ]; then
        echo "FORCE_CONFIG_DRIVE=always" >>localrc
    else
        echo "FORCE_CONFIG_DRIVE=False" >>localrc
    fi
}

if [ "$DEVSTACK_GATE_GRENADE" -eq "1" ]; then
    cd $BASE/old/devstack
    setup_localrc "old" "$GRENADE_OLD_BRANCH"

    cd $BASE/new/devstack
    setup_localrc "new" "$GRENADE_OLD_BRANCH"

    cat <<EOF >$BASE/new/grenade/localrc
BASE_RELEASE=old
BASE_RELEASE_DIR=$BASE/\$BASE_RELEASE
BASE_DEVSTACK_DIR=\$BASE_RELEASE_DIR/devstack
TARGET_RELEASE=new
TARGET_RELEASE_DIR=$BASE/\$TARGET_RELEASE
TARGET_DEVSTACK_DIR=\$TARGET_RELEASE_DIR/devstack
TARGET_RUN_SMOKE=False
SAVE_DIR=\$BASE_RELEASE_DIR/save
DO_NOT_UPGRADE_SERVICES=$DO_NOT_UPGRADE_SERVICES
EOF
    # Make the workspace owned by the stack user
    sudo chown -R stack:stack $BASE

    cd $BASE/new/grenade
    echo "Running grenade ..."
    sudo -H -u stack ./grenade.sh
    cd $BASE/new/devstack

else
    cd $BASE/new/devstack
    setup_localrc "new" "$ZUUL_BRANCH"

    # Make the workspace owned by the stack user
    sudo chown -R stack:stack $BASE

    echo "Running devstack"
    echo "... this takes 5 - 8 minutes (logs in logs/devstacklog.txt.gz)"
    sudo -H -u stack stdbuf -oL -eL ./stack.sh > /dev/null

    # provide a check that the right db was running
    # the path are different for fedora and red hat.
    if [ -f /usr/bin/yum ]; then
        POSTGRES_LOG_PATH="-d /var/lib/pgsql"
        MYSQL_LOG_PATH="-f /var/lib/mysqld.log"
    else
        POSTGRES_LOG_PATH="-d /var/log/postgresql"
        MYSQL_LOG_PATH="-d /var/log/mysql"
    fi
    if [ "$DEVSTACK_GATE_POSTGRES" -eq "1" ]; then
        if [ ! $POSTGRES_LOG_PATH ]; then
            echo "Postgresql should have been used, but there are no logs"
            exit 1
        fi
    else
        if [ ! $MYSQL_LOG_PATH ]; then
            echo "Mysql should have been used, but there are no logs"
            exit 1
        fi
    fi
fi

echo "Removing sudo privileges for devstack user"
sudo rm /etc/sudoers.d/50_stack_sh

if [ "$DEVSTACK_GATE_EXERCISES" -eq "1" ]; then
    echo "Running devstack exercises"
    sudo -H -u stack ./exercise.sh
fi

if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    # under tempest isolation tempest will need to write .tox dir, log files
    if [ -d "$BASE/new/tempest" ]; then
        sudo chown -R tempest:stack $BASE/new/tempest
    fi
    # our lock files are in data, so we need to be able to write over there
    if [ -d /opt/stack/data/tempest ]; then
        sudo chown -R tempest:stack /opt/stack/data/tempest
    fi
    # ensure the cirros image files are accessible
    if [ -d /opt/stack/new/devstack/files ]; then
        sudo chmod -R o+rx /opt/stack/new/devstack/files
    fi

    # let us control if we die or not
    set +o errexit

    cd $BASE/new/tempest
    if [[ "$DEVSTACK_GATE_TEMPEST_REGEX" != "" ]] ; then
        echo "Running tempest with a custom regex filter"
        sudo -H -u tempest tox -eall -- --concurrency=$TEMPEST_CONCURRENCY $DEVSTACK_GATE_TEMPEST_REGEX
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_ALL" -eq "1" ]]; then
        echo "Running tempest all test suite"
        sudo -H -u tempest tox -eall -- --concurrency=$TEMPEST_CONCURRENCY
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION" -eq "1" ]]; then
        echo "Running tempest full test suite serially"
        sudo -H -u tempest tox -efull-serial
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite"
        sudo -H -u tempest tox -efull -- --concurrency=$TEMPEST_CONCURRENCY
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_TESTR_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite with testr"
        sudo -H -u tempest tox -etestr-full -- --concurrency=$TEMPEST_CONCURRENCY
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_STRESS" -eq "1" ]] ; then
        echo "Running stress tests"
        sudo -H -u tempest tox -estress
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]] ; then
        echo "Running slow heat tests"
        sudo -H -u tempest tox -eheat-slow -- --concurrency=$TEMPEST_CONCURRENCY
        res=$?
    elif [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -eq "1" ]] ; then
        echo "Running large ops tests"
        sudo -H -u tempest tox -elarge-ops -- --concurrency=$TEMPEST_CONCURRENCY
        res=$?
    elif [[ "$DEVSTACK_GATE_SMOKE_SERIAL" -eq "1" ]] ; then
        echo "Running tempest smoke tests"
        sudo -H -u tempest tox -esmoke-serial
        res=$?
    else
        echo "Running tempest smoke tests"
        sudo -H -u tempest tox -esmoke -- --concurrency=$TEMPEST_CONCURRENCY
        res=$?
    fi

    if [[ "$GRENADE_OLD_BRANCH" != "stable/grizzly" ]] && \
       [[ "$DEVSTACK_GATE_TEMPEST_STRESS" -ne "1" ]] ; then
        tools/check_logs.py -d $BASE/new/screen-logs
        res2=$?
    fi
    # TODO(sdague): post icehouse-2 we can talk about turning
    # this back on, but right now it is violating the do no harm
    # principle.
    # [[ $res -eq 0 && $res2 -eq 0 ]]
    # exit $?
    exit $res

else
    # Jenkins expects at least one nosetests file.  If we're not running
    # tempest, then write a fake one that indicates the tests pass (since
    # we made it past exercise.sh.
    cat > $WORKSPACE/nosetests-fake.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?><testsuite name="nosetests" tests="0" errors="0" failures="0" skip="0"></testsuite>
EOF
fi
