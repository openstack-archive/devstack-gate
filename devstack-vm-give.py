#!/usr/bin/env python

# Turn over a devstack configured machine to the developer who
# proposed the change that is being tested.

# Copyright (C) 2011-2012 OpenStack LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import sys
import time
import getopt
import commands
import json
import urllib2
import tempfile

import vmdatabase

NODE_ID = sys.argv[1]


def main():
    db = vmdatabase.VMDatabase()
    machine = db.getMachine(NODE_ID)

    stat, out = commands.getstatusoutput(
      "ssh -p 29418 review.openstack.org gerrit" +
      "query --format=JSON change:%s" %
      os.environ['GERRIT_CHANGE_NUMBER'])

    data = json.loads(out.split('\n')[0])
    username = data['owner']['username']

    f = urllib2.urlopen('https://launchpad.net/~%s/+sshkeys' % username)
    keys = f.read()

    tmp = tempfile.NamedTemporaryFile(delete=False)
    try:
        tmp.write("""#!/bin/bash
chmod u+w ~/.ssh/authorized_keys
cat <<EOF >>~/.ssh/authorized_keys
""")
        tmp.write(keys)
        tmp.write("\nEOF\n")
        tmp.close()
        stat, out = commands.getstatusoutput("scp %s %s:/var/tmp/keys.sh" %
                                             (tmp.name, machine.ip))
        if stat:
            print out
            raise Exception("Unable to copy keys")

        stat, out = commands.getstatusoutput(
          "ssh %s /bin/sh /var/tmp/keys.sh" % machine.ip)

        if stat:
            print out
            raise Exception("Unable to add keys")
    finally:
        os.unlink(tmp.name)

    machine.user = username
    print "Added %s to authorized_keys on %s" % (username, machine.ip)

if __name__ == '__main__':
    main()
