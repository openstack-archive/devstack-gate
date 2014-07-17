#!/bin/bash

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

set -x
GIT_BASE=${GIT_BASE:-https://git.openstack.org}
GIT_BRANCH=${GIT_BRANCH:-master}

source $WORKSPACE/devstack-gate/functions.sh

export BASE=/opt/stack

# Make a directory to store logs
rm -rf $WORKSPACE/logs
mkdir -p $WORKSPACE/logs

echo "Available disk space on this host:"
indent df -h

echo "Setting up the host"
echo "... this takes a few seconds (logs at logs/node_ip/devstack-gate-setup-host.txt.gz)"
tsfilter setup_host &> $WORKSPACE/logs/devstack-gate-setup-host.txt

if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
    echo "Setting up the new (migrate to) workspace"
    echo "... this takes 3 - 5 minutes (logs at logs/node_ip/devstack-gate-setup-workspace-new.txt.gz)"
    tsfilter setup_workspace "$GRENADE_NEW_BRANCH" "$BASE/new" copycache &> \
        $WORKSPACE/logs/devstack-gate-setup-workspace-new.txt
    echo "Setting up the old (migrate from) workspace ..."
    echo "... this takes 3 - 5 minutes (logs at logs/node_ip/devstack-gate-setup-workspace-old.txt.gz)"
    tsfilter setup_workspace "$GRENADE_OLD_BRANCH" "$BASE/old" &> \
        $WORKSPACE/logs/devstack-gate-setup-workspace-old.txt
else
    echo "Setting up the workspace"
    echo "... this takes 3 - 5 minutes (logs at logs/node_ip/devstack-gate-setup-workspace-new.txt.gz)"
    tsfilter setup_workspace "$OVERRIDE_ZUUL_BRANCH" "$BASE/new" &> \
        $WORKSPACE/logs/devstack-gate-setup-workspace-new.txt
fi

mkdir -p $BASE/new/.ssh
sudo cp /etc/nodepool/id_rsa.pub $BASE/new/.ssh/authorized_keys
sudo chmod 600 $BASE/new/.ssh/authorized_keys

# relocate and symlink logs into $BASE to save space on the root filesystem
if [ -d "$WORKSPACE/logs" -a \! -e "$BASE/logs" ]; then
    sudo mv $WORKSPACE/logs $BASE/
    ln -s $BASE/logs $WORKSPACE/
fi

# Run pre test hook if we have one
if function_exists "pre_test_hook"; then
  echo "Running pre_test_hook"
  xtrace=$(set +o | grep xtrace)
  set -o xtrace
  tsfilter pre_test_hook | tee $WORKSPACE/devstack-gate-pre-test-hook.txt
  sudo mv $WORKSPACE/devstack-gate-pre-test-hook.txt $BASE/logs/
  $xtrace
fi
