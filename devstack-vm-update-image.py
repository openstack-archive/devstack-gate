#!/usr/bin/env python

# Update the base image that is used for devstack VMs.

# Copyright (C) 2011-2012 OpenStack LLC.
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
import commands
import time
import subprocess
import traceback
import socket

import vmdatabase
import utils
from sshclient import SSHClient

WORKSPACE = os.environ['WORKSPACE']
DEVSTACK_GATE_PREFIX = os.environ.get('DEVSTACK_GATE_PREFIX', '')
DEVSTACK = os.path.join(WORKSPACE, 'devstack')
PROVIDER_NAME = sys.argv[1]

PROJECTS = ['openstack/nova',
            'openstack/glance',
            'openstack/keystone',
            'openstack/horizon',
            'openstack/cinder',
            'openstack/python-cinderclient',
            'openstack/tempest',
            'openstack/python-glanceclient',
            'openstack/python-keystoneclient',
            'openstack/python-novaclient',
            'openstack/python-openstackclient',
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


def tokenize(fn, tokens, distribution, comment=None):
    for line in open(fn):
        if 'dist:' in line and ('dist:%s' % distribution not in line):
            continue
        if 'qpid' in line:
            continue  # XXX
        if comment and comment in line:
            line = line[:line.rfind(comment)]
        line = line.strip()
        if line and line not in tokens:
            tokens.append(line)


def local_prep(distribution):
    branches = []
    for branch in git_branches():
        branch_data = {'name': branch}
        print 'Branch: ', branch
        run_local(['git', 'checkout', branch], cwd=DEVSTACK)
        run_local(['git', 'pull', '--ff-only', 'origin'], cwd=DEVSTACK)

        pips = []
        pipdir = os.path.join(DEVSTACK, 'files', 'pips')
        if os.path.exists(pipdir):
            for fn in os.listdir(pipdir):
                fn = os.path.join(pipdir, fn)
                tokenize(fn, pips, distribution)
        branch_data['pips'] = pips

        debs = []
        debdir = os.path.join(DEVSTACK, 'files', 'apts')
        for fn in os.listdir(debdir):
            fn = os.path.join(debdir, fn)
            tokenize(fn, debs, distribution, comment='#')
        branch_data['debs'] = debs

        images = []
        for line in open(os.path.join(DEVSTACK, 'stackrc')):
            line = line.strip()
            if line.startswith('IMAGE_URLS'):
                if '#' in line:
                    line = line[:line.rfind('#')]
                if line.endswith(';;'):
                    line = line[:-2]
                value = line.split('=', 1)[1].strip()
                if value[0] == value[-1] == '"':
                    value = value[1:-1]
                images += [x.strip() for x in value.split(',')]
        branch_data['images'] = images
        branches.append(branch_data)
    return branches


def bootstrap_server(provider, server, admin_pass, key):
    client = server.manager.api
    ip = utils.get_public_ip(server)
    if not ip and 'os-floating-ips' in utils.get_extensions(client):
        utils.add_public_ip(server)
        ip = utils.get_public_ip(server)
    if not ip:
        raise Exception("Unable to find public ip of server")

    ssh_kwargs = {}
    if key:
        ssh_kwargs['pkey'] = key
    else:
        ssh_kwargs['password'] = admin_pass

    for username in ['root', 'ubuntu']:
        client = utils.ssh_connect(ip, username, ssh_kwargs, timeout=600)
        if client:
            break

    if not client:
        raise Exception("Unable to log in via SSH")

    # hpcloud can't reliably set the hostname
    gerrit_url = 'https://review.openstack.org/p/openstack/' \
                 'openstack-ci-puppet.git'
    client.ssh("set hostname", "sudo hostname %s" % server.name)
    client.ssh("update apt cache", "sudo apt-get update")
    client.ssh("upgrading system packages",
               'sudo DEBIAN_FRONTEND=noninteractive apt-get '
               '--option "Dpkg::Options::=--force-confold"'
               ' --assume-yes upgrade')
    client.ssh("install git and puppet",
               'sudo DEBIAN_FRONTEND=noninteractive apt-get '
               '--option "Dpkg::Options::=--force-confold"'
               ' --assume-yes install git puppet')
    client.ssh("clone puppret repo",
               "sudo git clone %s /root/openstack-ci-puppet" % gerrit_url)
    client.ssh("run puppet",
               "sudo puppet apply "
               "--modulepath=/root/openstack-ci-puppet/modules"
               "/root/openstack-ci-puppet/manifests/site.pp")


def configure_server(server, branches):
    client = SSHClient(utils.get_public_ip(server), 'jenkins')
    client.ssh('make file cache directory', 'mkdir -p ~/cache/files')
    client.ssh('make pip cache directory', 'mkdir -p ~/cache/pip')
    client.ssh('install build-essential',
               'sudo DEBIAN_FRONTEND=noninteractive '
               'apt-get --option "Dpkg::Options::=--force-confold"'
               ' --assume-yes install build-essential python-dev '
               'linux-headers-virtual linux-headers-`uname -r`')

    for branch_data in branches:
        if branch_data['debs']:
            client.ssh('cache debs for branch %s' % branch_data['name'],
                       'sudo apt-get -y -d install %s' %
                       ' '.join(branch_data['debs']))

        if branch_data['pips']:
            venv = client.ssh('get temp dir for venv', 'mktemp -d').strip()
            client.ssh('create venv',
                       'virtualenv --no-site-packages %s' % venv)
            client.ssh('cache pips for branch %s' % branch_data['name'],
                       'source %s/bin/activate && '
                       'PIP_DOWNLOAD_CACHE=~/cache/pip pip install %s' %
                       (venv, ' '.join(branch_data['pips'])))
            client.ssh('remove venv', 'rm -fr %s' % venv)

        for url in branch_data['images']:
            fname = url.split('/')[-1]
            try:
                client.ssh('check for %s' % fname,
                           'ls ~/cache/files/%s' % fname)
            except:
                client.ssh('download image %s' % fname,
                    'wget -nv -c %s -O ~/cache/files/%s' % (url, fname))

    client.ssh('clear workspace', 'rm -rf ~/workspace-cache')
    client.ssh('make workspace', 'mkdir -p ~/workspace-cache')
    for project in PROJECTS:
        sp = project.split('/')[0]
        client.ssh('clone %s' % project,
            'cd ~/workspace-cache && '
            'git clone https://review.openstack.org/p/%s' % project)

    script = os.environ.get('DEVSTACK_GATE_CUSTOM_SCRIPT', '')
    if script and os.path.isfile(script):
        bn = os.path.basename(script)
        client.scp(script, '/tmp/%s' % bn)
        client.ssh('run custom script %s' % bn,
            'chmod +x /tmp/%s && sudo /tmp/%s' % (bn, bn))

    client.ssh('sync', 'sync && sleep 5')


def snapshot_server(client, server, name):
    print 'Saving image'
    if hasattr(client.images, 'create'):  # v1.0
        image = client.images.create(server, name)
    else:
        # TODO: fix novaclient so it returns an image here
        # image = server.create_image(name)
        uuid = server.manager.create_image(server, name)
        image = client.images.get(uuid)
    print "Waiting for image ID %s" % image.id
    image = utils.wait_for_resource(image)
    return image


def build_image(provider, client, base_image, image,
                flavor, name, branches, timestamp):
    print "Building image %s" % name

    create_kwargs = dict(image=image, flavor=flavor, name=name)

    key = None
    key_name = '%sdevstack-%i' % (DEVSTACK_GATE_PREFIX, time.time())
    if 'os-keypairs' in utils.get_extensions(client):
        print "Adding keypair"
        key, kp = utils.add_keypair(client, key_name)
        create_kwargs['key_name'] = key_name

    server = client.servers.create(**create_kwargs)
    snap_image = base_image.newSnapshotImage(name=name,
                                             version=timestamp,
                                             external_id=None,
                                             server_external_id=server.id)
    admin_pass = server.adminPass
    try:
        print "Waiting for server ID %s" % server.id
        server = utils.wait_for_resource(server)
        bootstrap_server(provider, server, admin_pass, key)
        configure_server(server, branches)
        remote_snap_image = snapshot_server(client, server, name)
        snap_image.external_id = remote_snap_image.id
        snap_image.state = vmdatabase.READY
        # We made the snapshot, try deleting the server, but it's okay
        # if we fail.  The reap script will find it and try again.
        try:
            pass  # XXX
            # utils.delete_server(server)
        except:
            print "Exception encountered deleting server:"
            traceback.print_exc()
    except Exception, real_error:
        # Something went wrong, try our best to mark the server in error
        # then delete the server, then delete the db record for it.
        # If any of this fails, the reap script should catch it.  But
        # having correct info in the DB will help it do its job faster.
        try:
            snap_image.state = vmdatabase.ERROR
            try:
                utils.delete_server(server)
                snap_image.delete()
            except Exception, delete_error:
                print "Exception encountered deleting server:"
                traceback.print_exc()
        except Execption, database_error:
            print "Exception encountered marking server in error:"
            traceback.print_exc()
        # Raise the important exception that started this
        raise


def main():
    db = vmdatabase.VMDatabase()
    provider = db.getProvider(PROVIDER_NAME)
    print "Working with provider %s" % provider.name
    client = utils.get_client(provider)

    for base_image in provider.base_images:
        if base_image.min_ready <= 0:
            continue
        print "Working on base image %s" % base_image.name

        flavor = utils.get_flavor(client, base_image.min_ram)
        print "Found flavor", flavor

        branches = local_prep(base_image.name)

        remote_base_image = client.images.find(name=base_image.external_id)
        timestamp = int(time.time())
        remote_snap_image_name = ('%sdevstack-%s-%s.template.openstack.org' %
                                  (DEVSTACK_GATE_PREFIX,
                                  base_image.name, str(timestamp)))
        remote_snap_image = build_image(provider, client, base_image,
                                        remote_base_image, flavor,
                                        remote_snap_image_name,
                                        branches, timestamp)


if __name__ == '__main__':
    main()
