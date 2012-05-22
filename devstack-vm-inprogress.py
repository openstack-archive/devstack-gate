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

NODE_NAME = sys.argv[1]
DEVSTACK_GATE_SECURE_CONFIG = os.environ.get('DEVSTACK_GATE_SECURE_CONFIG', 
                                             os.path.expanduser('~/devstack-gate-secure.conf'))


def main():
    db = vmdatabase.VMDatabase()

    config=ConfigParser.ConfigParser()
    config.read(DEVSTACK_GATE_SECURE_CONFIG)

    jenkins = myjenkins.Jenkins(config.get('jenkins', 'server'),
                                config.get('jenkins', 'user'),
                                config.get('jenkins', 'apikey'))
    jenkins.get_info()

    machine = db.getMachineByJenkinsName(NODE_NAME)
    machine.state = vmdatabase.USED

    if machine.jenkins_name:
        if jenkins.node_exists(machine.jenkins_name):
            jenkins.disable_node(machine.jenkins_name, "Devstack build started")
            

if __name__ == '__main__':
    main()
