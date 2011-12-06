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

from libcloud.base import NodeImage, NodeSize, NodeLocation
from libcloud.types import Provider
from libcloud.providers import get_driver
from libcloud.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
from libcloud.dns.types import Provider as DnsProvider
from libcloud.dns.types import RecordType
from libcloud.dns.providers import get_driver as dns_get_driver
import libcloud
import sys
import os
import commands
import time
import paramiko

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']

SERVER_NAME = 'devstack-oneiric.template.openstack.org'
IMAGE_NAME = 'devstack-oneiric'

debs = ' '.join(open(sys.argv[1]).read().split('\n'))
pips = ' '.join(open(sys.argv[2]).read().split('\n'))

if CLOUD_SERVERS_DRIVER == 'rackspace':
    Driver = get_driver(Provider.RACKSPACE)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)
    
    print "Searching for %s server" % SERVER_NAME
    node = [n for n in conn.list_nodes() if n.name==SERVER_NAME][0]

    print "Searching for %s image" % IMAGE_NAME
    image = [img for img in conn.list_images() if img.name==IMAGE_NAME]
    if image: 
        image = image[0]
    else: 
        image = None
else:
    raise Exception ("Driver not supported")

ip = node.public_ip[0]
client = paramiko.SSHClient()
client.load_system_host_keys()
client.set_missing_host_key_policy(paramiko.WarningPolicy())
client.connect(ip)

def run(action, x):
    stdin, stdout, stderr = client.exec_command(x)
    print x
    ret = stdout.channel.recv_exit_status()
    print stdout.read()
    print stderr.read()
    if ret:
        raise Exception("Unable to %s" % action)

run('update package list', 'sudo apt-get update')
run('install packages', 'sudo DEBIAN_FRONTEND=noninteractive apt-get --option "Dpkg::Options::=--force-confold" --assume-yes install %s' % debs)
run('install pips', 'sudo pip install %s' % pips)
run('upgrade server', 'sudo apt-get -y dist-upgrade')
run('run puppet', 'sudo bash -c "cd /root/openstack-ci-puppet && /usr/bin/git pull -q && /var/lib/gems/1.8/bin/puppet apply -l /tmp/manifest.log --modulepath=/root/openstack-ci-puppet/modules manifests/site.pp"')
run('stop mysql', 'sudo /etc/init.d/mysql stop')
run('stop rabbitmq', 'sudo /etc/init.d/rabbitmq-server stop')

if image:
    conn.ex_delete_image(image)

image = conn.ex_save_image(node=node, name=IMAGE_NAME)

last_extra = None
while True:
    image = [img for img in conn.list_images(ex_only_active=False) 
             if img.name==IMAGE_NAME][0]
    if image.extra != last_extra:
        print image.extra['status'], image.extra['progress']
    if image.extra['status'] == 'ACTIVE': 
        break
    last_extra = image.extra
    time.sleep(2)
