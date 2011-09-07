:title: Jenkins Configuration

Jenkins
#######

Overview
********

Jenkins is a Continuous Integration system and the central control
system for the orchestration of both pre-merge testing and post-merge
actions such as packaging and publishing of documentation.

The overall design that Jenkins is a key part of implementing is that
all code should be reviewed and tested before being merged in to trunk,
and that as many tasks around review, testing, merging and release that
can be automated should be.

Jenkis is essentially a job queing system, and everything that is done
through Jenkins can be thought of as having a few discreet components:

* Triggers - What causes a job to be run
* Location - Where do we run a job
* Steps - What actions are taken when the job runs
* Results - What is the outcome of the job

The OpenStack Jenkins can be found at http://jenkins.openstack.org

The current system uses :doc:`tarmac` to manage Launchpad Merge
Proposals for projects using bzr as a version control system. As we add
projects which are using git, or migrate projects from bzr to git, we are
using :doc:`gerrit`

Authorization
*************

Jenkins is set up to use OpenID in a Single Sign On mode with Launchpad.
This means that all of the user and group information is managed via
Launchpad users and teams. In the Jenkins Security Matrix, a Launchpad team
name can be specified and any members of that team will be granted those
permissions. However, because of the way the information is processed, a
user will need to re-log in upon changing either team membership on
Launchpad, or changing that team's authorization in Jenkins for the new
privileges to take effect.

Deployment Testing
******************

TODO: How others can get involved in testing and integrating with
OpenStack Jenkins.

Rackspace Bare-Metal Testing Cluster
====================================

The CI team mantains a cluster of machines supplied by Rackspace to
perform bare-metal deployment and testing of OpenStack as a whole.
This installation is intended as a reference implementation of just
one of many possible testing platforms, all of which can be integrated
with the OpenStack Jenkins system.  This is a cluster of several
physical machines meaning the test environment has access to all of
the native processor features, and real-world networking, including
tagged VLANs.

Each trunk commit to an OpenStack project results in a new package
being built and pushed to the package archive.  Each time the archive
is updated, the openstack-deploy-rax job creates an OpenStack cluster
using the puppet configuration in the openstack/openstack-puppet
repository on GitHub.  When that is complete, the openstack-test-rax
job runs a test suite against the cluster.

Anyone is welcome to submit patches to the puppet modules to improve
the installation of OpenStack.  Parameterized variations in
configuration can also be added to the Puppet configuration and added
to the Jenkins job(s) that manage the installation and testing.

The Puppet repository is located at
https://github.com/openstack/openstack-puppet

Deployment and Testing Process
------------------------------

The cluster deployment is divided into two phases: base operating
system installation, and OpenStack installation.  Because the
operating system install takes considerable time (15 to 30 minutes),
has external network resource dependencies (the distribution mirror),
and has no bearing on the outcome of the OpenStack tests themselves,
the process used here effectively snapshots the machines immediately
after the base OS install and before OpenStack is installed.  LVM
snapshots and kexec are used to immediately return the cluster to a
newly installed state without incurring the additional time it would
take to install from scratch.  The openstack-deploy-rax job invokes
the process starting at :ref:`rax_openstack_install`.

Operating System Installation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The following are the steps executing during the operating system
installation process.

PXE Boot Servers
""""""""""""""""
The servers are all PXE booted with an Ubuntu installation image.
The Jenkins slave acts as the boot server.

Install Using Preseed File
""""""""""""""""""""""""""
Install Ubuntu Maverick with site-local preseed file.  The preseed
file does the following:

* Configures site-specific network info
* Configures site-specific root password
* Creates an LVM configuration that does not use the whole disk
* Adds a late-command that sets up a post-install script

Run the Post-Install Script
"""""""""""""""""""""""""""

At the end of the OS installation, before the first boot into the new
system, the post-install script does the following:

* Configures rsyslog to use TCP to stream log entries to the Jenkins
  slave and cache those entries when the network is unavailable.
* Stages (but does not run) the "install" script that installs
  Puppet and kicks off the OpenStack installation process.
