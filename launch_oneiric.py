import os, sys, time
import getopt

import clouddns
import openstack.compute


USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
API_KEY = os.environ['CLOUD_SERVERS_API_KEY']

compute = openstack.compute.Compute(username=USERNAME, apikey=API_KEY, cloud_api='RACKSPACE')

(option_pairs, args) = getopt.getopt(sys.argv[1:], [], ["distro="])

if len(args) == 0:
  print "Node Name required!"
  sys.exit(1)
node_name = args[0]

node = compute.servers.create(name=node_name, image=15330720, flavor=3)
while node.status != u'ACTIVE':
  print "sleep"
  time.sleep(1)
  node = compute.servers.get(node.id)

dns_ctx = clouddns.connection.Connection(USERNAME,
                                         API_KEY)
domain_name = ".".join(node_name.split(".")[-2:])
domain = dns_ctx.get_domain(name=domain_name)
try:
    record = domain.get_record(name=node_name)
except:
    record = None
if record is None:
    domain.create_record(node_name, node.public_ip, "A")
else:
    record.update(data=node.public_ip)

print "node ip", node.public_ip
with open("%s.node.sh" % node_name,"w") as node_file:
  node_file.write("ipAddr=%s\n" % node.public_ip)
  node_file.write("nodeId=%s\n" % node.id)
