#!/bin/bash

# Gate commits to several projects on a VM running those projects
# configured by devstack.

# Copyright (C) 2011 OpenStack LLC.
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

set -o xtrace

fi
if [[ ! -e python-novaclient ]]; then
    git clone https://github.com/rackspace/python-novaclient.git
fi

for PROJECT in $PROJECTS
do
    echo "Setting up $PROJECT"
    SHORT_PROJECT=`basename $PROJECT`
    if [[ ! -e $SHORT_PROJECT ]]; then
	echo "  Need to clone"
	git clone https://review.openstack.org/p/$PROJECT
    fi
    cd $SHORT_PROJECT
    
    git remote update
    git checkout $GERRIT_BRANCH
    git reset --hard remotes/origin/$GERRIT_BRANCH

    if [[ $GERRIT_PROJECT == $PROJECT ]]; then
	echo "  Merging proposed change"
	git fetch https://review.openstack.org/p/$PROJECT $GERRIT_REFSPEC
	git merge FETCH_HEAD
    else
	echo "  Updating from origin"
	git pull --ff-only origin $GERRIT_BRANCH
    fi
    cd $WORKSPACE
done

python $CI_SCRIPT_DIR/devstack-vm-launch.py || exit $?
. $HOSTNAME.node.sh
rm $HOSTNAME.node.sh
scp -C -q $CI_SCRIPT_DIR/devstack-vm-gate-host.sh $ipAddr:
scp -C -q -r $WORKSPACE/ $ipAddr:workspace
ssh $ipAddr ./devstack-vm-gate-host.sh
RETVAL=$?
if [ $RETVAL = 0 ]; then
    echo "Deleting host"
    python $CI_SCRIPT_DIR/devstack-vm-delete.py
else
    echo "Giving host to developer"
    python $CI_SCRIPT_DIR/devstack-vm-give.py
fi
