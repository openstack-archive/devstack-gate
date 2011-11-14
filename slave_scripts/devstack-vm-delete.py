#!/usr/bin/env python

# Delete a devstack VM.

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
from libcloud.dns.types import Provider as DnsProvider
from libcloud.dns.types import RecordType
from libcloud.dns.providers import get_driver as dns_get_driver
import libcloud
import os, sys
import getopt
import time

import vmdatabase

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']

CHANGE = os.environ['GERRIT_CHANGE_NUMBER']
PATCH = os.environ['GERRIT_PATCHSET_NUMBER']
BUILD = os.environ['BUILD_NUMBER']

db = vmdatabase.VMDatabase()
machine = db.getMachine(CHANGE, PATCH, BUILD)
node_name = machine['name']

if CLOUD_SERVERS_DRIVER == 'rackspace':
    Driver = get_driver(Provider.RACKSPACE)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)
    node = [n for n in conn.list_nodes() if n.id==str(machine['id'])][0]

    dns_provider = dns_get_driver(DnsProvider.RACKSPACE_US)
    dns_ctx = dns_provider(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)

    domain_name = ".".join(node_name.split(".")[-2:])
    domain = [z for z in dns_ctx.list_zones() if z.domain == 'openstack.org'][0]

    records = [z for z in domain.list_records() if z == node_name]
    if records:
        records[0].delete()

    node.destroy()

db.delMachine(machine['id'])
