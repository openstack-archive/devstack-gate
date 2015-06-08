Devstack Gate
=============

Devstack-gate is a collection of scripts used by the OpenStack CI team
to test every change to core OpenStack projects by deploying OpenStack
via devstack on a cloud server.

What It Is
==========

All changes to core OpenStack projects are "gated" on a set of tests
so that it will not be merged into the main repository unless it
passes all of the configured tests. Most projects require unit tests
with pep8 and several versions of Python. Those tests are all run only
on the project in question. The devstack gate test, however, is an
integration test and ensures that a proposed change still enables
several of the projects to work together.

Obviously we test integrated OpenStack components and their clients
because they all work closely together to form an OpenStack
system. Changes to devstack itself are also required to pass this test
so that we can be assured that devstack is always able to produce a
system capable of testing the next change to nova. The devstack gate
scripts themselves are included for the same reason.

How It Works
============

The devstack test starts with an essentially bare virtual machine,
installs devstack on it, and runs tests of the resulting OpenStack
installation. In order to ensure that each test run is independent,
the virtual machine is discarded at the end of the run, and a new
machine is used for the next run. In order to keep the actual test run
as short and reliable as possible, the virtual machines are prepared
ahead of time and kept in a pool ready for immediate use. The process
of preparing the machines ahead of time reduces network traffic and
external dependencies during the run.

The `Nodepool`_ project is used to maintain this pool of machines.

.. _Nodepool: https://git.openstack.org/cgit/openstack-infra/nodepool

How to Debug a Devstack Gate Failure
====================================

When Jenkins runs gate tests for a change, it leaves comments on the
change in Gerrit with a link to the resulting logs, including the
console log. If a change fails in a devstack-gate test, you can follow
these links to find out what went wrong. Start at the bottom of the log
file with the failure, scroll up to look for errors related to failed
tests.

You might need some information about the specific run of the test. In
the devstack-gate-setup-workspace log, you can see all the git commands
used to set up the repositories, and they will output the (short) sha1
and commit subjects of the head of each repository.

It's possible that a failure could be a false negative related to a
specific provider, especially if there is a pattern of failures from
tests that run on nodes from that provider. In order to find out which
provider supplied the node the test ran on, look at the name of the
jenkins slave in the devstack-gate-setup-host log, the name of the
provider is included.

Below that, you'll find the output from devstack as it installs all of
the debian and pip packages required for the test, and then configures
and runs the services. Most of what it needs should already be cached
on the test host, but if the change to be tested includes a dependency
change, or there has been such a change since the snapshot image was
created, the updated dependency will be downloaded from the Internet,
which could cause a false negative if that fails.
Assuming that there are no visible failures in the console log, you
may need to examine the log output from the OpenStack services, located
in the logs/ directory. All of the OpenStack services are configured to
syslog, so you may find helpful log messages by clicking on the
"syslog.txt[.gz]" file. Some error messages are so basic they don't
make it to syslog, such as if a service fails to start. Devstack
starts all of the services in screen, and you can see the output
captured by screen in files named "screen-\*.txt". You may find a
traceback there that isn't in syslog.

After examining the output from the test, if you believe the result
was a false negative, you can retrigger the test by running a recheck,
this is done by leaving a review comment with simply the text: recheck

