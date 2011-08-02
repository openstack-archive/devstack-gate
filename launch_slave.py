from libcloud.types import Provider
from libcloud.providers import get_driver
from libcloud.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
import os, sys
import getopt

CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']

(option_pairs, args) = getopt.getopt(sys.argv[1:], [], ["distro="])

if len(args) == 0:
  print "Node Name required!"
  sys.exit(1)
node_name = args[0]

node_manifest = "slave"
node_type = '76'

if len(args) > 1:
  node_manifest = args[1]

for (name, value) in option_pairs:
  if name == "--distro":
    if value == "maverick":
      node_type = '69'
    if value == "natty":
      node_type = '76'

files={}
for key in ("slave_private_key", "slave_gpg_key", "slave_tarmac_key"):
  if os.path.exists(key):
    with open(key, "r") as private_key:
      files["/root/%s" % key] = private_key.read()

Driver = get_driver(Provider.RACKSPACE)
conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)

# read your public key in
sd = SSHKeyDeployment(open(os.path.expanduser("~/.ssh/id_rsa.pub")).read())
# a simple script to install puppet post boot, can be much more complicated.
script = ScriptDeployment("""
perl -ple 's/main/main universe/' -i /etc/apt/sources.list
apt-get update
apt-get -y --force-yes upgrade
apt-get install -y --force-yes git rubygems
gem install --no-rdoc --no-ri puppet
git clone git://github.com/openstack/openstack-ci-puppet.git
cd openstack-ci-puppet
mv /root/slave_*_key modules/jenkins_slave/files/
/var/lib/gems/1.8/bin/puppet apply -l /tmp/manifest.log --modulepath=`pwd`/modules manifests/site.pp
""" % node_manifest)

# a task that first installs the ssh key, and then runs the script
msd = MultiStepDeployment([sd, script])


images = conn.list_images()

size = [sz for sz in conn.list_sizes() if sz.id == '3'][0]
image = [img for img in conn.list_images() if img.id == node_type][0]


# deploy_node takes the same base keyword arguments as create_node.
node = conn.deploy_node(name=node_name, image=image, size=size, deploy=msd,
                        ex_files=files)

with open("%s.node.sh" % node_name,"w") as node_file:
  node_file.write("ipAddr=%s\n" % node.public_ip[0])
  node_file.write("nodeId=%s\n" % node.id)
