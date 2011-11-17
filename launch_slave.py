from libcloud.base import NodeImage, NodeSize, NodeLocation
from libcloud.types import Provider
from libcloud.providers import get_driver
from libcloud.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
from libcloud.dns.types import Provider as DnsProvider
from libcloud.dns.types import RecordType
from libcloud.dns.providers import get_driver as dns_get_driver
import os, sys
import getopt

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']
CLOUD_SERVERS_HOST = os.environ.get('CLOUD_SERVERS_HOST', None)
CLOUD_SERVERS_PATH = os.environ.get('CLOUD_SERVERS_PATH', None)

(option_pairs, args) = getopt.getopt(sys.argv[1:], '', ["image=", "nodns"])

DNS = True
for o,v in option_pairs:
    if o=='--nodns': 
      DNS = False

if len(args) == 0:
  print "Node Name required!"
  sys.exit(1)
host_name = args[0]
node_name = "%s.slave.openstack.org" % host_name

files={}
for key in ("slave_private_key", "slave_gpg_key", "slave_tarmac_key"):
    if os.path.exists(key):
        with open(key, "r") as private_key:
            files["/root/%s" % key] = private_key.read()

node_size = '3'
image_name = 'Ubuntu 11.04'
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
    node_type = 'ami-0000037e'
    node_size = 'standard.small'
    Driver = get_driver(Provider.EUCALYPTUS)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY,
                  host=CLOUD_SERVERS_HOST, path=CLOUD_SERVERS_PATH)
    image = NodeImage(id=node_type, name="", driver="")
    size = NodeSize(id=node_size, name="", ram=None, disk=None,
                    bandwidth=None, price=None, driver="")

# a simple script to install puppet post boot, can be much more complicated.
launch_script = """perl -ple 's/main/main universe/' -i /etc/apt/sources.list
apt-get update
apt-get -y --force-yes upgrade
apt-get install -y --force-yes git rubygems
gem install --no-rdoc --no-ri --version=1.6.0 facter
gem install --no-rdoc --no-ri --version=2.7.1 puppet
cd /root
git clone git://github.com/openstack/openstack-ci-puppet.git
cd openstack-ci-puppet
mv /root/slave_*_key modules/jenkins_slave/files/
/var/lib/gems/1.8/bin/puppet apply -l /tmp/manifest.log --modulepath=`pwd`/modules manifests/site.pp
"""

# a task that first installs the ssh key, and then runs the script
if CLOUD_SERVERS_DRIVER == 'rackspace':
    # read your public key in
    sd = SSHKeyDeployment(open(os.path.expanduser("~/.ssh/id_rsa.pub")).read())
    script = ScriptDeployment(launch_script)
    msd = MultiStepDeployment([sd, script])
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
    node = conn.deploy_node(name=node_name, image=image, size=size, deploy=msd,
                            ex_files=files)
    if DNS:
        dns_provider = dns_get_driver(DnsProvider.RACKSPACE_US)
        dns_ctx = dns_provider(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)
        
        domain_name = ".".join(node_name.split(".")[-2:])
        domain = [z for z in dns_ctx.list_zones() if z.domain == 'openstack.org'][0]

        records = [z for z in domain.list_records() if z == node_name]
        if len(records) == 0:
            domain.create_record(node_name, RecordType.A, node.public_ip[0])
        else:   
            records[0].update(data=node.public_ip[0])
else:
    node = conn.create_node(name=node_name, image=image, size=size,
                            ex_keyname=node_name, ex_userdata=launch_script)

with open("%s.node.sh" % node_name,"w") as node_file:
    node_file.write("ipAddr=%s\n" % node.public_ip[0])
    node_file.write("nodeId=%s\n" % node.id)
