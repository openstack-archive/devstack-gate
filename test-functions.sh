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
    if [[ "$1" != "$2" ]]; then
        echo "$1 != $2 on line $3"
        exit 1
    fi
}

# Tests follow:
function test_one_on_master {
    # devstack-gate  master  ZA
    echo "== Test one on master"

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack-infra/devstack-gate'
    ZUUL_BRANCH='master'
    ZUUL_REF='refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZA' $LINENO
}

function test_two_on_master {
    # devstack-gate  master  ZA
    # glance         master  ZB
    echo "== Test two on master"

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack/glance'
    ZUUL_BRANCH='master'
    ZUUL_REF='refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/master/ZB'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZB' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/master/ZB' $LINENO
}

function test_multi_branch_on_master {
    # devstack-gate        master         ZA
    # glance               stable/havana  ZB
    # python-glanceclient  master         ZC
    echo "== Test multi-branch on master"

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack/python-glanceclient'
    ZUUL_BRANCH='master'
    ZUUL_REF='refs/zuul/master/ZC'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZC'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZC'
    TEST_ZUUL_REFS[python-glanceclient]+=' refs/zuul/master/ZC'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH
    setup_project openstack/python-glanceclient $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZC' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'master' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'refs/zuul/master/ZC' $LINENO
}

function test_multi_branch_on_stable {
    # devstack-gate        master         ZA
    # glance               stable/havana  ZB
    # python-glanceclient not in queue
    echo "== Test multi-branch on stable"

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack/glance'
    ZUUL_BRANCH='stable/havana'
    ZUUL_REF='refs/zuul/stable/havana/ZB'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZA'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZB'

    setup_project openstack-infra/devstack-gate $ZUUL_BRANCH
    setup_project openstack/glance $ZUUL_BRANCH
    setup_project openstack/python-glanceclient $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZB' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZB' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master' $LINENO
}

function test_grenade_backward {
    # devstack-gate        master         ZA
    # nova                 stable/havana  ZB
    # keystone             stable/havana  ZC
    # keystone             master         ZD
    # glance               master         ZE
    # swift not in queue
    # python-glanceclient not in queue
    echo "== Test grenade backward"
    # havana -> master (with changes)

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack/glance'
    ZUUL_BRANCH='master'
    ZUUL_REF='refs/zuul/master/ZE'
    GRENADE_OLD_BRANCH='stable/havana'
    GRENADE_NEW_BRANCH='master'
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

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'refs/zuul/stable/havana/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/stable/havana/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'stable/havana' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'stable/havana' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master' $LINENO

    declare -A TEST_GIT_CHECKOUTS

    setup_project openstack-infra/devstack-gate $GRENADE_NEW_BRANCH
    setup_project openstack/nova $GRENADE_NEW_BRANCH
    setup_project openstack/keystone $GRENADE_NEW_BRANCH
    setup_project openstack/glance $GRENADE_NEW_BRANCH
    setup_project openstack/swift $GRENADE_NEW_BRANCH
    setup_project openstack/python-glanceclient $GRENADE_NEW_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'master' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'master' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master' $LINENO
}

function test_grenade_forward {
    # devstack-gate        master         ZA
    # nova                 master         ZB
    # keystone             stable/havana  ZC
    # keystone             master         ZD
    # glance               stable/havana  ZE
    # swift not in queue
    # python-glanceclient not in queue
    echo "== Test grenade forward"
    # havana (with changes) -> master

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack/glance'
    ZUUL_BRANCH='stable/havana'
    ZUUL_REF='refs/zuul/stable/havana/ZE'
    GRENADE_OLD_BRANCH='stable/havana'
    GRENADE_NEW_BRANCH='master'
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

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'stable/havana' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/stable/havana/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'stable/havana' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master' $LINENO

    declare -A TEST_GIT_CHECKOUTS

    setup_project openstack-infra/devstack-gate $GRENADE_NEW_BRANCH
    setup_project openstack/nova $GRENADE_NEW_BRANCH
    setup_project openstack/keystone $GRENADE_NEW_BRANCH
    setup_project openstack/glance $GRENADE_NEW_BRANCH
    setup_project openstack/swift $GRENADE_NEW_BRANCH
    setup_project openstack/python-glanceclient $GRENADE_NEW_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[nova]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[keystone]}" 'refs/zuul/master/ZE' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'master' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'master' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master' $LINENO
}

function test_branch_override {
    # glance               stable/havana  ZA
    # devstack-gate        master         ZB
    # swift not in queue
    # python-glanceclient not in queue
    echo "== Test branch override"

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_PROJECT='openstack-infra/devstack-gate'
    ZUUL_BRANCH='master'
    ZUUL_REF='refs/zuul/master/ZB'
    OVERRIDE_ZUUL_BRANCH='stable/havana'
    TEST_ZUUL_REFS[devstack-gate]+=' refs/zuul/master/ZB'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZA'
    TEST_ZUUL_REFS[glance]+=' refs/zuul/stable/havana/ZB'

    setup_project openstack-infra/devstack-gate $OVERRIDE_ZUUL_BRANCH
    setup_project openstack/glance $OVERRIDE_ZUUL_BRANCH
    setup_project openstack/swift $OVERRIDE_ZUUL_BRANCH
    setup_project openstack/python-glanceclient $OVERRIDE_ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[devstack-gate]}" 'refs/zuul/master/ZB' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'refs/zuul/stable/havana/ZB' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[swift]}" 'stable/havana' $LINENO
    assert_equal "${TEST_GIT_CHECKOUTS[python-glanceclient]}" 'master' $LINENO
}

function test_periodic {
    # No queue
    echo "== Test periodic"

    declare -A TEST_GIT_CHECKOUTS
    declare -A TEST_ZUUL_REFS
    ZUUL_BRANCH='stable/havana'

    setup_project openstack/glance $ZUUL_BRANCH

    assert_equal "${TEST_GIT_CHECKOUTS[glance]}" 'stable/havana' $LINENO
}

# Run tests:
#set -o xtrace
test_two_on_master
test_one_on_master
test_multi_branch_on_master
test_multi_branch_on_stable
test_grenade_backward
test_grenade_forward
test_branch_override
test_periodic
