import sqlite3
import os
import time

class VMDatabase(object):
    def __init__(self, path=os.path.expanduser("~/vm.db")):
        if not os.path.exists(path):
            conn = sqlite3.connect(path)
            c = conn.cursor()
            c.execute('''create table machines
(id int, name text, ip text, change_number, patch_number, build_number, created int, user text)''')
            conn.commit()
            c.close()
        self.conn = sqlite3.connect(path)

    def addMachine(self, mid, name, ip, change, patch, build):
        c = self.conn.cursor()
        c.execute("insert into machines (id, name, ip, change_number, patch_number, build_number, created) values (?, ?, ?, ?, ?, ?, ?)",
                  (mid, name, ip, change, patch, build, int(time.time())))
        self.conn.commit()
        c.close()
          
    def delMachine(self, mid):
        c = self.conn.cursor()
        c.execute("delete from machines where id=?", (mid,))
        self.conn.commit()
        c.close()

    def setMachineUser(self, mid, user):
        c = self.conn.cursor()
        c.execute("update machines set user=? where id=?", (user, mid))
        self.conn.commit()
        c.close()

    def getMachines(self):
        c = self.conn.cursor()
        c.execute("select * from machines")
        names = [col[0] for col in c.description]
        data = [dict(zip(names, row)) for row in c]
        c.close()
        return data

    def getMachine(self, change, patch, build):
        c = self.conn.cursor()
        c.execute("select * from machines where change_number=? and patch_number=? and build_number=?", (change, patch, build))
        names = [col[0] for col in c.description]
        data = [row for row in c]
        c.close()
        return dict(zip(names, data[0]))

if __name__=='__main__':
    db = VMDatabase()
    db.addMachine(1, 'foo', '1.2.3.4', 88, 2, 1)
    db.setMachineUser(1, 'jeblair')
    print db.getMachines()
    print db.getMachine(88,2,1)
    db.delMachine(1)
