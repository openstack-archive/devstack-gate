:title: Gerrit Installation

Gerrit
######

Objective
*********

A workflow where developers submit changes to gerrit, changes are
peer-reviewed and automatically tested by Jenkins before being
committed to the main repo.  The public repo is on github.

References
**********

* http://gerrit.googlecode.com/svn/documentation/2.2.1/install.html
* http://feeding.cloud.geek.nz/2011/04/code-reviews-with-gerrit-and-gitorious.html
* http://feeding.cloud.geek.nz/2011/05/integrating-launchpad-and-gerrit-code.html
* http://www.infoq.com/articles/Gerrit-jenkins-hudson
* https://wiki.jenkins-ci.org/display/JENKINS/Gerrit+Trigger
* https://wiki.mahara.org/index.php/Developer_Area/Developer_Tools

Known Issues
************

* Don't use innodb until at least gerrit 2.2.2 because of:
  http://code.google.com/p/gerrit/issues/detail?id=518

Installation
************

Host Installation
=================

Prepare Host
------------
::

  apt-get install bzr puppet emacs23-nox
  bzr branch lp:~mordred/+junk/osapuppetconf
  cd osapuppetconf/
  puppet apply --modulepath=`pwd`/modules manifests/site.pp
  apt-get install ufw
  ufw enable
  ufw allow from any to any port 22
  ufw allow from any to any port 29418
  ufw allow from any to any port 80
  ufw allow from any to any port 443
  apt-get install git openjdk-6-jre-headless mysql-server

Install MySQL
-------------
::

  mysql -u root -p

  CREATE USER 'gerrit2'@'localhost' IDENTIFIED BY 'secret';
  CREATE DATABASE reviewdb;
  ALTER DATABASE reviewdb charset=latin1;
  GRANT ALL ON reviewdb.* TO 'gerrit2'@'localhost';
  FLUSH PRIVILEGES;

  sudo useradd -r gerrit2
  sudo chsh gerrit2 -s /bin/bash
  sudo su - gerrit2


Install Gerrit
--------------
::

  wget http://gerrit.googlecode.com/files/gerrit-2.2.1.war
  mv gerrit-2.2.1.war gerrit.war     
  java -jar gerrit.war init -d review_site

