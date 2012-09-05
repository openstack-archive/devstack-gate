#!/usr/bin/env python

# Delete a devstack VM.

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
import getopt
import time

import vmdatabase
import utils

NODE_NAME = sys.argv[1]


def main():
    db = vmdatabase.VMDatabase()

    machine = db.getMachineByJenkinsName(NODE_NAME)
    if machine.state != vmdatabase.HOLD:
        machine.state = vmdatabase.DELETE


if __name__ == '__main__':
    main()
