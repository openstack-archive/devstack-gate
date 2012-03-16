#!/usr/bin/env python

# Update the base image that is used for devstack VMs.

# Copyright (C) 2012 OpenStack LLC.
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

import unittest
import vmdatabase

class testVMDatabase(unittest.TestCase):

    def setUp(self):
        self.db = vmdatabase.VMDatabase(':memory:')

    def test_add_provider(self):
        provider = vmdatabase.Provider(name='rackspace', driver='rackspace',
                                       username='testuser', api_key='testapikey',
                                       giftable=False)
        self.db.session.add(provider)
        self.db.commit()
        provider = vmdatabase.Provider(name='hpcloud', driver='openstack',
                                       username='testuser', api_key='testapikey',
                                       giftable=True)
        self.db.session.add(provider)
        self.db.commit()

    def test_add_base_image(self):
        self.test_add_provider()
        
        provider = self.db.getProvider('rackspace')
        base_image1 = provider.newBaseImage('oneiric', 1)
        base_image2 = provider.newBaseImage('precise', 2)

        provider = self.db.getProvider('hpcloud')
        base_image1 = provider.newBaseImage('oneiric', 1)
        base_image2 = provider.newBaseImage('precise', 2)

    def test_add_snap_image(self):
        self.test_add_base_image()
        provider = self.db.getProvider('rackspace')
        base_image1 = provider.getBaseImage('oneiric')
        base_image2 = provider.getBaseImage('precise')       
        snapshot_image1 = base_image1.newSnapshotImage('oneiric-1331683549', 1331683549, 201, 301)
        snapshot_image2 = base_image2.newSnapshotImage('precise-1331683549', 1331683549, 202, 301)

        hp_provider = self.db.getProvider('hpcloud')
        hp_base_image1 = hp_provider.getBaseImage('oneiric')
        hp_base_image2 = hp_provider.getBaseImage('precise')       
        hp_snapshot_image1 = hp_base_image1.newSnapshotImage('oneiric-1331683549', 1331929410, 211, 311)
        hp_snapshot_image2 = hp_base_image2.newSnapshotImage('precise-1331683549', 1331929410, 212, 311)

        self.db.print_state()
        assert(not base_image1.current_snapshot)
        assert(not base_image2.current_snapshot)

        snapshot_image1.state=vmdatabase.READY
        assert(base_image1.current_snapshot)
        assert(not base_image2.current_snapshot)
        assert(snapshot_image1 == base_image1.current_snapshot)

        snapshot_image2.state=vmdatabase.READY
        assert(base_image1.current_snapshot)
        assert(base_image2.current_snapshot)
        assert(snapshot_image1 == base_image1.current_snapshot)
        assert(snapshot_image2 == base_image2.current_snapshot)

        snapshot_image2_latest = base_image2.newSnapshotImage('precise-1331683550', 
                                                              1331683550, 203, 303)
        assert(base_image1.current_snapshot)
        assert(base_image2.current_snapshot)
        assert(snapshot_image1 == base_image1.current_snapshot)
        assert(snapshot_image2 == base_image2.current_snapshot)

        snapshot_image2_latest.state=vmdatabase.READY
        assert(base_image1.current_snapshot)
        assert(base_image2.current_snapshot)
        assert(snapshot_image1 == base_image1.current_snapshot)
        assert(snapshot_image2_latest == base_image2.current_snapshot)

    def test_add_machine(self):
        self.test_add_snap_image()
        provider = self.db.getProvider('rackspace')
        base_image1 = provider.getBaseImage('oneiric')
        base_image2 = provider.getBaseImage('precise')
        snapshot_image1 = base_image1.current_snapshot
        snapshot_image2 = base_image2.current_snapshot
        assert(len(provider.machines) == 0)
        assert(len(provider.ready_machines) == 0)
        assert(len(provider.building_machines) == 0)
        assert(len(base_image1.machines) == 0)
        assert(len(base_image1.ready_machines) == 0)
        assert(len(base_image1.building_machines) == 0)
        assert(len(base_image2.machines) == 0)
        assert(len(base_image2.ready_machines) == 0)
        assert(len(base_image2.building_machines) == 0)

        machine1 = base_image1.newMachine('%s-1331683760'%base_image1.name,
                                          '20000021', '1.2.3.4', 'uuid1')
        assert(len(provider.machines) == 1)
        assert(len(provider.ready_machines) == 0)
        assert(len(provider.building_machines) == 1)
        assert(len(base_image1.machines) == 1)
        assert(len(base_image1.ready_machines) == 0)
        assert(len(base_image1.building_machines) == 1)
        assert(len(base_image2.machines) == 0)
        assert(len(base_image2.ready_machines) == 0)
        assert(len(base_image2.building_machines) == 0)

        machine2 = base_image2.newMachine('%s-1331683761'%base_image1.name,
                                          '20000022', '1.2.3.5', 'uuid2')
        assert(len(provider.machines) == 2)
        assert(len(provider.ready_machines) == 0)
        assert(len(provider.building_machines) == 2)
        assert(len(base_image1.machines) == 1)
        assert(len(base_image1.ready_machines) == 0)
        assert(len(base_image1.building_machines) == 1)
        assert(len(base_image2.machines) == 1)
        assert(len(base_image2.ready_machines) == 0)
        assert(len(base_image2.building_machines) == 1)

        machine1.state = vmdatabase.READY
        assert(len(provider.machines) == 2)
        assert(len(provider.ready_machines) == 1)
        assert(len(provider.building_machines) == 1)
        assert(len(base_image1.machines) == 1)
        assert(len(base_image1.ready_machines) == 1)
        assert(len(base_image1.building_machines) == 0)
        assert(len(base_image2.machines) == 1)
        assert(len(base_image2.ready_machines) == 0)
        assert(len(base_image2.building_machines) == 1)

        machine2.state = vmdatabase.ERROR
        assert(len(provider.machines) == 2)
        assert(len(provider.ready_machines) == 1)
        assert(len(provider.building_machines) == 0)
        assert(len(base_image1.machines) == 1)
        assert(len(base_image1.ready_machines) == 1)
        assert(len(base_image1.building_machines) == 0)
        assert(len(base_image2.machines) == 1)
        assert(len(base_image2.ready_machines) == 0)
        assert(len(base_image2.building_machines) == 0)

        machine2.state = vmdatabase.READY
        assert(len(provider.machines) == 2)
        assert(len(provider.ready_machines) == 2)
        assert(len(provider.building_machines) == 0)
        assert(len(base_image1.machines) == 1)
        assert(len(base_image1.ready_machines) == 1)
        assert(len(base_image1.building_machines) == 0)
        assert(len(base_image2.machines) == 1)
        assert(len(base_image2.ready_machines) == 1)
        assert(len(base_image2.building_machines) == 0)

        hp_provider = self.db.getProvider('hpcloud')
        hp_base_image1 = hp_provider.getBaseImage('oneiric')
        hp_base_image2 = hp_provider.getBaseImage('precise')
        hp_snapshot_image1 = hp_base_image1.current_snapshot
        hp_snapshot_image2 = hp_base_image2.current_snapshot
        hp_machine1 = hp_base_image1.newMachine('%s-1331683551'%hp_base_image1.name,
                                                '21000021', '2.2.3.4', 'hpuuid1')
        hp_machine2 = hp_base_image2.newMachine('%s-1331683552'%hp_base_image2.name,
                                                '21000022', '2.2.3.5', 'hpuuid2')
        hp_machine1.state = vmdatabase.READY
        hp_machine2.state = vmdatabase.READY

        return (machine1, machine2, hp_machine1, hp_machine2)

    def test_get_machine(self):
        (machine1, machine2, hp_machine1, hp_machine2) = self.test_add_machine()
        # order should be rs1, hp1 for oneiric, hp2, rs1 for precise
        hp_machine2.state_time = machine1.state_time-60
        self.db.commit()

        self.db.print_state()

        rs_provider = self.db.getProvider('rackspace')
        hp_provider = self.db.getProvider('hpcloud')

        assert(len(rs_provider.ready_machines)==2)
        assert(len(hp_provider.ready_machines)==2)

        machine = self.db.getMachineForUse('oneiric')
        print 'got machine', machine.name
        assert(len(rs_provider.ready_machines)==1)
        assert(len(hp_provider.ready_machines)==2)
        assert(machine==machine1)

        machine = self.db.getMachineForUse('oneiric')
        print 'got machine', machine.name
        assert(len(rs_provider.ready_machines)==1)
        assert(len(hp_provider.ready_machines)==1)
        assert(machine==hp_machine1)

        machine = self.db.getMachineForUse('precise')
        print 'got machine', machine.name
        assert(len(rs_provider.ready_machines)==1)
        assert(len(hp_provider.ready_machines)==0)
        assert(machine==hp_machine2)

        machine = self.db.getMachineForUse('precise')
        print 'got machine', machine.name
        assert(len(rs_provider.ready_machines)==0)
        assert(len(hp_provider.ready_machines)==0)
        assert(machine==machine2)