* Stages (but does not run) the "reset" script that resets the machine
  to the state it should be in immediately before starting the
  OpenStack installation and kicks off the "install" script.
* Stages (but does not run) the "idle" script that reboots the
  machines into a state where they are not performing any activity.
* Stages the "firstboot" script and configures it to be run by
  rc.local during the next boot.

The operating system installation then completes by booting into the
new system where the "firstboot" script is run.

Run the Firstboot Script
""""""""""""""""""""""""

On the first boot, the following happens:

* Installs kexec for fast rebooting.
* rc.local is modified so that firstboot will not run on subsequent
  reboots.
* Renames the "root" LVM volume to "orig_root" and creates a snapshot of
  the volume named "root".

This is the end of the operating system installation, and the system
is currently in the pristine state that will be used by the test
procedure (which is stored in the LVM volume "orig_root").

.. _rax_openstack_install:

OpenStack Installation
~~~~~~~~~~~~~~~~~~~~~~

When the openstack-deploy-rax job runs, it does the following, each
time starting from the pristine state arrived at the end of the
previous section.

Run the Reset Script on the Infrastructure Node
"""""""""""""""""""""""""""""""""""""""""""""""

The "reset" script does the following:

* Remove the "last_root" LVM volume if it exists.
* Rename the "root" LVM volume to "last_root".
* Create a snapshot of "orig_root" named "root".
* Configure rc.local to run the "install" script (previously staged
  during the operating system installation) on the next boot.
* Reboot.

Because kexec is in use, resetting the environment and rebooting into
the pristine state takes only about 6 seconds.

Run the Idle Script on All Other Nodes
""""""""""""""""""""""""""""""""""""""

On any node where Jenkins is not ready to start the installation but
the node may still be running OpenStack infrastructure that might
interfere with the new installation, the "idle" script is run to
reboot into the pristine environment without triggering the OpenStack
install.  Later, Jenkins will run the "reset" script on these nodes to
start their OpenStack installation.  The "idle" script does the
following:

* Remove the "last_root" LVM volume if it exists.
* Rename the "root" LVM volume to "last_root".
* Create a snapshot of "orig_root" named "root".
* Reboot.

Run the Install Script
""""""""""""""""""""""

On each node, the "install" script is invoked by rc.local after the
reboot triggered by the "reset" script.  It does the following:

* Install puppet, and configure it to use the puppetmaster server.
* Run Puppet.

Puppet handles the entirety of the OpenStack installation according to
the configuration described in the openstack/opestack-puppet repository.

Cluster Configuration
---------------------

VLANs
~~~~~

+----+--------------------------------+
|VLAN| Description                    |
+====+================================+
|90  | Native VLAN                    |
+----+--------------------------------+
|91  | Internal cluster communication |
|    | network: 192.168.91.0/24       |
+----+--------------------------------+
|92  | Public Internet (fake)         |
|    | network: 192.168.92.0/24       |
+----+--------------------------------+

Servers
~~~~~~~
The servers are located on the Rackspace network, only accessible via
VPN.

+-----------+--------------+---------------+
| Server    | Primary IP   | Management IP |
+===========+==============+===============+
|driver1    | 10.14.247.36 | 10.14.247.46  |
+-----------+--------------+---------------+
|baremetal01| 10.14.247.37 | 10.14.247.47  |
+-----------+--------------+---------------+
|baremetal02| 10.14.247.38 | 10.14.247.48  |
+-----------+--------------+---------------+
|baremetal03| 10.14.247.39 | 10.14.247.49  |
+-----------+--------------+---------------+
|baremetal04| 10.14.247.40 | 10.14.247.50  |
+-----------+--------------+---------------+

driver1
  The deployment server and Jenkins slave.  It will deploy the servers
  (currently using djeep and puppet).  It is also the puppetmaster
  server, and it is where the test framework will run.  It should not
  run any OpenStack components, but we can install libraries or
  anything else needed to run tests.

baremetal01
  Configured with the 'nova-infra' role from the puppet recipes.  It
  runs MySQL and glance, and other components needed to run a nova
  cluster.

baremetal02-04
  Configured with the 'nova' role, they are the compute nodes.

