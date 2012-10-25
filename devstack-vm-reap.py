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

PROVIDER_NAME = sys.argv[1]
MACHINE_LIFETIME = 24 * 60 * 60  # Amount of time after being used
DEVSTACK_GATE_SECURE_CONFIG = os.environ.get('DEVSTACK_GATE_SECURE_CONFIG',
                                             os.path.expanduser(
                                                '~/devstack-gate-secure.conf'))
SKIP_DEVSTACK_GATE_JENKINS = os.environ.get('SKIP_DEVSTACK_GATE_JENKINS', None)

if '--all-servers' in sys.argv:
    print "Reaping all known machines"
    REAP_ALL_SERVERS = True
else:
    REAP_ALL_SERVERS = False

if '--all-images' in sys.argv:
    print "Reaping all known images"
    REAP_ALL_IMAGES = True
else:
    REAP_ALL_IMAGES = False


def delete_machine(jenkins, client, machine):
    try:
        server = client.servers.get(machine.external_id)
    except novaclient.exceptions.NotFound:
        print '  Machine id %s not found' % machine.external_id
        server = None

    if server:
        utils.delete_server(server)
        # Rackspace Nova sometimes lies about whether a server is deleted.
        # If we have deleted a server, don't believe it.  Instead, wait for
        # the next run of the script and only if the server doesn't exist,
        # delete it from Jenkins and the DB.
        return

    if jenkins:
        if machine.jenkins_name:
            if jenkins.node_exists(machine.jenkins_name):
                jenkins.delete_node(machine.jenkins_name)

    machine.delete()


def delete_image(client, image):
    try:
        server = client.servers.get(image.server_external_id)
    except novaclient.exceptions.NotFound:
        print '  Image server id %s not found' % image.server_external_id
        server = None

    if server:
        utils.delete_server(server)
        # Rackspace Nova sometimes lies about whether a server is deleted.
        # If we have deleted a server, don't believe it.  Instead, wait for
        # the next run of the script and only if the server doesn't exist,
        # delete it from Jenkins and the DB.
        return

    try:
        remote_image = client.images.get(image.external_id)
    except novaclient.exceptions.NotFound:
        print '  Image id %s not found' % image.external_id
        remote_image = None

    if remote_image:
        remote_image.delete()

    image.delete()


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

    print 'Known machines (start):'
    db.print_state()

    provider = db.getProvider(PROVIDER_NAME)
    print "Working with provider %s" % provider.name

    client = utils.get_client(provider)

    flavor = utils.get_flavor(client, 1024)
    print "Found flavor", flavor

    error = False
    now = time.time()
    for machine in provider.machines:
        # Normally, reap machines that have sat in their current state
        # for 24 hours, unless that state is READY.
        if (REAP_ALL_SERVERS or
            (machine.state != vmdatabase.READY and
             now - machine.state_time > MACHINE_LIFETIME) or
            machine.state == vmdatabase.DELETE or
            machine.state == vmdatabase.ERROR):
            print 'Deleting machine', machine.name
            try:
                delete_machine(jenkins, client, machine)
            except:
                error = True
                traceback.print_exc()

    provider_min_ready = 0
    for base_image in provider.base_images:
        provider_min_ready += base_image.min_ready
        for snap_image in base_image.snapshot_images:
            # Normally, reap images that have sat in their current state
            # for 24 hours, unless the image is the current snapshot
            if (REAP_ALL_IMAGES or
                (snap_image != base_image.current_snapshot and
                now - snap_image.state_time > MACHINE_LIFETIME)):
                print 'Deleting image', snap_image.name
                try:
                    delete_image(client, snap_image)
                except:
                    error = True
                    traceback.print_exc()

    print
    print 'Known machines (end):'
    db.print_state()

    utils.update_stats(provider)
    if error:
        sys.exit(1)


if __name__ == '__main__':
    main()
