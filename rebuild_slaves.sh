for slave in \
  burrow \
  burrow-java \
  dashboard \
  glance \
  keystone \
  libburrow \
  nova \
  manuals \
  openstack-ci \
  swift
do
  source ${slave}.slave.openstack.org.node.sh
  cloudservers delete ${nodeId}
  python launch_slave.py ${slave}.slave.openstack.org `echo ${slave} | tr - _`
  source ${slave}.slave.openstack.org.node.sh
  echo ${slave} IP: ${ipAddr}
done
