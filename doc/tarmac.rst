:title: Tarmac Configuration

Tarmac
######

Overview
********

Tarmac is a Patch Queue Manager written to manage and land merge requests in
Launchpad. It is not integrated in to Jenkins, and therefore does not
trigger Jenkins jobs to determine if a branch is good. Rather, Jenkins
triggers tarmac on a periodic basis and tarmac checks the merge queue,
performs its own tests on the branch, and either passes and merges the
branch in question, or fails the branch, reports the error to the merge
request and sets the status back to Work In Progress.

Installation
************

Tarmac is installed from packages in the Tarmac PPA. It currently is
installed and runs only on the Jenkins master.

Install Tarmac PPA
------------------
::

  add-apt-repository ppa:tarmac/ppa

Install Tarmac
--------------
::

  apt-get install tarmac

Configuration
*************

Tarmac keeps its config file in .config/tarmac/tarmac.conf in standard ini
format. That config file is, in turn, stored in
git://github.com/openstack/openstack-ci.git

Authentication
**************

Tarmac authenticates to launchpad via oauth as the hudson-openstack user.

Operation
*********

Tarmac is a command line program, which takes a subcommand and then a branch
to land as arguments.

::

  tarmac land lp:nova
