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
in python2.6 and python2.7, and pep8. Those tests are all run only on
the project in question. The devstack gate test, however, is an
integration test and ensures that a proposed change still enables
several of the projects to work together. Currently, any proposed
change to the following projects must pass the devstack gate test::

    nova
    glance
    keystone
    heat
    horizon
    quantum
    ceilometer
    python-novaclient
    python-heatclient
    python-keystoneclient
    python-quantumclient
    devstack
    devstack-gate

Obviously we test nova, glance, keystone, horizon, quantum and their clients
because they all work closely together to form an OpenStack
system. Changes to devstack itself are also required to pass this test
so that we can be assured that devstack is always able to produce a
system capable of testing the next change to nova. The devstack gate
scripts themselves are included for the same reason.

How It Works
============

The devstack test starts with an essentially bare virtual machine,
installs devstack on it, and runs some simple tests of the resulting
OpenStack installation. In order to ensure that each test run is
independent, the virtual machine is discarded at the end of the run,
and a new machine is used for the next run. In order to keep the
actual test run as short and reliable as possible, the virtual
machines are prepared ahead of time and kept in a pool ready for
immediate use. The process of preparing the machines ahead of time
reduces network traffic and external dependencies during the run.

The mandate of the devstack-gate project is to prepare those virtual
machines, ensure that enough of them are always ready to run,
bootstrap the test process itself, and clean up when it's done. The
devstack gate scripts should be able to be configured to provision
machines based on several images (eg, natty, oneiric, precise), and
each of those from several providers. Using multiple providers makes
the entire system somewhat highly-available since only one provider
needs to function in order for us to run tests. Supporting multiple
images will help with the transition of testing from oneiric to
precise, and will allow us to continue running tests for stable
branches on older operating systems.

To accomplish all of that, the devstack-gate repository holds several
scripts that are run by Jenkins.

Once per day, for every image type (and provider) configured, the
``devstack-vm-update-image.sh`` script checks out the latest copy of
devstack, and then runs the ``devstack-vm-update-image.py script.`` It
boots a new VM from the provider's base image, installs some basic
packages (build-essential, python-dev, etc) including java so that the
machine can run the Jenkins slave agent, runs puppet to set up the
basic system configuration for Jenkins slaves in the openstack-infra
project, and then caches all of the debian and pip packages and test
images specified in the devstack repository, and clones the OpenStack
project repositories. It then takes a snapshot image of that machine
to use when booting the actual test machines. When they boot, they
will already be configured and have all, or nearly all, of the network
accessible data they need. Then the template machine is deleted. The
Jenkins job that does this is ``devstack-update-vm-image``. It is a
matrix job that runs for all configured providers, and if any of them
fail, it's not a problem since the previously generated image will
still be available.

Even though launching a machine from a saved image is usually fast,
depending on the provider's load it can sometimes take a while, and
it's possible that the resulting machine may end up in an error state,
or have some malfunction (such as a misconfigured network). Due to
these uncertainties, we provision the test machines ahead of time and
keep them in a pool. Every ten minutes, a job runs to spin up new VMs
for testing and add them to the pool, using the
``devstack-vm-launch.py`` script. Each image type has a parameter
specifying how many machine of that type should be kept ready, and
each provider has a parameter specifying the maximum number of
machines allowed to be running on that provider. Within those bounds,
the job attempts to keep the requested number of machines up and ready
to go at all times. When a machine is spun up and found to be
accessible, it as added to Jenkins as a slave machine with one
executor and a tag like "devstack-foo" (eg, "devstack-oneiric" for
oneiric image types). The Jenkins job that does this is
``devstack-launch-vms``. It is also a matrix job that runs for all
configured providers.

Process invoked once a proposed change is approved by the core
reviewers is as follows:

 * Jenkins triggers the devstack gate test itself.
 * This job runs on one of the previously configured "devstack-foo"
   nodes and invokes the ``devstack-vm-gate-wrap.sh`` script which
   checks out code from all of the involved repositories, and merges
   the proposed change.
 * If the ``pre_test_hook`` function is defined it is executed.
 * The wrap script defines a ``gate_hook`` function if one is
   not provided. By default it uses the devstack-vm-gate.sh script
   which installs a devstack configuration file, and invokes devstack.
 * If the ``post_test_hook`` function is defined it is executed.
 * Once devstack is finished, it runs ``exercise.sh`` which performs
   some basic integration testing.
 * After everything is done, the script copies all of the log files
   back to the Jenkins workspace and archives them along with the
   console output of the run. The Jenkins job that does this is the
   somewhat awkwardly named ``gate-integration-tests-devstack-vm``.

