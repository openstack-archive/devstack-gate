#!/bin/bash

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

ERRORS=0

TEMPEST_FULL_MASTER="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification,n-net"

TEMPEST_NEUTRON_MASTER="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta,q-lbaas,q-fwaas,q-metering"

TEMPEST_NEUTRON_KILO="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta,q-lbaas,q-fwaas,q-metering,q-vpn"

TEMPEST_HEAT_SLOW_MASTER="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification,quantum,q-svc,q-agt,q-dhcp,q-l3,q-meta,q-lbaas,q-fwaas,q-metering"

GRENADE_NEW_MASTER="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,n-net,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification"

GRENADE_JUNO_MASTER="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,n-net,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification"

GRENADE_ICEHOUSE_MASTER="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,n-net,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification"

TEMPEST_FULL_JUNO="n-api,n-crt,n-obj,n-cpu,n-sch,n-cond,g-api,g-reg,key,horizon,c-api,c-vol,c-sch,c-bak,cinder,s-proxy,s-account,s-container,s-object,mysql,rabbit,dstat,tempest,ceilometer-acompute,ceilometer-acentral,ceilometer-collector,ceilometer-api,ceilometer-alarm-notifier,ceilometer-alarm-evaluator,ceilometer-anotification,n-net"

# Utility function for tests
function assert_list_equal {
    local source=$(echo $1 | awk 'BEGIN{RS=",";} {print $1}' | sort -V | xargs echo)
    local target=$(echo $2 | awk 'BEGIN{RS=",";} {print $1}' | sort -V | xargs echo)
    if [[ "$target" != "$source" ]]; then
        echo -n `caller 0 | awk '{print $2}'`
        echo -e " - ERROR\n    $target \n != $source"
        ERRORS=1
    else
        # simple backtrace progress detector
        echo -n `caller 0 | awk '{print $2}'`
        echo " - ok"
    fi
}

function test_full_master {
    local results=$(DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py)
    assert_list_equal $TEMPEST_FULL_MASTER $results
}

function test_full_feature_ec {
    local results=$(DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py -b feature/ec)
    assert_list_equal $TEMPEST_FULL_MASTER $results
}

function test_full_juno {
    local results=$(DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py -b stable/juno)
    assert_list_equal $TEMPEST_FULL_JUNO $results
}

function test_neutron_master {
    local results=$(DEVSTACK_GATE_NEUTRON=1 DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py)
    assert_list_equal $TEMPEST_NEUTRON_MASTER $results
}

function test_neutron_kilo {
    local results=$(DEVSTACK_GATE_NEUTRON=1 DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py -b stable/kilo)
    assert_list_equal $TEMPEST_NEUTRON_KILO $results
}

function test_heat_slow_master {
    local results=$(DEVSTACK_GATE_TEMPEST_HEAT_SLOW=1 DEVSTACK_GATE_NEUTRON=1 DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py)
    assert_list_equal $TEMPEST_HEAT_SLOW_MASTER $results
}

function test_grenade_new_master {
    local results=$(DEVSTACK_GATE_TEMPEST_HEAT_SLOW=1 DEVSTACK_GATE_GRENADE=pullup DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py)
    assert_list_equal $GRENADE_NEW_MASTER $results
}

function test_grenade_juno_master {
    local results=$(DEVSTACK_GATE_GRENADE=pullup DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py -b stable/juno)
    assert_list_equal $GRENADE_JUNO_MASTER $results
}

function test_grenade_icehouse_master {
    local results=$(DEVSTACK_GATE_GRENADE=pullup DEVSTACK_GATE_TEMPEST=1 ./test-matrix.py -b stable/icehouse)
    assert_list_equal $GRENADE_ICEHOUSE_MASTER $results
}

test_full_master
test_full_feature_ec
test_neutron_master
test_neutron_kilo
test_heat_slow_master
test_grenade_new_master
test_grenade_juno_master
test_grenade_icehouse_master
test_full_juno

if [[ "$ERRORS" -ne 0 ]]; then
    echo "Errors detected, job failed"
    exit 1
fi