If a test failure is a result of a race condition in the OpenStack code,
you also have the opportunity to try to identify it, and file a bug report,
help fix the problem or leverage `elastic-recheck
<http://docs.openstack.org/infra/elastic-recheck/readme.html>`_ to help
track the problem. If it seems to be related to a specific devstack gate
node provider, we'd love it if you could help identify what the variable
might be (whether in the devstack-gate scripts, devstack itself, Nodepool,
OpenStack, or even the provider's service).

Simulating Devstack Gate Tests
==============================

Developers often have a need to recreate gating integration tests
manually, and this provides a walkthrough of making a DG-slave-like
throwaway server without the overhead of building other CI
infrastructure to manage a pool of them. This can be useful to reproduce
and troubleshoot failures or tease out nondeterministic bugs.

First, it helps if you have access to a virtual machine from one of the
providers the OpenStack project is using for gating, since their
performance characteristics and necessary build parameters are already
known. The same thing can of course be done locally or on another
provider, but you'll want to make sure you have a basic Ubuntu 14.04 LTS
(Trusty Tahr) image with sufficient memory and processor count.
These days Tempest testing is requiring in excess of 2GiB RAM (4 should
be enough but we typically use 8) and completes within an hour on a
4-CPU virtual machine.

If you're using a nova provider, it's usually helpful to set up an
environment variable list you can include into your shell so you don't
have to feed a bunch of additional options on the nova client command
line. A provider settings file for Rackspace would look something like::

  export OS_USERNAME=<provider_username>
  export OS_PASSWORD='<provider_password>'
  export OS_TENANT_NAME=<provider_tenant>
  export OS_AUTH_URL=https://identity.api.rackspacecloud.com/v2.0/
  export OS_REGION_NAME=DFW
  export FLAVOR='8GB Standard Instance'
  export IMAGE='Ubuntu 14.04 LTS (Trusty Tahr) (PVHVM)'

Where provider_username and provider_password are the user / password
for a valid user in your account, and provider_tenant is the numeric
id of your account (typically 6 digits).

By comparison, a provider settings file for HPCloud::

  export OS_USERNAME=<provider_username>
  export OS_PASSWORD='<provider_password>'
  export OS_TENANT_NAME=<provider_tenant>
  export OS_AUTH_URL=https://region-a.geo-1.identity.hpcloudsvc.com:35357/v2.0
  export OS_REGION_NAME=az-3.region-a.geo-1
  export FLAVOR='standard.large'
  export IMAGE='Ubuntu Server 14.04 LTS (amd64 20140607.1) - Partner Image'

Note: The image regularly changes as new images are uploaded, for the
specific image name currently used for tests, see
`nodepool.yaml.erb <http://git.openstack.org/cgit/openstack-infra/
system-config/tree/modules/openstack_project/templates/nodepool/
nodepool.yaml.erb>`_.

Source the provider settings, boot a server named "testserver" (chosen
arbitrarily for this example) with your SSH key allowed, and log into
it::

  . provider_settings.sh
  nova boot --poll --flavor "$FLAVOR" --image "$IMAGE" \
    --file /root/.ssh/authorized_keys=$HOME/.ssh/id_rsa.pub testserver
  nova ssh testserver

If you get a cryptic error like ``ERROR: 'public'`` then you may need to
manually look up the IP address with ``nova list --name testserver`` and
connect by running ``ssh root@<ip_address>`` instead.

Upgrade the server, install git and pip packages, add tox via pip
(because the packaged version is too old), set up a "jenkins" account
(add user "jenkins" to sudoers) and reboot to make sure you're running 
a current kernel::

  apt-get install -y git \
  && git clone https://review.openstack.org/p/openstack-infra/system-config \
  && system-config/install_puppet.sh && system-config/install_modules.sh \
  && puppet apply \
  --modulepath=/root/system-config/modules:/etc/puppet/modules \
  -e "class { openstack_project::single_use_slave: install_users => false,
  ssh_key => \"$( cat .ssh/id_rsa.pub | awk '{print $2}' )\" }" \
  && echo "jenkins ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
  && reboot

Wait a few moments for the reboot to complete, then log back in with
``nova ssh --login jenkins testserver`` or ``ssh jenkins@<ip_address>``
and set up parts of the environment expected by devstack-gate testing::

  export REPO_URL=https://review.openstack.org/p
  export ZUUL_URL=/home/jenkins/workspace-cache
  export ZUUL_REF=HEAD
  export WORKSPACE=/home/jenkins/workspace/testing
  mkdir -p $WORKSPACE

Specify the project and branch you want to test for integration::

  export ZUUL_PROJECT=openstack/nova
  export ZUUL_BRANCH=master

Get a copy of the tested project. After these steps, apply relevant
patches on the target branch (via cherry-pick, rebase, et cetera) and
make sure ``HEAD`` is at the ref you want tested::

  git clone $REPO_URL/$ZUUL_PROJECT $ZUUL_URL/$ZUUL_PROJECT \
  && cd $ZUUL_URL/$ZUUL_PROJECT \
  && git checkout remotes/origin/$ZUUL_BRANCH

Switch to the workspace and get a copy of devstack-gate::

  cd $WORKSPACE \
  && git clone --depth 1 $REPO_URL/openstack-infra/devstack-gate

At this point you're ready to set the same environment variables and run
the same commands/scripts as used in the desired job. The definitions
for these are found in the openstack-infra/project-config project under
the jenkins/jobs directory in a file named devstack-gate.yaml. It will
probably look something like::

  export PYTHONUNBUFFERED=true
  export DEVSTACK_GATE_TIMEOUT=120
  export DEVSTACK_GATE_TEMPEST=1
  export DEVSTACK_GATE_TEMPEST_FULL=1
  cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
  ./safe-devstack-vm-gate-wrap.sh

If you're trying to figure out which devstack gate jobs run for a given
project+branch combination, this is encoded in the
openstack-infra/project-config project under the zuul/ directory in a file
named layout.yaml. You'll want to look in the "projects" section for a list
of jobs run on a given project in the "gate" pipeline, and then consult the
"jobs" section of the file to see if there are any overrides indicating
which branches qualify for the job and whether or not its voting is
disabled.

After the script completes, investigate any failures. Then log out and
``nova delete testserver`` or similar to get rid of it once no longer
needed. It's possible to re-run certain jobs or specific tests on a used
VM (sometimes with a bit of manual clean-up in between runs), but for
proper testing you'll want to validate your fixes on a completely fresh
one.

Refer to the `Jenkins Job Builder`_ and Zuul_ documentation for more
information on their configuration file formats.

.. _`Jenkins Job Builder`: http://docs.openstack.org/infra/system-config/jjb.html

.. _Zuul: http://docs.openstack.org/infra/system-config/zuul.html

Contributions Welcome
=====================

All of the OpenStack developer infrastructure is freely available and
managed in source code repositories just like the code of OpenStack
itself. If you'd like to contribute, just clone and propose a patch to
the relevant repository::

    https://git.openstack.org/cgit/openstack-infra/devstack-gate
    https://git.openstack.org/cgit/openstack-infra/nodepool
    https://git.openstack.org/cgit/openstack-infra/system-config
    https://git.openstack.org/cgit/openstack-infra/project-config

You can file bugs on the storyboard devstack-gate project::

    https://storyboard.openstack.org/#!/project/712

And you can chat with us on Freenode in #openstack-dev or #openstack-infra.
