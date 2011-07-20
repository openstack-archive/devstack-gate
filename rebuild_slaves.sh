for slave in burrow libburrow burrow-java glance keystone openstack-ci; do
  source ${slave}.slave.openstack.org.node.sh
  cloudservers delete ${nodeId}
  python launch_slave.py ${slave}.slave.openstack.org `echo ${slave} | tr - _`
  source ${slave}.slave.openstack.org.node.sh
  echo ${slave} IP: ${ipAddr}
done
