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

using ssh key of a gerrit admin::

  ssh -p 29418 review.openstack.org gerrit create-project --name openstack/project

Grant the user the following privileges:

* push
* push merge commit
* forge committer
* forge author
* create reference

Do the initial push of the project with::

  git push ssh://USERNAME@review.openstack.org:29418/openstack/project.git HEAD:refs/heads/master

Remove the above privileges, and then set the access controls as
specified in :ref:`acl`.

Have Jenkins Monitor a Gerrit Project
=====================================

In jenkins, under source code management:

* select git

  * url: ssh://jenkins@review.openstack.org:29418/openstack/project.git
  * click "advanced"

    * refspec: $GERRIT_REFSPEC
    * click "advanced"

      * choosing stragety: gerrit trigger


* select gerrit event under build triggers:

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

.. _acl:

Access Controls
***************

Goal:

#. Anonymous users can read all projects.
#. All registered users can perform informational code review (+/-1) 
   on any project.
#. Jenkins can perform verification (blocking or approving: +/-1).
#. All registered users can create changes.
#. Members of $PROJECT-core group can perform full code review 
   (blocking or approving: +/- 2), and submit changes to be merged.
#. Release group (ttx and jenkins) can push annotated tags.

Set permissions as follows::

  admins: openstack-ci-admins
  all-projects: 
    refs/*
    read: anonymous
    push annotated tag: release managers, ci tools
    
    refs/heads/*
    label code review -1/+1: registered users
    label verified -1/+1: ci systems
    
    refs/meta/config
    read: project owners

    refs/for/refs/*
    push: registered

  project foo:
    refs/*
    owner: Administrators

    refs/heads/*
    label code review -2/+2: foo-core
    submit: foo-core