To prevent a node from being used for a second run, there is a job
named ``devstack-update-inprogress`` which is triggered as a
parameterized build step from ``gate-interation-tests-devstack-vm``.
It is passed the name of the node on which the gate job is running,
and it disabled that node in Jenkins by invoking
``devstack-vm-inprogress.py``.  The currently running job will
continue, but no new jobs will be scheduled for that node.

Similarly, when the node is finished, a parameterized job named
``devstack-update-complete`` (which runs ``devstack-vm-delete.py``)
is triggered as a post-build action.  It removes the node from Jenkins
and marks the VM for later deletion.

In the future, we hope to be able to install developer SSH keys on VMs
from failed test runs, but for the moment the policies of the
providers who are donating test resources do not permit that. However,
most problems can be diagnosed from the log data that are copied back
to Jenkins. There is a script that cleans up old images and VMs that
runs frequently. It's ``devstack-vm-reap.py`` and is invoked by the
Jenkins job ``devstack-reap-vms``.

How to Debug a Devstack Gate Failure
====================================

When Jenkins runs gate tests for a change, it leaves comments on the
change in Gerrit with links to the test run. If a change fails the
devstack gate test, you can follow it to the test run in Jenkins to
find out what went wrong. The first thing you should do is look at the
console output (click on the link labeled "[raw]" to the right of
"Console Output" on the left side of the screen). You'll want to look
at the raw output because Jenkins will truncate the large amount of
output that devstack produces. Skip to the end to find out why the
test failed (keep in mind that the last few commands it runs deal with
copying log files and deleting the test VM -- errors that show up
there won't affect the test results). You'll see a summary of the
devstack exercise.sh tests near the bottom. Scroll up to look for
errors related to failed tests.

You might need some information about the specific run of the test. At
the top of the console output, you can see all the git commands used
to set up the repositories, and they will output the (short) sha1 and
commit subjects of the head of each repository.

It's possible that a failure could be a false negative related to a
specific provider, especially if there is a pattern of failures from
tests that run on nodes from that provider. In order to find out which
provider supplied the node the test ran on, look at the name of the
jenkins slave near the top of tho console output, the name of the
provider is included.

Below that, you'll find the output from devstack as it installs all of
the debian and pip packages required for the test, and then configures
and runs the services. Most of what it needs should already be cached
on the test host, but if the change to be tested includes a dependency
change, or there has been such a change since the snapshot image was
created, the updated dependency will be downloaded from the Internet,
which could cause a false negative if that fails.

Assuming that there are no visible failures in the console log, you
may need to examine the log output from the OpenStack services. Back
on the Jenkins page for the build, you should see a list of "Build
Artifacts" in the center of the screen. All of the OpenStack services
are configured to syslog, so you may find helpful log messages by
clicking on "syslog.txt". Some error messages are so basic they don't
make it to syslog, such as if a service fails to start. Devstack
starts all of the services in screen, and you can see the output
captured by screen in files named "screen-\*.txt". You may find a
traceback there that isn't in syslog.

After examining the output from the test, if you believe the result
was a false negative, you can retrigger the test by re-approving the
change in Gerrit. If a test failure is a result of a race condition in
the OpenStack code, please take the opportunity to try to identify it,
and file a bug report or fix the problem. If it seems to be related to
a specific devstack gate node provider, we'd love it if you could help
identify what the variable might be (whether in the devstack-gate
scripts, devstack itself, OpenStack, or even the provider's service).

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
provider, but you'll want to make sure you have a basic Ubuntu 12.04 LTS
(Precise Pangolin) image with sufficient memory and processor count.
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
  export NOVA_RAX_AUTH=1
  export FLAVOR='8GB Standard Instance'
  export IMAGE='Ubuntu 12.04 LTS (Precise Pangolin)'

By comparison, a provider settings file for HPCloud::

  export OS_USERNAME=<provider_username>
  export OS_PASSWORD='<provider_password>'
  export OS_TENANT_NAME=<provider_tenant>
  export OS_AUTH_URL=https://region-a.geo-1.identity.hpcloudsvc.com:35357/v2.0
  export OS_REGION_NAME=az-3.region-a.geo-1
  export FLAVOR='standard.large'
  export IMAGE='Ubuntu Precise 12.04 LTS Server 64-bit 20121026 (b)'

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
and reboot to make sure you're running a current kernel::

  apt-get install -y git \
  && git clone https://review.openstack.org/p/openstack-infra/config \
  && config/install_puppet.sh && config/install_modules.sh \
  && puppet apply --modulepath=/root/config/modules:/etc/puppet/modules \
  -e "class { openstack_project::slave_template: install_users => false,
  ssh_key => \"$( cat .ssh/authorized_keys )\" }" \
  && echo HostKey /etc/ssh/ssh_host_ecdsa_key >> /etc/ssh/sshd_config \
  && reboot

Wait a few moments for the reboot to complete, then log back in with
``nova ssh --login jenkins testserver`` or ``ssh jenkins@<ip_address>``
and set up parts of the environment expected by devstack-gate testing
(the "devstack-vm-gate-dev.sh" script mentioned below in the
`Developer Setup`_ section implements a similar workflow for testing
changes to devstack-gate itself, but could be modified to automate much
of this for ease of repetition)::

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
for these are found in the openstack-infra/config project under the
modules/openstack_project/files/jenkins_job_builder/config directory in
a file named devstack-gate.yaml. It will probably look something like::

  export PYTHONUNBUFFERED=true
  export DEVSTACK_GATE_TEMPEST=1
  export DEVSTACK_GATE_TEMPEST_FULL=1
  cp devstack-gate/devstack-vm-gate-wrap.sh ./safe-devstack-vm-gate-wrap.sh
  ./safe-devstack-vm-gate-wrap.sh

If you're trying to figure out which devstack gate jobs run for a given
project+branch combination, this is encoded in the
openstack-infra/config project under the
modules/openstack_project/files/zuul directory in a file named
layout.yaml. You'll want to look in the "projects" section for a list of
jobs run on a given project in the "gate" pipeline, and then consult the
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

.. _`Jenkins Job Builder`: http://ci.openstack.org/jjb.html

.. _Zuul: http://ci.openstack.org/zuul.html

Contributions Welcome
=====================

All of the OpenStack developer infrastructure is freely available and
managed in source code repositories just like the code of OpenStack
itself. If you'd like to contribute, just clone and propose a patch to
the relevant repository::

    https://github.com/openstack-infra/devstack-gate
    https://github.com/openstack/openstack-infra-puppet

You can file bugs on the openstack-ci project::

    https://launchpad.net/openstack-ci

And you can chat with us on Freenode in #openstack-dev or #openstack-infra.

Developer Setup
===============

If you'd like to work on the devstack-gate scripts and test process,
this should help you bootstrap a test environment (assuming the user
you're working as is called "jenkins")::

    export WORKSPACE=/home/jenkins/workspace
    export DEVSTACK_GATE_PREFIX=wip-
    export SKIP_DEVSTACK_GATE_PROJECT=1
    export SKIP_DEVSTACK_GATE_JENKINS=1
    export ZUUL_BRANCH=master
    export ZUUL_PROJECT=testing

    cd /home/jenkins/workspace
    git clone https://github.com/openstack-infra/devstack-gate
    cd devstack-gate
    python vmdatabase.py
    sqlite3 /home/jenkins/vm.db

With the database open, you'll want to populate the provider and base_image
tables with your provider details and specifications for images created.

By default, the update-image script will produce a VM that only members
of the OpenStack CI team can log into.  You can inject your SSH public
key by setting the appropriate env variable, like so::

    export JENKINS_SSH_KEY=$(head -1 ~/.ssh/authorized_keys)

Then run::

    ./devstack-vm-update-image.sh <YOUR PROVIDER NAME>
    ./devstack-vm-launch.py <YOUR PROVIDER NAME>
    python vmdatabase.py

So that you don't need an entire Jenkins environment during
development, The SKIP_DEVSTACK_GATE_JENKINS variable will cause the
launch and reap scripts to omit making changes to Jenkins.  You'll
need to pick a machine to use yourself, so chose an IP from the output
from 'python vmdatabase.py' and then run::

    ./devstack-vm-gate-dev.sh <IP>

To test your changes.  That script copies the workspace over to the
machine and invokes the gate script as Jenkins would.  When you're
done, you'll need to run::

    ./devstack-vm-reap.py <YOUR PROVIDER NAME> --all-servers

To clean up.

Production Setup
================

In addition to the jobs described under "How It Works", you will need
to install a config file at ~/devstack-gate-secure.conf on the Jenkins
node where you are running the update-image, launch, and reap jobs
that looks like this::

    [jenkins]
    server=https://jenkins.example.com
    user=jekins-user-with-admin-privs
    apikey=1234567890abcdef1234567890abcdef

