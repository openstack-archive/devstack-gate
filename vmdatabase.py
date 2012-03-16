#!/usr/bin/env python

# Keep track of VMs used by the devstack gate test.

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

import sqlite3
import os
import time

# States:
# The cloud provider is building this machine.  We have an ID, but it's
# not ready for use.
BUILDING = 1
# The machine is ready for use.
READY = 2
# This can mean in-use, or used but complete.  We don't actually need to
# distinguish between those states -- we'll just delete a machine 24 hours
# after it transitions into the USED state.
USED = 3
# An error state, should just try to delete it.
ERROR = 4
# Keep this machine indefinitely
HOLD = 5

from sqlalchemy import Table, Column, Boolean, Integer, String, MetaData, ForeignKey, UniqueConstraint, Index, create_engine, and_, or_
from sqlalchemy.orm import mapper, relation
from sqlalchemy.orm.session import Session, sessionmaker

metadata = MetaData()
provider_table = Table('provider', metadata,
    Column('id', Integer, primary_key=True),
    Column('name', String(255), index=True, unique=True),
    Column('max_servers', Integer),      # Max total number of servers for this provider
    Column('giftable', Boolean),         # May we give failed vms from this provider to developers?
    Column('nova_api_version', String(8)),       # 1.0 or 1.1
    Column('nova_rax_auth', Boolean),            # novaclient doesn't discover this itself
    Column('nova_username', String(255)),
    Column('nova_api_key', String(255)),
    Column('nova_auth_url', String(255)),        # Authentication URL
    Column('nova_project_id', String(255)),      # Project id to use at authn
    Column('nova_service_type', String(255)),    # endpoint selection: service type (Null for default)
    Column('nova_service_region', String(255)),  # endpoint selection: service region (Null for default)
    Column('nova_service_name', String(255)),    # endpoint selection: Endpoint name (Null for default)
    )
base_image_table = Table('base_image', metadata,
    Column('id', Integer, primary_key=True),
    Column('provider_id', Integer, ForeignKey('provider.id'), index=True, nullable=False),
    Column('name', String(255)),         # Image name (oneiric, precise, etc).
    Column('external_id', String(255)),  # Provider assigned id for this image
    Column('min_ready', Integer),        # Min number of servers to keep ready for this provider/image
    Column('min_ram', Integer),          # amount of ram to select for servers with this image
    #active?
    )
snapshot_image_table = Table('snapshot_image', metadata,
    Column('id', Integer, primary_key=True),
    Column('name', String(255)),
    Column('base_image_id', Integer, ForeignKey('base_image.id'), index=True, nullable=False),
    Column('version', Integer),          # Version indicator (timestamp)
    Column('external_id', String(255)),  # Provider assigned id for this image
    Column('server_external_id', String(255)),  # Provider assigned id of the server used to create the snapshot
    Column('state', Integer),            # One of the above values
    Column('state_time', Integer),       # Time of last state change
    )
machine_table = Table('machine', metadata,
    Column('id', Integer, primary_key=True),
    Column('base_image_id', Integer, ForeignKey('base_image.id'), index=True, nullable=False),
    Column('external_id', String(255)),  # Provider assigned id for this machine
    Column('name', String(255)),         # Machine name
    Column('ip', String(255)),           # Primary IP address
    Column('user', String(255)),         # Username if ssh keys have been installed, or NULL
    Column('state', Integer),            # One of the above values
    Column('state_time', Integer),       # Time of last state change
    )


class Provider(object):
    def __init__(self, name, driver, username, api_key, giftable):
        self.name = name
        self.driver = driver
        self.username = username
        self.api_key = api_key
        self.giftable = giftable

    def delete(self):
        session = Session.object_session(self)
        session.delete(self)
        session.commit()

    def newBaseImage(self, *args, **kwargs):
        new = BaseImage(*args, **kwargs)
        new.provider = self
        session = Session.object_session(self)
        session.commit()
        return new

    def getBaseImage(self, name):
        session = Session.object_session(self)
        return session.query(BaseImage).filter(and_(
                base_image_table.c.name == name,
                base_image_table.c.provider_id == self.id)).first()

    def _machines(self):
        session = Session.object_session(self)
        return session.query(Machine).filter(and_(
                machine_table.c.base_image_id == base_image_table.c.id,
                base_image_table.c.provider_id == self.id)).order_by(
            machine_table.c.state_time)

    @property
    def machines(self):
        return self._machines().all()

    @property
    def building_machines(self):
        return self._machines().filter(machine_table.c.state == BUILDING).all()

    @property
    def ready_machines(self):
        return self._machines().filter(machine_table.c.state == READY).all()


