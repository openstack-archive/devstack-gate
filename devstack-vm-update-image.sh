#!/bin/bash -xe

# Update the VM used in devstack deployments.

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

CI_SCRIPT_DIR=$(cd $(dirname "$0") && pwd)
cd $WORKSPACE

if [[ ! -e devstack ]]; then
    git clone https://review.openstack.org/p/openstack-dev/devstack
fi
cd devstack
git remote update
git remote prune origin
cd $WORKSPACE

$CI_SCRIPT_DIR/devstack-vm-update-image.py
