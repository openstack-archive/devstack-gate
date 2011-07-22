import os, sys, subprocess
from launchpadlib.launchpad import Launchpad
from launchpadlib.uris import LPNET_SERVICE_ROOT
from openid.consumer import consumer
from openid.cryptutil import randomString
import pickle



cachedir="~/.launchpadlib/cache"
credentials="~/.launchpadlib/creds"

if not os.path.exists("~/.launchpadlib"):
  os.makedirs("~/.launchpadlib")

launchpad = Launchpad.login_anonymously("Gerrit User Sync", "production",
                                        cachedir,
                                        credentials_file=credentials)

def get_type(in_type):
  if in_type == "RSA":
    return "ssh-rsa"
  else:
    return "ssh-dsa"


teams_todo = [
  "burrow",
  "burrow-core",
  "glance",
  "glance-core",
  "keystone",
  "keystone-core",
  "openstack",
  "openstack-admins",
  "openstack-ci",
  "lunr-core",
  "nova",
  "nova-core",
  "swift",
  "swift-core",
  ]

users={}
groups={}
groups_in_groups={}

for team_todo in teams_todo:

  team = launchpad.people[team_todo]
  details = [detail for detail in team.members_details]
  
  groups[team.name] = team.display_name

  for detail in details:

    user = None
    member = detail.member
    if member.is_team:
      group_in_group = groups_in_groups.get(team.name, [])
      group_in_group.append(member.name)
      groups_in_groups[team.name] = group_in_group

    else:
      status = detail.status

      login = member.name
      if users.has_key(login):
        user = users[login]
      else:
        full_name = member.display_name

        ssh_keys = ["%s %s %s" % (get_type(key.keytype), key.keytext, key.comment) for key in member.sshkeys]

        openid_consumer = consumer.Consumer(dict(id=randomString(16, '0123456789abcdef')), None)
        openid_request = openid_consumer.begin("https://launchpad.net/~%s" % member.name)
        openid_external_id = openid_request.endpoint.getLocalID()

        email = None
        try:
          email = member.preferred_email_address.email
        except ValueError:
          pass

        user = dict(name=full_name,
                    ssh_keys=ssh_keys,
                    openid_external_id=openid_external_id,
                    email=email,
                    add_groups=[],
                    rm_groups=[])
        

      if (status == "Approved" or status == "Administrator") and member.is_valid:
        user['add_groups'].append(team.name)
      else:
        user['rm_groups'].append(team.name)
      users[login] = user


with open("users.pickle", "w") as user_file:
  pickle.dump([users, groups, groups_in_groups], user_file)

