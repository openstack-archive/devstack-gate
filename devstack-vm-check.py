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

PROVIDER_NAME = sys.argv[1]
DEVSTACK_GATE_SECURE_CONFIG = os.environ.get('DEVSTACK_GATE_SECURE_CONFIG',
                                             os.path.expanduser(
                                                '~/devstack-gate-secure.conf'))
SKIP_DEVSTACK_GATE_JENKINS = os.environ.get('SKIP_DEVSTACK_GATE_JENKINS', None)


def check_machine(jenkins, machine):
    utils.log.debug("Check ID: %s" % machine.id)

    try:
        if utils.ssh_connect(machine.ip, 'jenkins'):
            return
    except:
        utils.log.exception("Check failed ID: %s" % machine.id)
        utils.log.debug("Set deleted ID: %s old state: %s" % (
                machine.id, machine.state))
        machine.state = vmdatabase.DELETE
        if jenkins:
            if machine.jenkins_name:
                if jenkins.node_exists(machine.jenkins_name):
                    utils.log.debug("Delete jenkins node ID: %s" % machine.id)
                    jenkins.delete_node(machine.jenkins_name)

    machine.delete()


def main():
    db = vmdatabase.VMDatabase()

    if not SKIP_DEVSTACK_GATE_JENKINS:
        config = ConfigParser.ConfigParser()
        config.read(DEVSTACK_GATE_SECURE_CONFIG)

        jenkins = myjenkins.Jenkins(config.get('jenkins', 'server'),
                                    config.get('jenkins', 'user'),
                                    config.get('jenkins', 'apikey'))
        jenkins.get_info()
    else:
        jenkins = None

    provider = db.getProvider(PROVIDER_NAME)
    print "Working with provider %s" % provider.name

    error = False
    for machine in provider.machines:
        if machine.state != vmdatabase.READY:
            continue
        print 'Checking machine', machine.name
        try:
            check_machine(jenkins, machine)
        except:
            error = True
            traceback.print_exc()

    utils.update_stats(provider)
    if error:
        sys.exit(1)


if __name__ == '__main__':
    main()
