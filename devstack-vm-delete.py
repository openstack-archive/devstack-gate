#!/usr/bin/env python

# Delete a devstack VM.

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

import json
import os
import sys
from statsd import statsd
import traceback
import urllib

import vmdatabase
import utils

NODE_NAME = sys.argv[1]
UPSTREAM_BUILD_URL = os.environ.get('UPSTREAM_BUILD_URL', '')
UPSTREAM_JOB_NAME = os.environ.get('UPSTREAM_JOB_NAME', '')
UPSTREAM_BRANCH = os.environ.get('UPSTREAM_BRANCH', '')
BUILD_URL = os.environ.get('BUILD_URL', '')


def main():
    db = vmdatabase.VMDatabase()

    machine = db.getMachineByJenkinsName(NODE_NAME)
    if machine.state != vmdatabase.HOLD:
        utils.log.debug("Set deleted ID: %s old state: %s build: %s" % (
                machine.id, machine.state, BUILD_URL))
        machine.state = vmdatabase.DELETE
    else:
        utils.log.debug("Hold ID: %s old state: %s build: %s" % (
                machine.id, machine.state, BUILD_URL))

    try:
        utils.update_stats(machine.base_image.provider)

        if UPSTREAM_BUILD_URL:
            fd = urllib.urlopen(UPSTREAM_BUILD_URL + 'api/json')
            data = json.load(fd)
            result = data['result']
            if statsd and result == 'SUCCESS':
                dt = int(data['duration'])

                key = 'devstack.job.%s' % UPSTREAM_JOB_NAME
                statsd.timing(key + '.runtime', dt)
                statsd.incr(key + '.builds')

                key += '.%s' % UPSTREAM_BRANCH
                statsd.timing(key + '.runtime', dt)
                statsd.incr(key + '.builds')

                key += '.%s' % machine.base_image.provider.name
                statsd.timing(key + '.runtime', dt)
                statsd.incr(key + '.builds')
    except:
        print "Error getting build information"
        traceback.print_exc()

if __name__ == '__main__':
    main()