::

  *** Gerrit Code Review 2.2.1
  *** 

  Create '/home/gerrit2/review_site' [Y/n]? 

  *** Git Repositories
  *** 

  Location of Git repositories   [git]: 

  *** SQL Database
  *** 

  Database server type           [H2/?]: ?
  Supported options are:
  h2
  postgresql
  mysql
  jdbc
  Database server type           [H2/?]: mysql

  Gerrit Code Review is not shipped with MySQL Connector/J 5.1.10
  **  This library is required for your configuration. **
  Download and install it now [Y/n]? 
  Downloading http://repo2.maven.org/maven2/mysql/mysql-connector-java/5.1.10/mysql-connector-java-5.1.10.jar ... OK
  Checksum mysql-connector-java-5.1.10.jar OK
  Server hostname                [localhost]: 
  Server port                    [(MYSQL default)]: 
  Database name                  [reviewdb]: 
  Database username              [gerrit2]: 
  gerrit2's password             : 
  confirm password : 

  *** User Authentication
  *** 

  Authentication method          [OPENID/?]: 

  *** Email Delivery
  *** 

  SMTP server hostname           [localhost]: 
  SMTP server port               [(default)]: 
  SMTP encryption                [NONE/?]: 
  SMTP username                  : 

  *** Container Process
  *** 

  Run as                         [gerrit2]: 
  Java runtime                   [/usr/lib/jvm/java-6-openjdk/jre]: 
  Copy gerrit.war to /home/gerrit2/review_site/bin/gerrit.war [Y/n]? 
  Copying gerrit.war to /home/gerrit2/review_site/bin/gerrit.war

  *** SSH Daemon
  *** 

  Listen on address              [*]: 
  Listen on port                 [29418]: 

  Gerrit Code Review is not shipped with Bouncy Castle Crypto v144
  If available, Gerrit can take advantage of features
  in the library, but will also function without it.
  Download and install it now [Y/n]? 
  Downloading http://www.bouncycastle.org/download/bcprov-jdk16-144.jar ... OK
  Checksum bcprov-jdk16-144.jar OK
  Generating SSH host key ... rsa... dsa... done

  *** HTTP Daemon
  *** 

  Behind reverse proxy           [y/N]? y
  Proxy uses SSL (https://)      [y/N]? y
  Subdirectory on proxy server   [/]: 
  Listen on address              [*]: 
  Listen on port                 [8081]: 
  Canonical URL                  [https://review.openstack.org/]: 

  Initialized /home/gerrit2/review_site
  Executing /home/gerrit2/review_site/bin/gerrit.sh start
  Starting Gerrit Code Review: OK
  Waiting for server to start ... OK
  Opening browser ...
  Please open a browser and go to https://review.openstack.org/#admin,projects

Configure Gerrit
----------------

Update etc/gerrit.config::

  [user]
    email = review@openstack.org
  [auth]
    allowedOpenID = ^https?://(login.)?launchpad.net/.*$
  [commentlink "launchpad"]
    match = "([Bb]ug\\s+#?)(\\d+)"
    link = https://code.launchpad.net/bugs/$2

Set Gerrit to start on boot::

  ln -snf /home/gerrit2/review_site/bin/gerrit.sh /etc/init.d/gerrit
  update-rc.d gerrit defaults 90 10

  cat <<EOF >/etc/default/gerritcodereview
  GERRIT_SITE=/home/gerrit2/review_site
  EOF

Add "Approved" review type to gerrit::

  mysql -u root -p
  use reviewdb;
  insert into approval_categories values ('Approved', 'A', 2, 'MaxNoBlock', 'N', 'APRV');
  insert into approval_category_values values ('No score', 'APRV', 0);    
  insert into approval_category_values values ('Approved', 'APRV', 1);
  update approval_category_values set name = "Looks good to me (core reviewer)" where name="Looks good to me, approved";

Install Apache
--------------
::

  apt-get install apache2

create: /etc/apache2/sites-available/gerrit

::

  a2enmod ssl proxy proxy_http rewrite
  a2ensite gerrit
  a2dissite default

Install Exim
------------
::

  apt-get install exim4
  dpkg-reconfigure exim4-config

Choose "internet site", otherwise select defaults

edit: /etc/default/exim4 ::

  QUEUEINTERVAL='5m'

GitHub Setup
============

Generate an SSH key for Gerrit for use on GitHub
------------------------------------------------
::

  sudo su - gerrit2
  gerrit2@gerrit:~$ ssh-keygen        
  Generating public/private rsa key pair.
  Enter file in which to save the key (/home/gerrit2/.ssh/id_rsa): 
  Created directory '/home/gerrit2/.ssh'.
  Enter passphrase (empty for no passphrase): 
  Enter same passphrase again: 

GitHub Configuration
--------------------

#. create openstack-gerrit user on github
#. add gerrit2 ssh public key to openstack-gerrit user
#. create gerrit team in openstack org on github with push/pull access
#. add openstack-gerrit to gerrit team in openstack org
#. add public master repo to gerrit team in openstack org
#. save github host key in known_hosts

::

  gerrit2@gerrit:~$ ssh git@github.com
  The authenticity of host 'github.com (207.97.227.239)' can't be established.
  RSA key fingerprint is 16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48.
  Are you sure you want to continue connecting (yes/no)? yes
  Warning: Permanently added 'github.com,207.97.227.239' (RSA) to the list of known hosts.
  PTY allocation request failed on channel 0

Gerrit Replication to GitHub
----------------------------
::

  cat <<EOF >review_site/etc/replication.config
  [remote "github"]
  url = git@github.com:\$\{name\}.git
  EOF

Jenkins / Gerrit Integration
============================

Create a Jenkins User in Gerrit
-------------------------------

With the jenkins public key, as a gerrit admin user::

  cat jenkins.pub | ssh -p29418 review.openstack.org gerrit create-account --ssh-key - --full-name Jenkins jenkins

Create "CI Systems" group in gerrit, make jenkins a member

Create a Gerrit Git Prep Job in Jenkins
---------------------------------------

When gating trunk with Jenkins, we want to test changes as they will
appear once merged by Gerrit, but the gerrit trigger plugin will, by
default, test them as submitted.  If HEAD moves on while the change is
under review, it may end up getting merged with HEAD, and we want to
test the result.

To do that, make sure the "Hudson Template Project plugin" is
installed, then set up a new job called "Gerrit Git Prep", and add a
shell command build step (no other configuration)::

  #!/bin/sh -x
  git checkout $GERRIT_BRANCH
  git reset --hard remotes/origin/$GERRIT_BRANCH
  git merge FETCH_HEAD
  CODE=$?
  if [ ${CODE} -ne 0 ]; then
    git reset --hard remotes/origin/$GERRIT_BRANCH
    exit ${CODE}
  fi

Later, we will configure Jenkins jobs that we want to behave this way
to use this build step.

Launchpad Sync
==============

The launchpad user sync process consists of two scripts which are in
openstack/openstack-ci on github: sync_launchpad_gerrit.py and
insert_gerrit.py.

Both scripts should be run as gerrit2 on review.openstack.org

sync_launchpad_users.py runs and creates a python pickle file, users.pickle,
with all of the user and group information. This is a long process. (12
minutes)

insert_gerrit.py reads the pickle file and applies it to the MySQL database.
The gerrit caches must then be flushed.

Depends
-------
::

  apt-get install python-mysqldb python-openid python-launchpadlib

Keys
----

The key for the launchpad sync user is in ~/.ssh/launchpad_rsa. Connecting
to Launchpad requires oauth authentication - so the first time
sync_launchpad_gerrit.py is run, it will display a URL. Open this URL in a
browser and log in to launchpad as the hudson-openstack user. Subsequent
runs will run with cached credentials.

Running
-------
::

  cd openstack-ci
  git pull
  python sync_launchpad_gerrit.py
  python insert_gerrit.py
  ssh -i /home/gerrit2/.ssh/launchpadsync_rsa -p29418 review.openstack.org gerrit flush-caches

Gerrit IRC Bot
==============

Installation
------------

Ensure there is an up-to-date checkout of openstack-ci in ~gerrit2.

::

  apt-get install python-irclib python-daemon
  cp ~gerrit2/openstack-ci/gerritbot.init /etc/init.d
  chmod a+x /etc/init.d/gerritbot
  update-rc.d gerritbot defaults
  su - gerrit2
  ssh-keygen -f /home/gerrit2/.ssh/gerritbot_rsa

As a Gerrit admin, create a user for gerritbot::

  cat ~gerrit2/.ssh/gerritbot_rsa | ssh -p29418 gerrit.openstack.org gerrit create-account --ssh-key - --full-name GerritBot gerritbot

Configure gerritbot, including which events should be announced::

  cat <<EOF >~gerrit2/gerritbot.config
  [ircbot]
  nick=NICNAME
  pass=PASSWORD
  server=irc.freenode.net
  channel=openstack-dev
  port=6667
  
  [gerrit]
  user=gerritbot
  key=/home/gerrit2/.ssh/gerritbot_rsa
  host=review.openstack.org
  port=29418
  events=patchset-created, change-merged, x-vrif-minus-1, x-crvw-minus-2
  EOF

Register an account with NickServ on FreeNode, and put the account and
password in the config file.

::

  sudo /etc/init.d/gerritbot start

Launchpad Bug Integration
=========================

In addition to the hyperlinks provided by the regex in gerrit.config,
we use a Gerrit hook to update Launchpad bugs when changes referencing
them are applied.

Installation
------------

Ensure an up-to-date checkout of openstack-ci is in ~gerrit2.

::

  apt-get install python-pyme
  cp ~gerrit2/gerrit-hooks/change-merged ~gerrit2/review_site/hooks/

Create a GPG and register it with Launchpad::

  gerrit2@gerrit:~$ gpg --gen-key
  gpg (GnuPG) 1.4.11; Copyright (C) 2010 Free Software Foundation, Inc.
  This is free software: you are free to change and redistribute it.
  There is NO WARRANTY, to the extent permitted by law.
  
  Please select what kind of key you want:
     (1) RSA and RSA (default)
     (2) DSA and Elgamal
     (3) DSA (sign only)
     (4) RSA (sign only)
  Your selection? 
  RSA keys may be between 1024 and 4096 bits long.
  What keysize do you want? (2048) 
  Requested keysize is 2048 bits
  Please specify how long the key should be valid.
           0 = key does not expire
        <n>  = key expires in n days
        <n>w = key expires in n weeks
        <n>m = key expires in n months
        <n>y = key expires in n years
  Key is valid for? (0) 
  Key does not expire at all
  Is this correct? (y/N) y
  
  You need a user ID to identify your key; the software constructs the user ID
  from the Real Name, Comment and Email Address in this form:
      "Heinrich Heine (Der Dichter) <heinrichh@duesseldorf.de>"
  
  Real name: Openstack Gerrit
  Email address: review@openstack.org
  Comment: 
  You selected this USER-ID:
      "Openstack Gerrit <review@openstack.org>"
  
  Change (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? o
  You need a Passphrase to protect your secret key.
  
  gpg: gpg-agent is not available in this session
  You don't want a passphrase - this is probably a *bad* idea!
  I will do it anyway.  You can change your passphrase at any time,
  using this program with the option "--edit-key".
  
  We need to generate a lot of random bytes. It is a good idea to perform
  some other action (type on the keyboard, move the mouse, utilize the
  disks) during the prime generation; this gives the random number
  generator a better chance to gain enough entropy.
  
  gpg: /home/gerrit2/.gnupg/trustdb.gpg: trustdb created
  gpg: key 382ACA7F marked as ultimately trusted
  public and secret key created and signed.
  
  gpg: checking the trustdb
  gpg: 3 marginal(s) needed, 1 complete(s) needed, PGP trust model
  gpg: depth: 0  valid:   1  signed:   0  trust: 0-, 0q, 0n, 0m, 0f, 1u
  pub   2048R/382ACA7F 2011-07-26
          Key fingerprint = 21EF 7F30 C281 F61F 44CD  EC48 7424 9762 382A CA7F
  uid                  Openstack Gerrit <review@openstack.org>
  sub   2048R/95F6FA4A 2011-07-26
  
  gerrit2@gerrit:~$ gpg --send-keys --keyserver keyserver.ubuntu.com 382ACA7F
  gpg: sending key 382ACA7F to hkp server keyserver.ubuntu.com

Log into the Launchpad account and add the GPG key to the account.

Adding New Projects
*******************

Creating a Project in Gerrit
============================

Using ssh key of a gerrit admin (you)::

  ssh -p 29418 review.openstack.org gerrit create-project --name openstack/PROJECT

If the project is an API project (eg, image-api), we want it to share
some extra permissions that are common to all API projects (eg, the
OpenStack documentation coordinators can approve changes, see
:ref:`acl`).  Run the following command to reparent the project if it
is an API project::

  ssh -p 29418 gerrit.openstack.org gerrit set-project-parent --parent API-Projects openstack/PROJECT

Add yourself to the "Project Bootstrappers" group in Gerrit which will
give you permissions to push to the repo bypassing code review.

Do the initial push of the project with::

  git push ssh://USERNAME@review.openstack.org:29418/openstack/PROJECT.git HEAD:refs/heads/master
  git push --tags ssh://USERNAME@review.openstack.org:29418/openstack/PROJECT.git

Remove yourself from the "Project Bootstrappers" group, and then set
the access controls as specified in :ref:`acl`.

Have Jenkins Monitor a Gerrit Project
=====================================

In jenkins, under source code management:

* select git

  * url: ssh://jenkins@review.openstack.org:29418/openstack/project.git
  * click "advanced"

    * refspec: $GERRIT_REFSPEC
    * branches: origin/$GERRIT_BRANCH
    * click "advanced"

      * choosing stragety: gerrit trigger

* select gerrit event under build triggers:

  * Trigger on Comment Added

    * Approval Category: APRV
    * Approval Value: 1

  * plain openstack/project
  * path **

* Select "Add build step" under "Build"

  * select "Use builders from another project"
  * Template Project: "Gerrit Git Prep"
  * make sure this build step is the first in the sequence

Create a Project in GitHub
==========================

As a github openstack admin:

* Visit https://github.com/organizations/openstack
* Click New Repository
* Visit the gerrit team admin page
* Add the new repository to the gerrit team

Pull requests can not be disabled for a project in Github, so instead
we have a script that runs from cron to close any open pull requests
with instructions to use Gerrit.  

* Edit openstack/openstack-ci-puppet:manifests/site.pp

and add the project to the list of github projects in the gerrit class
for the gerrit.openstack.org node.

Migrating a Project from bzr
============================

Add the bzr PPA and install bzr-fastimport:

  add-apt-repository ppa:bzr/ppa
  apt-get update
  apt-get install bzr-fastimport

Doing this from the bzr PPA is important to ensure at least version 0.10 of
bzr-fastimport.

Clone the git-bzr-ng from termie:

  git clone https://github.com/termie/git-bzr-ng.git

In git-bzr-ng, you'll find a script, git-bzr. Put it somewhere in your path.
Then, to get a git repo which contains the migrated bzr branch, run:

  git bzr clone lp:${BRANCHNAME} ${LOCATION}

So, for instance, to do glance, you would do:

  git bzr clone lp:glance glance

And you will then have a git repo of glance in the glance dir. This git repo
is now suitable for uploading in to gerrit to become the new master repo.

Project Config
==============

There are a few options which need to be enabled on the project in the Admin
interface.

* Merge Strategy should be set to "Merge If Necessary"
* "Automatically resolve conflicts" should be enabled
* "Require Change-Id in commit message" should be enabled
* "Require a valid contributor agreement to upload" should be enabled

Optionally, if the PTL agrees to it:

* "Require the first line of the commit to be 50 characters or less" should
  be enabled.

.. _acl:

Access Controls
***************

High level goals:

#. Anonymous users can read all projects.
#. All registered users can perform informational code review (+/-1) 
   on any project.
#. Jenkins can perform verification (blocking or approving: +/-1).
#. All registered users can create changes.
#. The OpenStack Release Manager and Jenkins can tag releases (push
   annotated tags).
#. Members of $PROJECT-core group can perform full code review 
   (blocking or approving: +/- 2), and submit changes to be merged.
#. Members of openstack-release (Release Manager and PTLs), and
   $PROJECT-drivers (PTL and release minded people) exclusively can
   perform full code review (blocking or approving: +/- 2), and submit
   changes to be merged on milestone-proposed branches.
#. Full code review (+/- 2) of API projects should be available to the
   -core group of the corresponding implementation project as well as to
   the OpenStack Documentation Coordinators.
#. Full code review of stable branches should be available to the
   -core group of the project as well as the openstack-stable-maint
   group.

To manage API project permissions collectively across projects, API
projects are reparented to the "API-Projects" meta-project instead of
"All-Projects".  This causes them to inherit permissions from the
API-Projects project (which, in turn, inherits from All-Projects).

These permissions try to achieve the high level goals::

  All Projects (metaproject):
    refs/*
      read: anonymous
      push annotated tag: release managers, ci tools, project bootstrappers
      forge author identity: project bootstrappers  
      forge committer identity: project bootstrappers  
      push (w/ force push): project bootstrappers  
      create reference: project bootstrappers, release managers
      push merge commit: project bootstrappers

    refs/for/refs/*
      push: registered users

    refs/heads/*
      label code review: 
        -1/+1: registered users
        -2/+2: project bootstrappers
      label verified:
        -1/+1: ci tools
        -1/+1: project bootstrappers
      label approved 0/+1: project bootstrappers
      submit: ci tools
      submit: project bootstrappers
    
    refs/heads/milestone-proposed
      label code review (exclusive):
        -2/+2 openstack-release
        -1/+1 registered users
      label approved (exclusive): 0/+1: openstack-release
      owner: openstack-release

    refs/heads/stable/*
      label code review (exclusive):
        -2/+2 opestack-stable-maint
        -1/+1 registered users
      label approved (exclusive): 0/+1: opestack-stable-maint
      forge author identity: openstack-stable-maint
      forge committer identity: openstack-stable-maint

    refs/meta/config
      read: project owners

  API Projects (metaproject):
    refs/*
      owner: Administrators
      forge author identity: openstack-doc-core
      forge committer identity: openstack-doc-core

    refs/heads/*
      label code review -2/+2: openstack-doc-core
      label approved 0/+1: openstack-doc-core

  project foo:
    refs/*
      owner: Administrators
      forge author identity: foo-core
      forge committer identity: foo-core

    refs/heads/*
      label code review -2/+2: foo-core
      label approved 0/+1: foo-core

    refs/heads/milestone-proposed
      label code review -2/+2: foo-drivers
      label approved 0/+1: foo-drivers

Renaming a Project
******************

Renaming a project is not automated and is disruptive to developers,
so it should be avoided.  Allow for an hour of downtime for the
project in question, and about 10 minutes of downtime for all of
Gerrit.  All Gerrit changes, merged and open, will carry over, so
in-progress changes do not need to be merged before the move.

To rename a project:

#. Make it inacessible by editing the Access pane.  Add a "read" ACL
   for "Administrators", and mark it "exclusive".  Be sure to save
   changes.

#. Update the database::

     update account_project_watches
     set project_name = "openstack/OLD"
     where project_name = "openstack/NEW";
 
     update changes
     set dest_project_name = "openstack/OLD"
     where dest_project_name = "openstack/NEW";

#. Wait for Jenkins to be idle (or take it offline)

#. Stop Gerrit and move the Git repository::

     /etc/init.d/gerrit stop
     cd /home/gerrit2/review_site/git/openstack/
     mv OLD.git/ NEW.git
     /etc/init.d/gerrit start

#. (Bring Jenkins online if need be)

#. Rename the project in GitHub

#. Update Jenkins jobs te reference the new name.  Rename the jobs
   themselves as appropriate

#. Remove the read access ACL you set in the first step from project

#. Submit a change that updates .gitreview with the new location of the
   project

Developers will either need to re-clone a new copy of the repository,
or manually update their remotes.

Adding A New Project On The Command Line
****************************************

All of the steps involved in adding a new project to Gerrit can be
accomplished via the commandline, with the exception of creating a new repo
on github and adding the jenkins jobs.

First of all, add the .gitreview file to the repo that will be added. Then,
assuming an ssh config alias of `review` for the gerrit instance, as a person
in the Project Bootstrappers group::

     ssh review gerrit create-project --name openstack/$PROJECT
     git review -s
     git push gerrit HEAD:refs/heads/master
     git push --tags gerrit

At this point, the branch contents will be in gerrit, and the project config
settings and ACLs need to be set. These are maintained in a special branch
inside of git in gerrit. Check out the branch from git::

     git fetch gerrit +refs/meta/*:refs/remotes/gerrit-meta/*
     git checkout -b config remotes/gerrit-meta/config

There will be two interesting files, `groups` and `project.config`. `groups`
contains UUIDs and names of groups that will be referenced in
`project.config`. There is a helper script in the openstack-ci repo called
`get_group_uuid.py` which will fetch the UUID for a given group. For
$PROJECT-core and $PROJECT-drivers::

      openstack-ci/gerrit/get_group_uuid.py $GROUP_NAME

And make entries in `groups` for each one of them. Next, edit
`project.config` to look like::

      [access "refs/*"]
              owner = group Administrators
              forgeAuthor = group $PROJECT-core
              forgeCommitter = group $PROJECT-core
      [receive]
              requireChangeId = true
              requireContributorAgreement = true
      [submit]
              mergeContent = true
      [access "refs/heads/*"]
              label-Code-Review = -2..+2 group $PROJECT-core
              label-Approved = +0..+1 group $PROJECT-core
      [access "refs/heads/milestone-proposed"]
              label-Code-Review = -2..+2 group $PROJECT-drivers
              label-Approved = +0..+1 group $PROJECT-drivers

Replace $PROJECT with the name of the project.

Finally, commit the changes and push the config back up to Gerrit::

      git commit -m "Initial project config"
      git push gerrit HEAD:refs/meta/config
