#!/usr/bin/env python

# Launch a VM for use by devstack.

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

from libcloud.base import NodeImage, NodeSize, NodeLocation
from libcloud.types import Provider
from libcloud.providers import get_driver
from libcloud.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
import libcloud
import os, sys
import getopt
import time

import vmdatabase

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']
CLOUD_SERVERS_HOST = os.environ.get('CLOUD_SERVERS_HOST', None)
CLOUD_SERVERS_PATH = os.environ.get('CLOUD_SERVERS_PATH', None)
IMAGE_NAME = 'devstack-oneiric'
MIN_RAM = 1024

CHANGE = os.environ['GERRIT_CHANGE_NUMBER']
PATCH = os.environ['GERRIT_PATCHSET_NUMBER']
BUILD = os.environ['BUILD_NUMBER']

db = vmdatabase.VMDatabase()
node_name = 'devstack-%s-%s-%s.slave.openstack.org' % (CHANGE, PATCH, BUILD)

if CLOUD_SERVERS_DRIVER == 'rackspace':
    Driver = get_driver(Provider.RACKSPACE)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)
    images = conn.list_images()

    sizes = [sz for sz in conn.list_sizes() if sz.ram >= MIN_RAM]
    sizes.sort(lambda a,b: cmp(a.ram, b.ram))
    size = sizes[0]
    image = [img for img in conn.list_images() if img.name==IMAGE_NAME][0]
else:
    raise Exception ("Driver not supported")

if CLOUD_SERVERS_DRIVER == 'rackspace':
    node = conn.create_node(name=node_name, image=image, size=size)
    # A private method, Tomaz Muraus says he's thinking of making it public
    node = conn._wait_until_running(node=node, wait_period=3,
                                    timeout=600)

print "Node ID:", node.id
print "Node IP:", node.public_ip[0]

db.addMachine(node.id, node_name, node.public_ip[0], CHANGE, PATCH, BUILD)

with open("%s.node.sh" % node_name,"w") as node_file:
  node_file.write("ipAddr=%s\n" % node.public_ip[0])
  node_file.write("nodeId=%s\n" % node.id)

