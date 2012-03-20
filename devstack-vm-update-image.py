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

from libcloud.compute.base import NodeImage, NodeSize, NodeLocation
from libcloud.compute.types import Provider
from libcloud.compute.providers import get_driver
from libcloud.compute.deployment import MultiStepDeployment, ScriptDeployment, SSHKeyDeployment
import libcloud
import sys
import os
import commands
import time
import paramiko
import subprocess

CLOUD_SERVERS_DRIVER = os.environ.get('CLOUD_SERVERS_DRIVER','rackspace')
CLOUD_SERVERS_USERNAME = os.environ['CLOUD_SERVERS_USERNAME']
CLOUD_SERVERS_API_KEY = os.environ['CLOUD_SERVERS_API_KEY']
WORKSPACE = os.environ['WORKSPACE']
DEVSTACK = os.path.join(WORKSPACE, 'devstack')
SERVER_NAME = os.environ.get('SERVER_NAME',
                             'devstack-oneiric.template.openstack.org')
IMAGE_NAME = os.environ.get('IMAGE_NAME', 'devstack-oneiric')
DISTRIBUTION = 'oneiric'
PROJECTS = ['openstack/nova',
            'openstack/glance', 
            'openstack/keystone', 
            'openstack/horizon', 
            'openstack/python-novaclient',
            'openstack/python-keystoneclient',
            'openstack/python-quantumclient',
            'openstack-dev/devstack',
            'openstack-ci/devstack-gate']

def run_local(cmd, status=False, cwd='.', env={}):
    print "Running:", cmd
    newenv = os.environ
    newenv.update(env)
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, cwd=cwd,
                         stderr=subprocess.STDOUT, env=newenv)
    (out, nothing) = p.communicate()
    if status:
        return (p.returncode, out.strip())
    return out.strip()

def git_branches():
    branches = []
    for branch in run_local(['git', 'branch'], cwd=DEVSTACK).split("\n"):
        if branch.startswith('*'):
            branch = branch.split()[1]
        branches.append(branch.strip())
    return branches

def tokenize(fn, tokens, comment=None):
    for line in open(fn):
        if 'dist:' in line and ('dist:%s'%DISTRIBUTION not in line):
            continue
        if comment and comment in line:
            line = line[:line.rfind(comment)]
        line = line.strip()
        if line and line not in tokens:
            tokens.append(line)

BRANCHES = []
for branch in git_branches():
    branch_data = {'name': branch}
    print 'Branch: ', branch
    run_local(['git', 'checkout', branch], cwd=DEVSTACK)
    run_local(['git', 'pull', '--ff-only', 'origin'], cwd=DEVSTACK)

    pips = []
    pipdir = os.path.join(DEVSTACK, 'files', 'pips')
    for fn in os.listdir(pipdir):
        fn = os.path.join(pipdir, fn)
        tokenize(fn, pips)
    branch_data['pips'] = pips

    debs = []
    debdir = os.path.join(DEVSTACK, 'files', 'apts')
    for fn in os.listdir(debdir):
        fn = os.path.join(debdir, fn)
        tokenize(fn, debs, comment='#')
    branch_data['debs'] = debs

    images = []
    for line in open(os.path.join(DEVSTACK, 'stackrc')):
        if line.startswith('IMAGE_URLS'):
            if '#' in line: 
                line = line[:line.rfind('#')]
            value = line.split('=', 1)[1].strip()
            if value[0]==value[-1]=='"':
                value=value[1:-1]
            images += [x.strip() for x in value.split(',')]
    branch_data['images'] = images
    BRANCHES.append(branch_data)

if CLOUD_SERVERS_DRIVER == 'rackspace':
    Driver = get_driver(Provider.RACKSPACE)
    conn = Driver(CLOUD_SERVERS_USERNAME, CLOUD_SERVERS_API_KEY)
    
    print "Searching for %s server" % SERVER_NAME
    node = [n for n in conn.list_nodes() if n.name==SERVER_NAME][0]

    print "Searching for %s image" % IMAGE_NAME
    old_images = [img for img in conn.list_images()
                  if img.name.startswith(IMAGE_NAME)]
else:
    raise Exception ("Driver not supported")

ip = node.public_ip[0]
client = paramiko.SSHClient()
client.load_system_host_keys()
client.set_missing_host_key_policy(paramiko.WarningPolicy())
client.connect(ip)

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

ssh('make file cache directory', 'mkdir -p ~/cache/files')
ssh('make pip cache directory', 'mkdir -p ~/cache/pip')
ssh('update package list', 'sudo apt-get update')
ssh('upgrade server', 'sudo apt-get -y dist-upgrade')
ssh('run puppet', 'sudo bash -c "cd /root/openstack-ci-puppet && /usr/bin/git pull -q && /var/lib/gems/1.8/bin/puppet apply -l /tmp/manifest.log --modulepath=/root/openstack-ci-puppet/modules manifests/site.pp"')

for branch_data in BRANCHES:
    ssh('cache debs for branch %s'%branch_data['name'], 
        'sudo apt-get -y -d install %s' % ' '.join(branch_data['debs']))
    venv = ssh('get temp dir for venv', 'mktemp -d').strip()
    ssh('create venv', 'virtualenv --no-site-packages %s' % venv)
    ssh('cache pips for branch %s'%branch_data['name'], 
        'source %s/bin/activate && PIP_DOWNLOAD_CACHE=~/cache/pip pip install %s' % (venv, ' '.join(branch_data['pips'])))
    ssh('remove venv', 'rm -fr %s'%venv)
    for url in branch_data['images']:
        fname = url.split('/')[-1]
        try:
            ssh('check for %s'%fname, 'ls ~/cache/files/%s'%fname)
        except:
            ssh('download image %s'%fname,
                'wget -c %s -O ~/cache/files/%s' % (url, fname))

ssh('clear workspace', 'rm -rf ~/workspace')
ssh('make workspace', 'mkdir -p ~/workspace')
for project in PROJECTS:
    sp = project.split('/')[0]
    ssh('clone %s'%project,
        'cd ~/workspace && git clone https://review.openstack.org/p/%s'%project)

# TODO: remove after mysql/rabbitmq are removed from image
try:
    ssh('stop mysql', 'sudo /etc/init.d/mysql stop')
except:
    pass
try:
    ssh('stop rabbitmq', 'sudo /etc/init.d/rabbitmq-server stop')
except:
    pass

IMAGE_NAME = IMAGE_NAME+'-'+str(int(time.time()))

print 'Saving image'
image = conn.ex_save_image(node=node, name=IMAGE_NAME)

last_extra = None
okay = False
while True:
    image = [img for img in conn.list_images(ex_only_active=False) 
             if img.name==IMAGE_NAME][0]
    if image.extra != last_extra:
        print image.extra['status'], image.extra['progress']
    if image.extra['status'] == 'ACTIVE':
        okay = True
        break
    last_extra = image.extra
    time.sleep(2)

if okay:
    for image in old_images:
        print 'Deleting image', image
        try:
            conn.ex_delete_image(image)
        except Exception, e:
            print e
