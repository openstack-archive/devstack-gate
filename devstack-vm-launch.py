#!/usr/bin/env python

# Make sure there are always a certain number of VMs launched and
# ready for use by devstack.

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
import getopt
import time
import paramiko
import traceback

import vmdatabase
import utils

PROVIDER_NAME = sys.argv[1]
DEVSTACK_GATE_PREFIX = os.environ.get('DEVSTACK_GATE_PREFIX', '')

ABANDON_TIMEOUT = 900   # assume a machine will never boot if it hasn't
                        # after this amount of time


def calculate_deficit(provider, base_image):
    # Count machines that are ready and machines that are building,
    # so that if the provider is very slow, we aren't queueing up tons
    # of machines to be built.
    num_to_launch = base_image.min_ready - (len(base_image.ready_machines) +
                                            len(base_image.building_machines))

    # Don't launch more than our provider max
    num_to_launch = min(provider.max_servers - len(provider.machines),
                        num_to_launch)

    # Don't launch less than 0
    num_to_launch = max(0, num_to_launch)

    print "Ready nodes:   ", len(base_image.ready_machines)
    print "Building nodes:", len(base_image.building_machines)
    print "Provider total:", len(provider.machines)
    print "Provider max:  ", provider.max_servers
    print "Need to launch:", num_to_launch

    return num_to_launch


def launch_node(client, snap_image, image, flavor, last_name):
    while True:
        name = '%sdevstack-%s.slave.openstack.org' % (
            DEVSTACK_GATE_PREFIX, int(time.time()))
        if name != last_name:
            break
        time.sleep(1)
    create_kwargs = dict(image=image, flavor=flavor, name=name)
    server = client.servers.create(**create_kwargs)
    machine = snap_image.base_image.newMachine(name=name,
                                               external_id=server.id)
    print "Started building machine %s:" % machine.id
    print "    id: %s" % (server.id)
    print "  name: %s" % (name)
    print
    return server, machine


def check_machine(client, machine, error_counts):
    try:
        server = client.servers.get(machine.external_id)
    except:
        print "Unable to get server detail, will retry"
        traceback.print_exc()
        return
    
    if server.status == 'ACTIVE':
        if 'os-floating-ips' in utils.get_extensions(client):
            utils.add_public_ip(server)
        ip = utils.get_public_ip(server)
        if not ip:
            raise Exception("Unable to find public ip of server")
        machine.ip = ip
        print "Machine %s is running, testing ssh" % machine.id
        if utils.ssh_connect(ip, 'jenkins'):
            print "Machine %s is ready" % machine.id
            machine.state = vmdatabase.READY
            return
    elif not server.status.startswith('BUILD'):
        count = error_counts.get(machine.id, 0)
        count += 1
        error_counts[machine.id] = count
        print "Machine %s is in error %s (%s/5)" % (machine.id,
                                                    server.status,
                                                    count)
        if count >= 5:
            raise Exception("Too many errors querying machine %s" % machine.id)
    else:
        if time.time() - machine.state_time >= ABANDON_TIMEOUT:
            raise Exception("Waited too long for machine %s" % machine.id)


def main():
    db = vmdatabase.VMDatabase()

    provider = db.getProvider(PROVIDER_NAME)
    print "Working with provider %s" % provider.name

    client = utils.get_client(provider)

    last_name = ''
    error_counts = {}
    error = False

    for base_image in provider.base_images:
        snap_image = base_image.current_snapshot
        if not snap_image:
            continue
        print "Working on image %s" % snap_image.name

        flavor = utils.get_flavor(client, base_image.min_ram)
        print "Found flavor", flavor

        remote_snap_image = client.images.get(snap_image.external_id)
        print "Found image", remote_snap_image

        num_to_launch = calculate_deficit(provider, base_image)
        for i in range(num_to_launch):
            try:
                server, machine = launch_node(client, snap_image,
                                              remote_snap_image, flavor, last_name)
                last_name = machine.name
            except:
                traceback.print_exc()
                error = True

    while True:
        building_machines = provider.building_machines
        if not building_machines:
            print "No more machines are building, finished."
            break

        print "Waiting on %s machines" % len(building_machines)
        for machine in building_machines:
            try:
                check_machine(client, machine, error_counts)
            except:
                traceback.print_exc()
                print "Abandoning machine %s" % machine.id
                machine.state = vmdatabase.ERROR
                error = True
            db.commit()

        time.sleep(3)

    if error:
        sys.exit(1)


if __name__ == '__main__':
    main()
