#!/usr/bin/env python

# Get count of available slaves.

# Copyright (C) 2011 OpenStack LLC.
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

import vmdatabase
import os
import sys
import getopt


def main(threshold, stat_file):
    db = vmdatabase.VMDatabase()
    ready = vmdatabase.READY
    ready_nodes = []

    for provider in db.getProviders():
        for base_image in provider.base_images:
            ready_nodes = [x for x in base_image.machines if x.state == ready]
    ready_count = len(ready_nodes)
    set_vm_state(ready_count, stat_file)

    print "Number of slaves available: %s\n" % ready_count
    if ready_count < threshold:
        sys.exit(1)


def set_vm_state(count, stat_file):
    try:
        w_fh = open(stat_file, 'w')
        w_fh.write("slaves\n%s\n" % count)
        w_fh.close()
    except IOError, err:
        print >>sys.stderr, "warning: unable to update stat file: %s" % err


def usage(msg=None):
    if msg:
        stream = sys.stderr
    else:
        stream = sys.stdout
    stream.write("usage: %s [-h] -t threshold [-f stat-file]\n"
                 % os.path.basename(sys.argv[0]))
    if msg:
        stream.write("\nERROR: " + msg + "\n")
        exitCode = 1
    else:
        exitCode = 0
    sys.exit(exitCode)

if __name__ == '__main__':
    try:
        opts = getopt.getopt(sys.argv[1:], 'ht:f:')[0]
    except getopt.GetoptError:
        usage('invalid option selected')

    threshold = None
    stat_file = None
    for opt, value in opts:
        if (opt in ('-h')):
            usage()
        elif (opt in ('-f')):
            stat_file = value
        elif (opt in ('-t')):
            threshold = value

    if not threshold:
        usage('please specify threshold')
    try:
        threshold = int(threshold)
    except TypeError, err:
        usage('invalid threshold specified')

    if not stat_file:
        stat_file = os.path.expanduser('~/vm-threshold.txt')

    main(threshold, stat_file)
