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

install /home/gerrit2/review_site/hooks/change-merged

::

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
  url = git@github.com:${name}.git
  EOF

Jenkins / Gerrit Integration
============================

Create a Jenkins User in Gerrit
-------------------------------

With the jenkins public key, as a gerrit admin user::

  cat jenkins.pub | ssh -p29418 review.openstack.org gerrit create-account --ssh-key - --full-name Jenkins jenkins

Create "CI Systems" group in gerrit, make jenkins a member

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

Launchpad Sync
**************

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
=======
::

  apt-get install python-mysqldb python-openid python-launchpadlib

Keys
====

The key for the launchpad sync user is in ~/.ssh/launchpad_rsa.

Running
=======
::

  cd openstack-ci
  git pull
  python sync_launchpad_gerrit.py
  python insert_gerrit.py
  ssh -i /home/gerrit2/.ssh/launchpadsync_rsa -p29418 review.openstack.org gerrit flush-caches
