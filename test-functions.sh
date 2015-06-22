#!/bin/bash

# Copyright (C) 2013 OpenStack Foundation
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

# This script tests the checkout functions defined in functions.sh.

source functions.sh

SUDO=""

# Mock out the checkout function since the refs we're checking out do
# not exist.
function git_checkout {
    local project=$1
    local branch=$2

    project=`basename $project`
    if [[ "$branch" == "FETCH_HEAD" ]]; then
        branch=$FETCH_HEAD
    fi
    TEST_GIT_CHECKOUTS[$project]=$branch
}

# Mock out the fetch function since the refs we're fetching do not
# exist.
function git_fetch_at_ref {
    local project=$1
    local ref=$2

    project=`basename $project`
    if [ "$ref" != "" ]; then
        if [[ "${TEST_ZUUL_REFS[$project]}" =~ "$ref" ]]; then
            FETCH_HEAD="$ref"
            return 0
        fi
        return 1
    else
        # return failing
        return 1
    fi
}

# Mock out git repo functions so the git repos don't have to exist.
function git_has_branch {
    local project=$1
    local branch=$2

    case $branch in
        master) return 0 ;;
        stable/havana)
            case $project in
                openstack/glance) return 0 ;;
                openstack/swift) return 0 ;;
                openstack/nova) return 0 ;;
                openstack/keystone) return 0 ;;
                opestnack/tempest) return 0 ;;
            esac
    esac
    return 1
}

function git_prune {
    return 0
}

function git_remote_update {
    return 0
}

function git_remote_set_url {
    return 0
}

function git_clone_and_cd {
    return 0
}

# Utility function for tests
function assert_equal {
    local lineno=`caller 0 | awk '{print $1}'`
    local function=`caller 0 | awk '{print $2}'`
    if [[ "$1" != "$2" ]]; then
        echo "ERROR: $1 != $2 in $function:L$lineno!"
        ERROR=1
    else
        echo "$function:L$lineno - ok"
    fi
}

function assert_raises {
    local lineno=`caller 0 | awk '{print $1}'`
    local function=`caller 0 | awk '{print $2}'`
    eval "$@" &>/dev/null
    if [[ $? -eq 0 ]]; then
        ERROR=1
        echo "ERROR: \`\`$@\`\` returned OK instead of error in $function:L$lineno!"
    fi
}

# Tests follow:
function test_one_on_master {
    # devstack-gate  master  ZA
    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack-infra/devstack-gate'
    local ZUUL_BRANCH='master'
    local ZUUL_REF='refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZA'
}

function test_two_on_master {
    # devstack-gate  master  ZA
    # glance         master  ZB
    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack/glance'
    local ZUUL_BRANCH='master'
    local ZUUL_REF='refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/master/ZB'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZB'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/master/ZB'
}

function test_multi_branch_on_master {
    # devstack-gate        master         ZA
    # glance               stable/havana  ZB
    # python-glanceclient  master         ZC
    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack/python-glanceclient'
    local ZUUL_BRANCH='master'
    local ZUUL_REF='refs/zuul/master/ZC'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZC'
    TEST_ZUUL_REFS[python-glanceclient]+=' refs/zuul/master/ZC'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH
    setup_project openstack/python-glanceclient $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZC'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'refs/zuul/master/ZC'
}

function test_multi_branch_project_override {
    # main branch is stable/havana
    # devstack-gate        master         ZA
    # devstack-gate        master         ZB
    # python-glanceclient  master         ZC
    # glance               stable/havana  ZD
    # tempest              not in queue (override to master)
    # oslo.config          not in queue (master because no stable/havana branch)
    # nova                 not in queue (stable/havana)
    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack/glance'
    local ZUUL_BRANCH='stable/havana'
    local OVERRIDE_TEMPEST_PROJECT_BRANCH='master'
    local ZUUL_REF='refs/zuul/stable/havana/ZD'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[python-glanceclient]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[python-glanceclient]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZD'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH
    setup_project openstack/python-glanceclient $ZUUL_BRANCH
    setup_project openstack/tempest $ZUUL_BRANCH
    setup_project openstack/nova $ZUUL_BRANCH
    setup_project openstack/oslo.config $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZD'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZD'
    assert_equal "${TEST_GIT_CHECKOUTS[tempest]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'stable/havana'
    assert_equal "${TEST_GIT_CHECKOUTS[oslo.config]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'refs/zuul/master/ZD'
}

