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
change to the following projects must pass the devstack gate test:

    nova
    glance
    keystone
    horizon
    python-novaclient
    python-keystoneclient
    devstack
    devstack-gate

Obviously we test nova, glance, keystone, horizon and their clients
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
devstack-vm-update-image.sh script checks out the latest copy of
devstack, and then runs the devstack-vm-update-image.py script. It
boots a new VM from the provider's base image, installs some basic
packages (build-essential, python-dev, etc), runs puppet to set up the
basic system configuration for the openstack-ci project, and then
caches all of the debian and pip packages and test images specified in
the devstack repository, and clones the OpenStack project
repositories. It then takes a snapshot image of that machine to use
when booting the actual test machines. When they boot, they will
already be configured and have all, or nearly all, of the network
accessible data they need. Then the template machine is deleted. The
Jenkins job that does this is devstack-update-vm-image. It is a matrix
job that runs for all configured providers, and if any of them fail,
it's not a problem since the previously generated image will still be
available.

Even though launching a machine from a saved image is usually fast,
depending on the provider's load it can sometimes take a while, and
it's possible that the resulting machine may end up in an error state,
or have some malfunction (such as a misconfigured network). Due to
these uncertainties, we provision the test machines ahead of time and
keep them in a pool. Every ten minutes, a job runs to spin up new VMs
for testing and add them to the pool, using the devstack-vm-launch.py
script. Each image type has a parameter specifying how many machine of
that type should be kept ready, and each provider has a parameter
specifying the maximum number of machines allowed to be running on
that provider. Within those bounds, the job attempts to keep the
requested number of machines up and ready to go at all times. The
Jenkins job that does this is devstack-launch-vms. It is also a matrix
job that runs for all configured providers.

When a proposed change is approved by the core reviewers, Jenkins
triggers the devstack gate test itself. This job runs the
devstack-vm-gate.sh script which checks out code from all of the
involved repositories, merges the proposed change, fetches the next
available VM from the pool that matches the image type that should be
tested (eg, oneiric) using the devstack-vm-fetch.py script, rsyncs the
Jenkins workspace (including all the source code repositories) to the
VM, installs a devstack configuration file, and invokes devstack. Once
devstack is finished, it runs exercise.sh which performs some basic
integration testing. After everything is done, the script copies all
of the log files back to the Jenkins workspace and archives them along
with the console output of the run. If testing was successful, it
deletes the node. The Jenkins job that does this is the somewhat
awkwardly named gate-integration-tests-devstack-vm.

If testing fails, the machine is not immediately deleted. It's kept
around for 24 hours in case it contains information critical to
understanding what's wrong. In the future, we hope to be able to
install developer SSH keys on VMs from failed test runs, but for the
moment the policies of the providers who are donating test resources
do not permit that. However, most problems can be diagnosed from the
log data that are copied back to Jenkins. There is a script that
cleans up old images and VMs that runs once per hour. It's
devstack-vm-reap.py and is invoked by the Jenkins job
devstack-reap-vms.  

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
provider supplied the node the test ran on, search for
"NODE_PROVIDER=" near the top of the console output.

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
captured by screen in files named "screen-*.txt". You may find a
traceback there that isn't in syslog.

After examining the output from the test, if you believe the result
was a false negative, you can retrigger the test by clicking on the
"Retrigger" link on the left side of the screen. If a test failure is
a result of a race condition in the OpenStack code, please take the
opportunity to try to identify it, and file a bug report or fix the
problem. If it seems to be related to a specific devstack gate node
provider, we'd love it if you could help identify what the variable
might be (whether in the devstack-gate scripts, devstack itself,
OpenStack, or even the provider's service).

Contributions Welcome
=====================

All of the OpenStack developer infrastructure is freely available and
managed in source code repositories just like the code of OpenStack
itself. If you'd like to contribute, just clone and propose a patch to
the relevant repository:

    https://github.com/openstack-ci/devstack-gate
    https://github.com/openstack/openstack-ci
    https://github.com/openstack/openstack-ci-puppet

You can file bugs on the openstack-ci project:

    https://launchpad.net/openstack-ci

And you can chat with us on Freenode in #openstack-dev or #openstack-infra.

Developer Setup
===============

If you'd like to work on the devstack-gate scripts and test process,
this should help you bootstrap a test environment (assuming the user
you're working as is called "jenkins"):

    export WORKSPACE=/home/jenkins/workspace
    export DEVSTACK_GATE_PREFIX=wip-
    export SKIP_DEVSTACK_GATE_PROJECT=1
    export GERRIT_BRANCH=master
    export GERRIT_PROJECT=testing

    cd /home/jenkins/workspace
    git clone https://github.com/openstack-ci/devstack-gate
    cd devstack-gate
    python vmdatabase.py
    sqlite3 /home/jenkins/vm.db

Currently the update-image script will produce a VM that only members
of the OpenStack CI team can log into.  You should start by patching
devstack-vm-update-image.py to have an option to install your own
local ssh key, and if you don't want to use the "jenkins" user, it
should also create whatever user you want to use.  Send that patch
upstream to us so it can be merged.  Then run:

    ./devstack-vm-update-image.sh <YOUR PROVIDER NAME>
    ./devstack-vm-launch.py <YOUR PROVIDER NAME>

Then you should be set to make changes and run:

    ./devstack-vm-gate.sh
