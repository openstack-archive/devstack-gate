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

# Important to set DEST so that devstack uses our prepared sources.
export DEST=$WORKSPACE
cd $DEST/devstack

ENABLED_SERVICES=g-api,g-reg,key,n-api,n-crt,n-obj,n-cpu,n-net,n-vol,n-sch,horizon,mysql,rabbit

if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    ENABLED_SERVICES=$ENABLED_SERVICES,tempest
fi

cat <<EOF >localrc
ACTIVE_TIMEOUT=60
BOOT_TIMEOUT=90
ASSOCIATE_TIMEOUT=60
MYSQL_PASSWORD=secret
RABBIT_PASSWORD=secret
ADMIN_PASSWORD=secret
SERVICE_PASSWORD=secret
SERVICE_TOKEN=111222333444
SWIFT_HASH=1234123412341234
ROOTSLEEP=0
ENABLED_SERVICES=$ENABLED_SERVICES
SKIP_EXERCISES=boot_from_volume,client-env,swift
SERVICE_HOST=127.0.0.1
SYSLOG=True
SCREEN_LOGDIR=$WORKSPACE/screen-logs
FIXED_RANGE=10.1.0.0/24
FIXED_NETWORK_SIZE=256
EOF

if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    # We need to disable ratelimiting when running
    # Tempest tests since so many requests are executed
    echo "API_RATE_LIMIT=False" >> localrc
    # Volume tests in Tempest require a number of volumes
    # to be created, each of 1G size. Devstack's default
    # volume backing file size is 2G, so we increase to 4G
    echo "VOLUME_BACKING_FILE_SIZE=4G" >> localrc
fi

echo "Running devstack"
./stack.sh
if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    echo "Configuring tempest"
    ./tools/configure_tempest.sh
    cd $WORKSPACE/tempest
    echo "Running tempest"
    nosetests --with-xunit -sv $DEVSTACK_GATE_TEMPEST_TESTS
else
    echo "Running devstack exercises"
    ./exercise.sh
fi
