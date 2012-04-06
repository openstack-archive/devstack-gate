#!/usr/bin/env python

# Fetch a ready VM for use by devstack.

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

import sys
import os

import vmdatabase

IMAGE_NAME = sys.argv[1]

def main():
    db = vmdatabase.VMDatabase()
    node = db.getMachineForUse(IMAGE_NAME)
    if not node:
        raise Exception("No ready nodes")

    job_name = os.environ.get('JOB_NAME', None)
    build_number = os.environ.get('BUILD_NUMBER', None)
    gerrit_change = os.environ.get('GERRIT_CHANGE_NUMBER', None)
    gerrit_patchset = os.environ.get('GERRIT_PATCHSET_NUMBER', None)
    if job_name and build_number and gerrit_change and gerrit_patchset:
        result = node.newResult(job_name, build_number, gerrit_change, gerrit_patchset)
    else:
        result = None

    print "NODE_IP_ADDR=%s" % node.ip
    print "NODE_PROVIDER=%s" % node.base_image.provider.name
    print "NODE_ID=%s" % node.id
    if result:
        print "RESULT_ID=%s" % result.id

if __name__ == "__main__":
    main()
