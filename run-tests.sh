#!/bin/bash

# Run all test-*.sh functions, fail if any of them fail

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

set -o errexit

# this is mostly syntactic sugar to make it easy on the reader of the tests
trap exit_trap EXIT
function exit_trap {
    local r=$?
    if [[ "$r" -eq "0" ]]; then
        echo "All tests run successfully"
    else
        echo "ERROR! some tests failed, please see detailed output"
    fi
}

for testfile in test-*.sh; do
    echo "Running $testfile"
    ./$testfile
    echo
done
