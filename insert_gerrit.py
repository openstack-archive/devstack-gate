import MySQLdb
import pickle
import uuid
import os

import StringIO
import ConfigParser

GERRIT_CONFIG = os.environ.get('GERRIT_CONFIG','/home/gerrit2/review_site/etc/gerrit.config')
GERRIT_SECURE_CONFIG = os.environ.get('GERRIT_SECURE_CONFIG','/home/gerrit2/review_site/etc/secure.config')

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

gerrit_config = get_broken_config(GERRIT_CONFIG)
secure_config = get_broken_config(GERRIT_SECURE_CONFIG)

conn = MySQLdb.connect(user=gerrit_config.get("database","username"),
                       passwd=secure_config.get("database","password"),
                       db=gerrit_config.get("database","database"))
cur = conn.cursor()

users={}
groups={}
groups_in_groups={}
group_ids={}

with open("users.pickle","r") as users_file:
  (users, groups, groups_in_groups) = pickle.load(users_file)

# squish in unknown groups
for (k,v) in groups_in_groups.items():
  for g in v:
    if g not in groups.keys():
      groups[g] = None

# account_groups
for (k,v) in groups.items():
  if cur.execute("select group_id from account_groups where name = %s", k):
    group_ids[k] = cur.fetchall()[0][0]
  else:
    cur.execute("""insert into account_group_id (s) values (NULL)""");
    cur.execute("select max(s) from account_group_id")
    group_id = cur.fetchall()[0][0]

    # Match the 40-char 'uuid' that java is producing
    group_uuid = uuid.uuid4()
    second_uuid = uuid.uuid4()
    full_uuid = "%s%s" % (group_uuid.hex, second_uuid.hex[:8])

    cur.execute("""insert into account_groups
                   (group_id, group_type, owner_group_id,
                    name, description, group_uuid)
                   values
                   (%s, 'INTERNAL', 1, %s, %s, %s)""",
                (group_id, k,v, full_uuid))
    cur.execute("""insert into account_group_names (group_id, name) values
    (%s, %s)""",
    (group_id, k))

    group_ids[k] = group_id

# account_group_includes
for (k,v) in groups_in_groups.items():
  for g in v:
    try:
      cur.execute("""insert into account_group_includes
                       (group_id, include_id)
                      values (%s, %s)""",
                  (group_ids[k], group_ids[g]))
    except MySQLdb.IntegrityError:
      pass

for (k,v) in users.items():

  # accounts
  account_id = None
  if cur.execute("""select account_id from account_external_ids where
    external_id in (%s, %s)""", (v['openid_external_id'], "username:%s" % k)):
    account_id = cur.fetchall()[0][0]
  else:

    cur.execute("""insert into account_id (s) values (NULL)""");
    cur.execute("select max(s) from account_id")
    account_id = cur.fetchall()[0][0]

    cur.execute("""insert into accounts (account_id, full_name, preferred_email) values
    (%s, %s, %s)""", (account_id, v['name'],v['email']))

  # account_ssh_keys
  for key in v['ssh_keys']:

    cur.execute("""select ssh_public_key from account_ssh_keys where
      account_id = %s""", account_id)
    db_keys = [r[0].strip() for r in cur.fetchall()]
    if key.strip() not in db_keys:

      cur.execute("""select max(seq)+1 from account_ssh_keys
                            where account_id = %s""", account_id)
      seq = cur.fetchall()[0][0]
      if seq is None:
        seq = 1
      cur.execute("""insert into account_ssh_keys
                      (ssh_public_key, valid, account_id, seq) 
                      values
                      (%s, 'Y', %s, %s)""", 
                      (key.strip(), account_id, seq))

  # account_external_ids
  ## external_id
  if not cur.execute("""select account_id from account_external_ids
                        where account_id = %s and external_id = %s""",
                     (account_id, v['openid_external_id'])):
    cur.execute("""insert into account_external_ids
                   (account_id, email_address, external_id)
                   values (%s, %s, %s)""",
               (account_id, v['email'], v['openid_external_id']))
  if not cur.execute("""select account_id from account_external_ids
                        where account_id = %s and external_id = %s""",
                     (account_id, "username:%s" % k)):
    cur.execute("""insert into account_external_ids
                   (account_id, external_id) values (%s, %s)""",
                (account_id, "username:%s" % k))

  # account_group_memebers
  for group in v['add_groups']:
    if not cur.execute("""select account_id from account_group_members
                          where account_id = %s and group_id = %s""",
                       (account_id, group_ids[group])):
      cur.execute("""insert into account_group_members 
                       (account_id, group_id)
                     values (%s, %s)""", (account_id, group_ids[group]))
  for group in v['rm_groups']:
    cur.execute("""delete from account_group_members
                   where account_id = %s and group_id = %s""",
                (account_id, group_ids[group]))
