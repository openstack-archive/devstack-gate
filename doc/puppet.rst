Puppet Modules
==============

Overview
--------

Much of the OpenStack project infrastructure is deployed and managed using
puppet.
The OpenStack CI team manage a number of custom puppet modules outlined in this
document.

Doc Server
----------

The doc_server module configures nginx [4]_ to serve the documentation for
several specified OpenStack projects.  At the moment to add a site to this
you need to edit ``modules/doc_server/manifests/init.pp`` and add a line as
follows:

.. code-block:: ruby
   :linenos:

   doc_server::site { "swift": }

In this example nginx will be configured to serve ``swift.openstack.org``
from ``/srv/docs/swift`` and ``swift.openstack.org/tarballs/`` from 
``/srv/tarballs/swift``

Lodgeit
-------

The lodgeit module installs and configures lodgeit [1]_ on required servers to
be used as paste installations.  For OpenStack we use a fork of this maintained
by dcolish [2]_ which contains bug fixes necessary for us to use it.

Puppet will configure lodgeit to use drizzle [3]_ as a database backend,
nginx [4]_ as a front-end proxy and upstart scripts to run the lodgeit
instances.  It will store and maintain local branch of the the mercurial
repository for lodgeit in ``/tmp/lodgeit-main``.

To use this module you need to add something similar to the following in the
main ``site.pp`` manifest:

.. code-block:: ruby
   :linenos:

   node "paste.openstack.org" {
     include openstack_server
     include lodgeit
     lodgeit::site { "openstack":
       port => "5000",
       image => "header-bg2.png"
     }

     lodgeit::site { "drizzle":
       port => "5001"
     }
   }

In this example we include the lodgeit module which will install all the
pre-requisites for Lodgeit as well as creating a checkout ready.
The ``lodgeit::site`` calls create the individual paste sites.

The name in the ``lodgeit::site`` call will be used to determine the URL, path
and name of the site.  So "openstack" will create ``paste.openstack.org``,
place it in ``/srv/lodgeit/openstack`` and give it an upstart script called
``openstack-paste``.  It will also change the h1 tag to say "Openstack".

The port number given needs to be a unique port which the lodgeit service will
run on.  The puppet script will then configure nginx to proxy to that port.

Finally if an image is given that will be used instead of text inside the h1
tag of the site.  The images need to be stored in the ``modules/lodgeit/files``
directory.

Lodgeit Backups
^^^^^^^^^^^^^^^

The lodgeit module will automatically create a git repository in ``/var/backups/lodgeit_db``.  Inside this every site will have its own SQL file, for example "openstack" will have a file called ``openstack.sql``.  Every day a cron job will update the SQL file (one job per file) and commit it to the git repository.

.. note::
   Ideally the SQL files would have a row on every line to keep the diffs stored
   in git small, but ``drizzledump`` does not yet support this.

.. rubric:: Footnotes
.. [1] `Lodgeit homepage <http://www.pocoo.org/projects/lodgeit/>`_
.. [2] `dcolish's Lodgeit fork <https://bitbucket.org/dcolish/lodgeit-main>`_
.. [3] `Drizzle homepage <http://www.dirzzle.org/>`_
.. [4] `nginx homepage <http://nginx.org/en/>`_
