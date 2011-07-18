from libcloud.types import Provider
from libcloud.providers import get_driver
from libcloud.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
import os, sys

CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']
try:
  node_name = sys.argv[1]
except:
  print "Node Name required!"
  sys.exit(1)

node_manifest = "slave"
if len(sys.argv) > 2:
  node_manifest = sys.argv[2]

Driver = get_driver(Provider.RACKSPACE)
conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)

# read your public key in
sd = SSHKeyDeployment(open(os.path.expanduser("~/.ssh/id_rsa.pub")).read())
# a simple script to install puppet post boot, can be much more complicated.
script = ScriptDeployment("""
perl -ple 's,main,main universe,' -i /etc/apt/sources.list
apt-get update
apt-get install -y --force-yes git rubygems
gem install --no-rdoc --no-ri puppet
git clone git://github.com/openstack/openstack-ci-puppet.git
cd openstack-ci-puppet
ln -sf /root/openstack-ci-puppet/manifests/burrow.pp manifests/this.pp
/var/lib/gems/1.8/bin/puppet apply -l /tmp/manifest.log --modulepath=`pwd`/modules manifests/this.pp
""" % node_manifest)

# a task that first installs the ssh key, and then runs the script
msd = MultiStepDeployment([sd, script])


images = conn.list_images()

size = [sz for sz in conn.list_sizes() if sz.id == '3'][0]
image = [img for img in conn.list_images() if img.id == '76'][0]


# deploy_node takes the same base keyword arguments as create_node.
node = conn.deploy_node(name=node_name, image=image, size=size, deploy=msd)

with open("%s.node.sh" % node_name,"w") as node_file:
  node_file.write("ipAddr=%s\n" % node.public_ip[0])
  node_file.write("nodeId=%s\n" % node.id)
