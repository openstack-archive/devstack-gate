#!/usr/bin/env python

# Remove old devstack VMs that have been given to developers.

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

import os
import sys
import time
import getopt
import traceback
import ConfigParser

import myjenkins
import vmdatabase
import utils
import novaclient
import re

NODE_NAME = sys.argv[1]
DEVSTACK_GATE_SECURE_CONFIG = os.environ.get('DEVSTACK_GATE_SECURE_CONFIG',
                                             os.path.expanduser(
                                             '~/devstack-gate-secure.conf'))
SKIP_DEVSTACK_GATE_JENKINS = os.environ.get('SKIP_DEVSTACK_GATE_JENKINS', None)
BUILD_URL = os.environ.get('BUILD_URL', '')

LABEL_RE = re.compile(r'<label>(.*)</label>')


def main():
    db = vmdatabase.VMDatabase()

    config = ConfigParser.ConfigParser()
    config.read(DEVSTACK_GATE_SECURE_CONFIG)

    if not SKIP_DEVSTACK_GATE_JENKINS:
        jenkins = myjenkins.Jenkins(config.get('jenkins', 'server'),
                                    config.get('jenkins', 'user'),
                                    config.get('jenkins', 'apikey'))
        jenkins.get_info()
    else:
        jenkins = None

    machine = db.getMachineByJenkinsName(NODE_NAME)
    utils.log.debug("Used ID: %s old state: %s build:%s" % (
            machine.id, machine.state, BUILD_URL))

    machine.state = vmdatabase.USED

    if jenkins:
        if machine.jenkins_name:
            if jenkins.node_exists(machine.jenkins_name):
                config = jenkins.get_node_config(machine.jenkins_name)
                old = None
                m = LABEL_RE.search(config)
                if m:
                    old = m.group(1)
                config = LABEL_RE.sub('<label>devstack-used</label>', config)
                for i in range(3):
                    try:
                        jenkins.reconfig_node(machine.jenkins_name, config)
                    except:
                        if i == 2:
                            utils.log.exception(
                                "Unable to relabel ID: %s" % machine.id)
                            raise
                        time.sleep(5)
                utils.log.debug(
                    "Relabeled ID: %s old label: %s new label: %s" % (
                    machine.id, old, 'devstack-used'))

    utils.update_stats(machine.base_image.provider)

if __name__ == '__main__':
    main()