function test_multi_branch_on_stable {
    # devstack-gate        master         ZA
    # glance               stable/havana  ZB
    # python-glanceclient not in queue
    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack/glance'
    local ZUUL_BRANCH='stable/havana'
    local ZUUL_REF='refs/zuul/stable/havana/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZB'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH
    setup_project openstack/python-glanceclient $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZB'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZB'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master'
}

function test_grenade_backward {
    # devstack-gate        master         ZA
    # nova                 stable/havana  ZB
    # keystone             stable/havana  ZC
    # keystone             master         ZD
    # glance               master         ZE
    # swift not in queue
    # python-glanceclient not in queue
    # havana -> master (with changes)

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack/glance'
    local ZUUL_BRANCH='master'
    local ZUUL_REF='refs/zuul/master/ZE'
    local GRENADE_OLD_BRANCH='stable/havana'
    local GRENADE_NEW_BRANCH='master'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZE'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/stable/havana/ZB'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/stable/havana/ZC'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/stable/havana/ZD'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/stable/havana/ZE'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/stable/havana/ZC'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/stable/havana/ZD'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/stable/havana/ZE'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/master/ZE'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/master/ZE'

    setup_project openstack-infra/devstack-gate $GRENADE_OLD_BRANCH
    setup_project openstack/nova $GRENADE_OLD_BRANCH
    setup_project openstack/keystone $GRENADE_OLD_BRANCH
    setup_project openstack/glance $GRENADE_OLD_BRANCH
    setup_project openstack/swift $GRENADE_OLD_BRANCH
    setup_project openstack/python-glanceclient $GRENADE_OLD_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'refs/zuul/stable/havana/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/stable/havana/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'stable/havana'
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'stable/havana'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master'

    declare -A TEST_GIT_CHECKOUTS

    setup_project openstack-infra/devstack-gate $GRENADE_NEW_BRANCH
    setup_project openstack/nova $GRENADE_NEW_BRANCH
    setup_project openstack/keystone $GRENADE_NEW_BRANCH
    setup_project openstack/glance $GRENADE_NEW_BRANCH
    setup_project openstack/swift $GRENADE_NEW_BRANCH
    setup_project openstack/python-glanceclient $GRENADE_NEW_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master'
}

function test_grenade_forward {
    # devstack-gate        master         ZA
    # nova                 master         ZB
    # keystone             stable/havana  ZC
    # keystone             master         ZD
    # glance               stable/havana  ZE
    # swift not in queue
    # python-glanceclient not in queue
    # havana (with changes) -> master

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack/glance'
    local ZUUL_BRANCH='stable/havana'
    local ZUUL_REF='refs/zuul/stable/havana/ZE'
    local GRENADE_OLD_BRANCH='stable/havana'
    local GRENADE_NEW_BRANCH='master'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZE'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[nova]+=' refs/zuul/master/ZE'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/stable/havana/ZC'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/stable/havana/ZD'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/stable/havana/ZE'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/master/ZD'
    TEST_ZUUL_REFS[keystone]+=' refs/zuul/master/ZE'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZE'

    setup_project openstack-infra/devstack-gate $GRENADE_OLD_BRANCH
    setup_project openstack/nova $GRENADE_OLD_BRANCH
    setup_project openstack/keystone $GRENADE_OLD_BRANCH
    setup_project openstack/glance $GRENADE_OLD_BRANCH
    setup_project openstack/swift $GRENADE_OLD_BRANCH
    setup_project openstack/python-glanceclient $GRENADE_OLD_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'stable/havana'
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/stable/havana/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'stable/havana'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master'

    declare -A TEST_GIT_CHECKOUTS

    setup_project openstack-infra/devstack-gate $GRENADE_NEW_BRANCH
    setup_project openstack/nova $GRENADE_NEW_BRANCH
    setup_project openstack/keystone $GRENADE_NEW_BRANCH
    setup_project openstack/glance $GRENADE_NEW_BRANCH
    setup_project openstack/swift $GRENADE_NEW_BRANCH
    setup_project openstack/python-glanceclient $GRENADE_NEW_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/master/ZE'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'master'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master'
}

