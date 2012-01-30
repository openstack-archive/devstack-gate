#!/usr/bin/env python

# Turn over a devstack configured machine to the developer who
# proposed the change that is being tested.

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

from libcloud.compute.base import NodeImage, NodeSize, NodeLocation
from libcloud.compute.types import Provider
from libcloud.compute.providers import get_driver
from libcloud.compute.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
from libcloud.dns.types import Provider as DnsProvider
from libcloud.dns.types import RecordType
from libcloud.dns.providers import get_driver as dns_get_driver
import os, sys
import getopt
import paramiko

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']
CLOUD_SERVERS_HOST = os.environ.get('CLOUD_SERVERS_HOST', None)
CLOUD_SERVERS_PATH = os.environ.get('CLOUD_SERVERS_PATH', None)
DNS_CLOUD_SERVERS_USERNAME = os.environ.get('DNS_CLOUD_SERVERS_USERNAME',
                                            CLOUD_SERVERS_USERNAME)
DNS_CLOUD_SERVERS_API_KEY = os.environ.get('DNS_CLOUD_SERVERS_API_KEY',
                                           CLOUD_SERVERS_API_KEY)
def ssh(action, x):
    stdin, stdout, stderr = client.exec_command(x)
    print x
    output = ''
    for x in stdout:
        output += x
        sys.stdout.write(x)
    ret = stdout.channel.recv_exit_status()
    print stderr.read()
    if ret:
        raise Exception("Unable to %s" % action)
    return output

def scp(source, dest):
    print 'copy', source, dest
    ftp = client.open_sftp()
    ftp.put(source, dest)
    ftp.close()

(option_pairs, args) = getopt.getopt(sys.argv[1:], '', ["image=", "nodns"])

DNS = True
for o,v in option_pairs:
    if o=='--nodns': 
      DNS = False

if len(args) == 0:
  print "Node Name required!"
  sys.exit(1)
host_name = args[0]
node_name = "%s.openstack.org" % host_name


node_size = '3'
image_name = 'Ubuntu 11.10'
if CLOUD_SERVERS_DRIVER == 'rackspace':
    for (name, value) in option_pairs:
        if name == "--image":
            image_name = value

    Driver = get_driver(Provider.RACKSPACE)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)
    images = conn.list_images()

    size = [sz for sz in conn.list_sizes() if sz.id == node_size][0]
    image = [img for img in conn.list_images() if img.name == image_name][0]    

elif CLOUD_SERVERS_DRIVER == 'eucalyptus':
    node_type = 'ami-000004da'
    node_size = 'standard.small'
    Driver = get_driver(Provider.EUCALYPTUS)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY,
                  host=CLOUD_SERVERS_HOST, path=CLOUD_SERVERS_PATH)
    image = NodeImage(id=node_type, name="", driver="")
    size = NodeSize(id=node_size, name="", ram=None, disk=None,
                    bandwidth=None, price=None, driver="")


# a task that first installs the ssh key, and then runs the script
if CLOUD_SERVERS_DRIVER == 'rackspace':
    # read your public key in
    keypath = os.path.expanduser("~/.ssh/id_rsa.pub")
    if not os.path.exists(keypath):
        keypath = os.path.expanduser("~/.ssh/authorized_keys")
    sd = SSHKeyDeployment(open(keypath).read())
else:
    private_key_path = os.path.expanduser("~/.ssh/%s.pem" % node_name)
    if not os.path.exists(private_key_path):
        resp = conn.ex_create_keypair(name=node_name)
        key_material = resp.get('keyMaterial')
        if not key_material:
            print "Couldn't create keypair"
            sys.exit(1)
        with open(private_key_path, 'w') as private_key:
            private_key.write(key_material + '\n')
        os.chmod(private_key_path, 0600)

# deploy_node takes the same base keyword arguments as create_node.
if CLOUD_SERVERS_DRIVER == 'rackspace':
    print "Deploying %s" % node_name
    node = conn.deploy_node(name=node_name, image=image, size=size, deploy=sd)
else:
    node = conn.create_node(name=node_name, image=image, size=size,
                            ex_keyname=node_name, ex_userdata=launch_script)

if DNS:
    dns_provider = dns_get_driver(DnsProvider.RACKSPACE_US)
    dns_ctx = dns_provider(DNS_CLOUD_SERVERS_USERNAME,
                           DNS_CLOUD_SERVERS_API_KEY)
    
    host_shortname= host_name
    domain = [z for z in dns_ctx.list_zones() if z.domain == 'openstack.org'][0]

    records = [z for z in domain.list_records() if z == host_shortname]
    if len(records) == 0:
        domain.create_record(host_shortname, RecordType.A, node.public_ip[0])
    else:   
        records[0].update(data=node.public_ip[0])

with open("%s.node.sh" % node_name,"w") as node_file:
    node_file.write("ipAddr=%s\n" % node.public_ip[0])
    node_file.write("nodeId=%s\n" % node.id)

client = paramiko.SSHClient()
client.load_system_host_keys()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(node.public_ip[0])

if CLOUD_SERVERS_DRIVER == 'eucalyptus':
    ssh("set hostname", "hostname %s" % node_name)

ssh("update apt cache", "apt-get update")
ssh("upgrading system packages", "apt-get -y --force-yes upgrade")
ssh("install git and puppet", "apt-get install -y --force-yes git puppet")
ssh("clone puppret repo",
    "git clone https://review.openstack.org/p/openstack/openstack-ci-puppet.git /root/openstack-ci-puppet")

ssh("run puppet", "puppet apply --modulepath=/root/openstack-ci-puppet/modules /root/openstack-ci-puppet/manifests/site.pp")

client.close()
