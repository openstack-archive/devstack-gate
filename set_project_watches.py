import os
import sys
import uuid
import os
import subprocess

from datetime import datetime

import StringIO
import ConfigParser

import MySQLdb

GERRIT_USER = os.environ.get('GERRIT_USER', 'gerrit2')
GERRIT_CONFIG = os.environ.get('GERRIT_CONFIG',
                                 '/home/gerrit2/review_site/etc/gerrit.config')
GERRIT_SECURE_CONFIG = os.environ.get('GERRIT_SECURE_CONFIG',
                                 '/home/gerrit2/review_site/etc/secure.config')
GERRIT_SSH_KEY = os.environ.get('GERRIT_SSH_KEY',
                                 '/home/gerrit2/.ssh/launchpadsync_rsa')
GERRIT_CACHE_DIR = os.path.expanduser(os.environ.get('GERRIT_CACHE_DIR',
                                '~/.launchpadlib/cache'))
GERRIT_CREDENTIALS = os.path.expanduser(os.environ.get('GERRIT_CREDENTIALS',
                                '~/.launchpadlib/creds'))
GERRIT_BACKUP_PATH = os.environ.get('GERRIT_BACKUP_PATH',
                                '/home/gerrit2/dbupdates')

for check_path in (os.path.dirname(GERRIT_CACHE_DIR),
                   os.path.dirname(GERRIT_CREDENTIALS),
                   GERRIT_BACKUP_PATH):
  if not os.path.exists(check_path):
    os.makedirs(check_path)

def get_broken_config(filename):
  """ gerrit config ini files are broken and have leading tabs """
  text = ""
  with open(filename,"r") as conf:
    for line in conf.readlines():
      text = "%s%s" % (text, line.lstrip())

  fp = StringIO.StringIO(text)
  c=ConfigParser.ConfigParser()
  c.readfp(fp)
  return c

def get_type(in_type):
  if in_type == "RSA":
    return "ssh-rsa"
  else:
    return "ssh-dsa"

gerrit_config = get_broken_config(GERRIT_CONFIG)
secure_config = get_broken_config(GERRIT_SECURE_CONFIG)

DB_USER = gerrit_config.get("database", "username")
DB_PASS = secure_config.get("database","password")
DB_DB = gerrit_config.get("database","database")

db_backup_file = "%s.%s.sql" % (DB_DB, datetime.isoformat(datetime.now()))
db_backup_path = os.path.join(GERRIT_BACKUP_PATH, db_backup_file)
retval = os.system("mysqldump --opt -u%s -p%s %s > %s" %
                     (DB_USER, DB_PASS, DB_DB, db_backup_path))
if retval != 0:
  print "Problem taking a db dump, aborting db update"
  sys.exit(retval)

projects = None
if len(sys.argv) > 1:
  projects = ["openstack/%s" % sys.argv[1]]
else:
  projects = subprocess.check_output(['/usr/bin/ssh', '-p', '29418',
    '-i', GERRIT_SSH_KEY,
    '-l', GERRIT_USER, 'localhost',
    'gerrit', 'ls-projects']).split('\n')

conn = MySQLdb.connect(user = DB_USER, passwd = DB_PASS, db = DB_DB)
cur = conn.cursor()

cur.execute("select name, group_id from account_groups")

for (group_name, group_id) in cur.fetchall():
  os_project_name = 'openstack/%s' % group_name
  if os_project_name in projects:
    cur.execute("""insert into account_project_watches
                   select "Y", "N", "N", account_id,
                     %s, "" from account_group_members
                     where group_id = %s""", (os_project_name, group_id))

os.system("ssh -i %s -p29418 %s@localhost gerrit flush-caches" %
          (GERRIT_SSH_KEY, GERRIT_USER))
