import sqlite3
import os
import time

# States:
# The cloud provider is building this machine.  We have an ID, but it's
# not ready for use.
BUILDING=1
# The machine is ready for use.
READY=2
# This can mean in-use, or used but complete.  We don't actually need to
# distinguish between those states -- we'll just delete a machine 24 hours 
# after it transitions into the USED state.
USED=3  
# An error state, should just try to delete it.
ERROR=4

# Columns:
# state: one of the above values
# state_time: the time of transition into that state
# user: set if the machine is given to a user
# id: identifier from cloud provider
# name: machine name
# ip: machine ip
# uuid: uuid from libcloud
# provider: libcloud driver for this server
# image: name of image this server is based on

class VMDatabase(object):
    def __init__(self, path=os.path.expanduser("~/vm.db")):
        # Set isolation_level = None, which means "autocommit" mode
        # but more importantly lets you manage transactions manually
        # without the isolation emulation getting in your way.
        # Most of our writes can be autocomitted, and the one(s)
        # that can't, we'll set up the transaction around the critical 
        # section.
        if not os.path.exists(path):
            conn = sqlite3.connect(path, isolation_level=None)
            conn.execute("""create table machines
                                   (provider text, id int, image text,
                                    name text, ip text, uuid text,
                                    state_time int, state int, user text)""")
            del conn
        self.conn = sqlite3.connect(path, isolation_level = None)
        # This turns the returned rows into objects that are like lists
        # and dicts at the same time:
        self.conn.row_factory = sqlite3.Row

    def addMachine(self, provider, mid, image, name, ip, uuid):
        self.conn.execute("""insert into machines 
                                 (provider, id, image, name, ip, 
                                  uuid, state_time, state) 
                             values (?, ?, ?, ?, ?, ?, ?, ?)""",
                          (provider, mid, image, name, ip, uuid,
                           int(time.time()), BUILDING))
          
    def delMachine(self, uuid):
        self.conn.execute("delete from machines where uuid=?", (uuid,))

    def setMachineUser(self, uuid, user):
        self.conn.execute("update machines set user=? where uuid=?", 
                          (user, uuid))

    def setMachineState(self, uuid, state):
        self.conn.execute("""update machines set state=?, state_time=? 
                             where uuid=?""",
                          (state, int(time.time()), uuid))

    def getMachines(self):
        return self.conn.execute("select * from machines order by state_time")

    def getMachine(self, uuid):
        for x in self.conn.execute("select * from machines where uuid=?",
                                   (uuid,)):
            return x

    def getMachineForUse(self):
        """Atomically find a machine that is ready for use, and update
        its state."""
        self.conn.execute("begin exclusive transaction")
        ret = None
        for m in self.getMachines():
            if m['state']==READY:
                self.setMachineState(m['uuid'], USED)
                ret = m
                break
        self.conn.execute("commit")
        return ret

if __name__=='__main__':
    db = VMDatabase("/tmp/vm.db")
    db.addMachine('rackspace', 1, 'devstack', 'foo', '1.2.3.4', 'uuid1')
    db.setMachineState('uuid1', READY)
    db.addMachine('rackspace', 2, 'devstack', 'foo2', '1.2.3.4', 'uuid2')
    db.setMachineState('uuid2', READY)
    m = db.getMachineForUse()
    print 'got machine'
    print m
    db.setMachineUser(m['uuid'], 'jeblair')
    print db.getMachines()
    print db.getMachine(1)
    print 'waiting to delete'
    time.sleep(2)
    db.delMachine('uuid1')
    db.delMachine('uuid2')

