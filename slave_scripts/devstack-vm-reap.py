#!/usr/bin/env python

# Remove old devstack VMs that have been given to developers.

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

import os, sys, time
import getopt

from libcloud.base import NodeImage, NodeSize, NodeLocation
from libcloud.types import Provider
from libcloud.providers import get_driver
from libcloud.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
import libcloud

import vmdatabase

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']

db = vmdatabase.VMDatabase()

if CLOUD_SERVERS_DRIVER == 'rackspace':
    Driver = get_driver(Provider.RACKSPACE)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)

def delete(machine):
    node = [n for n in conn.list_nodes() if n.id==str(machine['id'])][0]
    node_name = machine['name']
    node.destroy()

    db.delMachine(machine['id'])

now = time.time()
for machine in db.getMachines():
  if now-machine['created'] > 24*60*60:
    print 'Deleting', machine['name']
    delete(machine)