function test_branch_override {
    # glance               stable/havana  ZA
    # devstack-gate        master         ZB
    # swift not in queue
    # python-glanceclient not in queue

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_PROJECT='openstack-infra/devstack-gate'
    local ZUUL_BRANCH='master'
    local ZUUL_REF='refs/zuul/master/ZB'
    local OVERRIDE_ZUUL_BRANCH='stable/havana'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZA'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZB'

    setup_project openstack-infra/devstack-gate $OVERRIDE_ZUUL_BRANCH
    setup_project openstack/glance $OVERRIDE_ZUUL_BRANCH
    setup_project openstack/swift $OVERRIDE_ZUUL_BRANCH
    setup_project openstack/python-glanceclient $OVERRIDE_ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZB'
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZB'
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'stable/havana'
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master'
}

function test_periodic {
    # No queue

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    local ZUUL_BRANCH='stable/havana'
    local ZUUL_PROJECT='openstack/glance'

    setup_project openstack/glance $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'stable/havana'
}

# Run setup_project without setting a ZUUL_BRANCH which is how a subset of
# periodic jobs operate
function test_periodic_no_branch {

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REF
    local ZUUL_PROJECT='openstack/glance'

    setup_project openstack/glance 'master'

    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'master'
}

# setup_workspace fails without argument
function test_workspace_branch_arg {
    assert_raises setup_workspace
}

function test_call_hook_if_defined {

    local filename=test_call_hook_if_defined.txt
    local save_dir=`pwd`/tmp

    mkdir -p $save_dir

    function demo_script {
        local filename=$1
        local save_dir=$2
        # Clean up any files from previous tests
        rm -f $save_dir/$filename
        call_hook_if_defined test_hook $filename $save_dir
        ret_val=$?
        return $ret_val
    }

    # No hook defined returns success 0 & no file created
    demo_script $filename $save_dir
    ret_val=$?
    assert_equal "$ret_val" "0"

    [[ -e $save_dir/$filename ]]
    file_exists=$?
    assert_equal $file_exists 1

    # Hook defined returns its error code and file with output
    function test_hook {
        echo "hello test_hook"
        return 123
    }
    demo_script $filename $save_dir
    ret_val=$?
    assert_equal "$ret_val" "123"

    [[ -e $save_dir/$filename ]]
    file_exists=$?
    assert_equal $file_exists 0

    # Make sure the expected contents has length > 0
    result_expected=`cat $save_dir/$filename | grep "hello test_hook"`
    [[ ${#result_expected} -eq "0" ]]
    assert_equal $? 1

    # Hook defined with invalid file fails
    demo_script /invalid/file.txt $save_dir
    ret_val=$?
    assert_equal "$ret_val" "1"

    # Clean up
    rm -rf $save_dir
}

# Run tests:
#set -o xtrace
test_branch_override
test_grenade_backward
test_grenade_forward
test_multi_branch_on_master
test_multi_branch_on_stable
test_multi_branch_project_override
test_one_on_master
test_periodic
test_periodic_no_branch
test_two_on_master
test_workspace_branch_arg
test_call_hook_if_defined

if [[ ! -z "$ERROR" ]]; then
    echo
    echo "FAIL: Tests have errors! See output above."
    echo
    exit 1
else
    echo
    echo "Tests completed successfully!"
    echo
fi
