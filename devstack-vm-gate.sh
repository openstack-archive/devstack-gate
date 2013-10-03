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

function setup_localrc() {
    LOCALRC_OLDNEW=$1;
    LOCALRC_BRANCH=$2;

    # Allow calling context to pre-populate the localrc file
    # with additional values
    if [ -z $KEEP_LOCALRC ] ; then
        rm -f localrc
    fi

    DEFAULT_ENABLED_SERVICES=g-api,g-reg,key,n-api,n-crt,n-obj,n-cpu,n-sch,horizon,mysql,rabbit,sysstat

    # Allow optional injection of ENABLED_SERVICES from the calling context
    if [ -z $ENABLED_SERVICES ] ; then
        MY_ENABLED_SERVICES=$DEFAULT_ENABLED_SERVICES
    else
        MY_ENABLED_SERVICES=$DEFAULT_ENABLED_SERVICES,$ENABLED_SERVICES
    fi

    if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
        MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,tempest
    fi

    SKIP_EXERCISES=boot_from_volume,client-env

    if [ "$LOCALRC_BRANCH" == "stable/folsom" ]; then
        MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-net,swift
        if [ "$DEVSTACK_GATE_CINDER" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,cinder,c-api,c-vol,c-sch
        else
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-vol
        fi
    elif [ "$LOCALRC_BRANCH" == "stable/grizzly" ]; then
        MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,s-proxy,s-account,s-container,s-object,cinder,c-api,c-vol,c-sch,n-cond
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
    else # master
        MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,s-proxy,s-account,s-container,s-object,cinder,c-api,c-vol,c-sch,c-bak,n-cond,heat,h-api,h-api-cfn,h-api-cw,h-eng,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api
        if [ "$DEVSTACK_GATE_NEUTRON" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta,q-lbaas
            echo "Q_USE_DEBUG_COMMAND=True" >>localrc
            echo "NETWORK_GATEWAY=10.1.0.1" >>localrc
        else
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-net
        fi
        if [ "$DEVSTACK_GATE_CELLS" -eq "1" ]; then
            MY_ENABLED_SERVICES=$MY_ENABLED_SERVICES,n-cell
        fi
        # When uncommented this will download and register the most recent successfully built
        # ubuntu-vm-heat-cfntools image from jenkins.tripleo.org
        # echo "IMAGE_URLS+=,\"http://jenkins.tripleo.org:8080/job/autobuilt-images/elements=ubuntu%20vm%20heat-cfntools/lastSuccessfulBuild/artifact/ubuntu-vm-heat-cfntools.qcow2\"" >>localrc
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
CINDER_PERIODIC_INTERVAL=10
export OS_NO_CACHE=True
EOF

    if [ "$DEVSTACK_CINDER_SECURE_DELETE" -eq "0" ]; then
        echo "CINDER_SECURE_DELETE=False" >>localrc
    fi

    if [ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]; then
        echo "HEAT_CREATE_TEST_IMAGE=True" >>localrc
    fi

    if [ "$DEVSTACK_GATE_TEMPEST_COVERAGE" -eq "1" ] ; then
        echo "EXTRA_OPTS=(backdoor_port=0)" >>localrc
    fi

    if [ "$DEVSTACK_GATE_POSTGRES" -eq "1" ]; then
        cat <<\EOF >>localrc
disable_service mysql
enable_service postgresql
EOF
    fi

    if [ "$DEVSTACK_GATE_ZEROMQ" -eq "1" ]; then
        cat <<\EOF >>localrc
disable_service rabbit
enable_service zeromq
EOF
    fi

    if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
        echo "SKIP_EXERCISES=${SKIP_EXERCISES},volumes" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=m1.small" >>localrc
        echo "DEFAULT_INSTANCE_USER=root" >>localrc
        echo "DEFAULT_INSTANCE_TYPE=m1.small" >>exerciserc
        echo "DEFAULT_INSTANCE_USER=root" >>exerciserc
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

    if [ "$DEVSTACK_GATE_TEMPEST_ALLOW_TENANT_ISOLATION" -eq "1" ]; then
        echo "TEMPEST_ALLOW_TENANT_ISOLATION=True" >>localrc
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
        echo "TEMPEST_LARGE_OPS_NUMBER=150" >>localrc
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
TARGET_RUN_EXERCISES=False
TARGET_RUN_SMOKE=False
SAVE_DIR=\$BASE_RELEASE_DIR/save
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
    sudo -H -u stack ./stack.sh

    # provide a check that the right db was running
    if [ "$DEVSTACK_GATE_POSTGRES" -eq "1" ]; then
        if [ ! -d /var/log/postgresql ]; then
            echo "Postgresql should have been used, but there are no logs"
            exit 1
        fi
    else
        if [ ! -d /var/log/mysql ]; then
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
    if [ ! -f "$BASE/new/tempest/etc/tempest.conf" ]; then
        echo "Configuring tempest"
        cd $BASE/new/devstack
        sudo -H -u stack ./tools/configure_tempest.sh
    fi
    # under tempest issolation tempest will need to write .tox dir, log files
    sudo chown -R tempest:stack $BASE/new/tempest
    # our lock files are in data, so we need to be able to write over there
    sudo chown -R tempest:stack /opt/stack/data/tempest
    # ensure the cirros image files are accessible
    sudo chmod -R o+rx /opt/stack/new/devstack/files/

    cd $BASE/new/tempest
    if [[ "$DEVSTACK_GATE_TEMPEST_ALL" -eq "1" ]]; then
        echo "Running tempest all test suite"
        sudo -H -u tempest tox -eall
    elif [[ "$DEVSTACK_GATE_TEMPEST_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite"
        sudo -H -u tempest tox -efull
    elif [[ "$DEVSTACK_GATE_TEMPEST_TESTR_FULL" -eq "1" ]]; then
        echo "Running tempest full test suite with testr"
        sudo -H -u tempest tox -etestr-full
    elif [[ "$DEVSTACK_GATE_TEMPEST_COVERAGE" -eq "1" ]] ; then
        echo "Generating coverage report"
        sudo -H -u tempest tox -ecoverage -- -o $BASE/new/tempest/coverage-report
    elif [[ "$DEVSTACK_GATE_TEMPEST_STRESS" -eq "1" ]] ; then
        echo "Running stress tests"
        sudo -H -u tempest tox -estress
    elif [[ "$DEVSTACK_GATE_TEMPEST_HEAT_SLOW" -eq "1" ]] ; then
        echo "Running slow heat tests"
        sudo -H -u tempest tox -eheat-slow
    elif [[ "$DEVSTACK_GATE_TEMPEST_LARGE_OPS" -eq "1" ]] ; then
        echo "Running large ops tests"
        sudo -H -u tempest tox -elarge-ops
    else
        echo "Running tempest smoke tests"
        sudo -H -u tempest tox -esmoke
    fi
else
    # Jenkins expects at least one nosetests file.  If we're not running
    # tempest, then write a fake one that indicates the tests pass (since
    # we made it past exercise.sh.
    cat > $WORKSPACE/nosetests-fake.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?><testsuite name="nosetests" tests="0" errors="0" failures="0" skip="0"></testsuite>
EOF
fi
