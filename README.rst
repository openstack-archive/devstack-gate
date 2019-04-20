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

.. _Nodepool: https://opendev.org/zuul/nodepool

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

First, you can build an image identical to the images running in the gate using
`diskimage-builder <https://docs.openstack.org/developer/diskimage-builder>`_.
The specific operating systems built and DIB elements for each image type are
defined in `nodepool.yaml <https://opendev.org/openstack/project-config/
src/branch/master/nodepool/nodepool.yaml>`_. There is a handy script
available in the project-config repo to build this for you::

  git clone https://opendev.org/openstack/project-config
  cd project-config
  ./tools/build-image.sh

Take a look at the documentation within the `build-image.sh` script for specific
build options.

These days Tempest testing is requiring in excess of 2GiB RAM (4 should
be enough but we typically use 8) and completes within an hour on a
4-CPU virtual machine.

If you're using an OpenStack provider, it's usually helpful to set up a
`clouds.yaml` file. More information on `clouds.yaml` files can be found in the
`os-client-config documentation <https://docs.openstack.org/developer/os-client-config/#config-files`_.
A `clouds.yaml` file for Rackspace would look something like::


  clouds:
    rackspace:
      auth:
        profile: rackspace
        username: '<provider_username>'
        password: '<provider_password>'
        project_name: '<provider_project_name>'

Where provider_username and provider_password are the user / password
for a valid user in your account, and provider_project_name is the project_name
you want to use (sometimes called 'tenant name' on older clouds)

You can then use the `openstack` command line client (found in the python
package
`python-openstackclient <http://pypi.python.org/pypi/python-openstackclient>`_)
to create a VM on the cloud.

You can tell `openstack` to use the `DFW` region
of the `rackspace` cloud you defined either by setting environment variables::

  export OS_CLOUD=rackspace
  export OS_REGION_NAME=DFW
  openstack servers list

or command line options:

  openstack --os-cloud=rackspace --os-region-name=DFW servers list

It will be assumed in remaining examples that environment varialbes have been
set.

If you haven't already, create an SSH keypair "my-keypair" (name it whatever
you like)::

  openstack keypair create --public-key=$HOME/.ssh/id_rsa.pub my-keypair

Upload your image, boot a server named "testserver" (chosen arbitrarily for
this example) with your SSH key allowed, and log into it::

  FLAVOR='8GB Standard Instance'
  openstack image create --file devstack-gate.qcow2 devstack-gate
  openstack server create --wait --flavor "$FLAVOR" --image "devstack-gate" \
    --key-name=my-keypair testserver
  openstack server ssh testserver

If you get a cryptic error like ``ERROR: 'public'`` then you may need to
manually look up the IP address with ``openstack server show testserver`` and
connect by running ``ssh root@<ip_address>`` instead. Once logged in, switch to
the jenkins user and set up parts of the environment expected by devstack-gate
testing::

  su - jenkins
  export REPO_URL=https://git.openstack.org
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
  && git clone --depth 1 $REPO_URL/openstack/devstack-gate

At this point you're ready to set the same environment variables and run
the same commands/scripts as used in the desired job. The definitions
for these are found in the openstack/project-config project under
the jenkins/jobs directory in a file named devstack-gate.yaml. It will
probably look something like::

  export PYTHONUNBUFFERED=true
  export DEVSTACK_GATE_TEMPEST=1
  export DEVSTACK_GATE_TEMPEST_FULL=1
  cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
  ./safe-devstack-vm-gate-wrap.sh

If you're trying to figure out which devstack gate jobs run for a given
project+branch combination, this is encoded in the
openstack/project-config project under the zuul/ directory in a file
named layout.yaml. You'll want to look in the "projects" section for a list
of jobs run on a given project in the "gate" pipeline, and then consult the
"jobs" section of the file to see if there are any overrides indicating
which branches qualify for the job and whether or not its voting is
disabled.

After the script completes, investigate any failures. Then log out and
``openstack server delete testserver`` or similar to get rid of it once no
longer needed. It's possible to re-run certain jobs or specific tests on a used
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

    https://opendev.org/openstack/devstack-gate
    https://opendev.org/zuul/nodepool
    https://opendev.org/opendev/system-config
    https://opendev.org/openstack/project-config

You can file bugs on the storyboard devstack-gate project::

    https://storyboard.openstack.org/#!/project/712

And you can chat with us on Freenode in #openstack-qa or #openstack-infra.

It's worth noting that, while devstack-gate is generally licensed under the
Apache license, `playbooks/plugins/callback/devstack.py` is GPLv3 due to having
derived from the Ansible source code.
