#!/usr/bin/env python

# Tail a syslog file printing each line while looking for indications
# that puppet has completed its initial run on each host.
# Once puppet is finished, wait 30 seconds (for any further interesting
# log entries), then exit.

import re
import time
import sys

HOSTS = set(['baremetal%02i'%(x+1) for x in range(4)])
LOGFILE = "/var/log/deploy.log"
COMPLETE_RE = re.compile(r'^\w+ \w+ \d\d:\d\d:\d\d (\w+) puppet-agent\[\d+\]: Finished catalog run in \S+ seconds$')
EXIT_DELAY = 30

logf = open(LOGFILE)
completed_hosts = set()
exit_time = None
         
while True:
    now = time.time()
    if exit_time and exit_time < now:
        sys.exit(0)

    where = logf.tell()
    line = logf.readline()
    if not line:
        time.sleep(1)
        logf.seek(where)
        continue

    sys.stdout.write(line)
    sys.stdout.flush()
    m = COMPLETE_RE.match(line)
    if m:
        completed_hosts |= set([m.group(1)])
        if completed_hosts == HOSTS:
            exit_time = time.time() + EXIT_DELAY