class BaseImage(object):
    def __init__(self, name, external_id):
        self.name = name
        self.external_id = external_id

    def delete(self):
        session = Session.object_session(self)
        session.delete(self)
        session.commit()

    def newSnapshotImage(self, *args, **kwargs):
        new = SnapshotImage(*args, **kwargs)
        new.base_image = self
        session = Session.object_session(self)
        session.commit()
        return new

    def newMachine(self, *args, **kwargs):
        new = Machine(*args, **kwargs)
        new.base_image = self
        session = Session.object_session(self)
        session.commit()
        return new

    @property
    def ready_snapshot_images(self):
        session = Session.object_session(self)
        return session.query(SnapshotImage).filter(and_(
                snapshot_image_table.c.base_image_id == self.id,
                snapshot_image_table.c.state == READY)).order_by(
            snapshot_image_table.c.version).all()

    @property
    def current_snapshot(self):
        if not self.ready_snapshot_images:
            return None
        return self.ready_snapshot_images[-1]

    def _machines(self):
        session = Session.object_session(self)
        return session.query(Machine).filter(
            machine_table.c.base_image_id == self.id).order_by(
            machine_table.c.state_time)

    @property
    def building_machines(self):
        return self._machines().filter(machine_table.c.state == BUILDING).all()

    @property
    def ready_machines(self):
        return self._machines().filter(machine_table.c.state == READY).all()


class SnapshotImage(object):
    def __init__(self, name, version, external_id, server_external_id, state=BUILDING):
        self.name = name
        self.version = version
        self.external_id = external_id
        self.server_external_id = server_external_id
        self.state = state

    def delete(self):
        session = Session.object_session(self)
        session.delete(self)
        session.commit()

    @property
    def state(self):
        return self._state

    @state.setter
    def state(self, state):
        self._state = state
        self.state_time = int(time.time())
        session = Session.object_session(self)
        if session:
            session.commit()


class Machine(object):
    def __init__(self, name, external_id, ip=None, user=None, state=BUILDING):
        self.name = name
        self.external_id = external_id
        self.ip = ip
        self.user = user
        self.state = state

    def delete(self):
        session = Session.object_session(self)
        session.delete(self)
        session.commit()

    @property
    def state(self):
        return self._state

    @state.setter
    def state(self, state):
        self._state = state
        self.state_time = int(time.time())
        session = Session.object_session(self)
        if session:
            session.commit()


mapper(Machine, machine_table, properties=dict(
        _state=machine_table.c.state,
        ))

mapper(SnapshotImage, snapshot_image_table, properties=dict(
        _state=snapshot_image_table.c.state,
        ))

mapper(BaseImage, base_image_table, properties=dict(
        snapshot_images=relation(SnapshotImage,
                                 order_by=snapshot_image_table.c.version,
                                 cascade='all, delete-orphan',
                                 backref='base_image'),
        machines=relation(Machine,
                          order_by=machine_table.c.state_time,
                          cascade='all, delete-orphan',
                          backref='base_image')))

mapper(Provider, provider_table, properties=dict(
        base_images=relation(BaseImage,
                             order_by=base_image_table.c.name,
                             cascade='all, delete-orphan',
                             backref='provider')))


class VMDatabase(object):
    def __init__(self, path=os.path.expanduser("~/vm.db")):
        engine = create_engine('sqlite:///%s' % path, echo=False)
        metadata.create_all(engine)
        Session = sessionmaker(bind=engine, autoflush=True, autocommit=False)
        self.session = Session()

    def print_state(self):
        for provider in self.getProviders():
            print 'Provider:', provider.name
            for base_image in provider.base_images:
                print '  Base image:', base_image.name
                for snapshot_image in base_image.snapshot_images:
                    print '    Snapshot:', snapshot_image.name, snapshot_image.state
                for machine in base_image.machines:
                    print '    Machine:', machine.id, machine.name, machine.state, machine.state_time, machine.ip

    def abort(self):
        self.session.rollback()

    def commit(self):
        self.session.commit()

    def delete(self, obj):
        self.session.delete(obj)

    def getProviders(self):
        return self.session.query(Provider).all()

    def getProvider(self, name):
        return self.session.query(Provider).filter_by(name=name)[0]

    def getMachine(self, id):
        return self.session.query(Machine).filter_by(id=id)[0]

    def getMachineForUse(self, image_name):
        """Atomically find a machine that is ready for use, and update
        its state."""
        image = None
        for machine in self.session.query(Machine).filter(
            machine_table.c.state == READY).order_by(
            machine_table.c.state_time):
            if machine.base_image.name == image_name:
                machine.state = USED
                self.commit()
                return machine
        raise Exception("No machine found for image %s" % image_name)


if __name__ == '__main__':
    db = VMDatabase()
    db.print_state()
