#!/usr/bin/env python

# Update the base image that is used for devstack VMs.

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

import sys
import os
import openstack.compute
import commands
import time

USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
API_KEY = os.environ['CLOUD_SERVERS_API_KEY']

SERVER_NAME = 'devstack-oneiric.slave.openstack.org'
IMAGE_NAME = 'devstack-oneiric'

compute = openstack.compute.Compute(username=USERNAME, apikey=API_KEY, 
                                    cloud_api='RACKSPACE')

print "Searching for %s server" % SERVER_NAME
node = compute.servers.find(name=SERVER_NAME)
print "Searching for %s image" % IMAGE_NAME
try:
    image = compute.images.find(name=IMAGE_NAME)
except openstack.compute.exceptions.NotFound:
    image = None

stat, out = commands.getstatusoutput("ssh %s sudo apt-get -y dist-upgrade" % 
                                     node.public_ip)
if stat: 
    print out
    raise Exception("Unable to upgrade server")
stat, out = commands.getstatusoutput("ssh %s sudo /etc/init.d/mysql stop" % 
                                     node.public_ip)
if stat: 
    print out
    raise Exception("Unable to stop mysql")
stat, out = commands.getstatusoutput("ssh %s sudo /etc/init.d/rabbitmq-server stop" % 
                                     node.public_ip)
if stat: 
    print out
    raise Exception("Unable to stop rabbitmq")

if image:
    image.delete()
image = compute.images.create(name=IMAGE_NAME, server=node)

last_status = None
while True:
    if image.status != last_status:
        print 
        print time.ctime(), image.status,
        last_status = image.status
    if image.status == u'ACTIVE':
        break
    sys.stdout.write('.')
    sys.stdout.flush()
    time.sleep(1)
    image = compute.images.get(image.id)
