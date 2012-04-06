#!/usr/bin/env python

# Record a result from a build in the database.

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

import sys

import vmdatabase

RESULT_ID = sys.argv[1]
RESULT = sys.argv[2]

RESULTS = dict(success=vmdatabase.RESULT_SUCCESS,
               failure=vmdatabase.RESULT_FAILURE,
               timeout=vmdatabase.RESULT_TIMEOUT,
               )

def main():
    db = vmdatabase.VMDatabase()
    result = db.getResult(RESULT_ID)

    value = RESULTS[RESULT]
    # This gets called with an argument of 'timeout' after every run,
    # regardless of whether a timeout occured; so in that case, only
    # set the result to timeout if there is not already a result.
    if not (value == vmdatabase.RESULT_TIMEOUT and result.result):
        result.setResult(value)

if __name__ == '__main__':
    main()
