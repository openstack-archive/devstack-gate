from xml.sax.saxutils import escape
from contextlib import closing
import codecs
import simplejson
import urllib2
import os
import sys
import time

if len(sys.argv) != 3:
    print "A team/user and a project/repo are required arguments"
    sys.exit(1)

team = sys.argv[1]
project = sys.argv[2]


def fix_bad_time(bad_time):
    # This is stupid, but time.strptime doesn't support %z in 2.6
    #return "%s-%s-%sT%sZ%s:%s" % (bad_time[:4], bad_time[5:7], bad_time[8:10],
    #    bad_time[11:19], bad_time[20:23], bad_time[23:])
    return "%s-%s-%sT%sZ" % (bad_time[:4], bad_time[5:7], bad_time[8:10],
        bad_time[11:19])

# TODO: Fetch the files from the internets
issues = []

for issue_state in ("open", "closed"):
    full_url = "http://github.com/api/v2/json/issues/list/%s/%s/%s" % (team,
        project, issue_state)
    with closing(urllib2.urlopen(full_url)) as issue_json:
        these_issues = simplejson.load(issue_json)
        issues.extend(these_issues['issues'])

users = {}
with open("gh_to_lp_users.json", "r") as users_json:
    users = simplejson.load(users_json)

outfile_name = "%s_%s_lp_bugs.xml" % (team, project)
bugs_outfile = codecs.open(outfile_name, "w", "utf-8-sig")
bugs_outfile.write("""<?xml version="1.0"?>
<launchpad-bugs xmlns="https://launchpad.net/xmlns/2006/bugs">
""")

for issue in issues:
    issue['body'] = escape(issue['body'])
    issue['title'] = escape(issue['title'])
    issue['lower_user'] = users.get(issue['user'], issue['user'].lower())

    if issue['state'] == "open":
        issue['status'] = "CONFIRMED"
    else:
        issue['status'] = "FIXRELEASED"
    for bad_time in ('updated_at', 'created_at'):
        issue[bad_time] = fix_bad_time(issue[bad_time])

    bugs_outfile.write("""
<bug xmlns="https://launchpad.net/xmlns/2006/bugs" id="%(number)s">
  <datecreated>%(created_at)s</datecreated>
  <title>%(title)s</title>

  <description>%(body)s</description>
  <reporter name="%(lower_user)s" email="noreply@openstack.org">%(user)s</reporter>
  <status>%(status)s</status>
  <importance>HIGH</importance>

  """ % issue)

    if len(issue['labels']) > 0:
        bugs_outfile.write("<tags>\n")
        for label in issue['labels']:
            bugs_outfile.write("<tag>%s</tag>\n" % label.lower())
        bugs_outfile.write("</tags>\n")

    bugs_outfile.write("""
  <comment>
    <sender name="%(lower_user)s" email="noreply@openstack.org">%(user)s</sender>
    <date>%(created_at)s</date>
    <title>%(title)s</title>
    <text>%(body)s</text>
  </comment>
    """ % issue)
    issue['comments'] = []
    full_url = "http://github.com/api/v2/json/issues/comments/%s/%s/%s" % \
        (team, project, issue['number'])
    # github ratelimits v2 api to 60 calls per minute
    time.sleep(1)
    print full_url
    with closing(urllib2.urlopen(full_url)) as comments_json:
        try:
            comments = simplejson.load(comments_json)
            issue['comments'] = comments['comments']
        except:
            issue['comments'] = []
    for comment in issue['comments']:
        for bad_time in ('updated_at', 'created_at'):
            comment[bad_time] = fix_bad_time(comment[bad_time])
        comment['body'] = escape(comment['body'])
        comment['lower_user'] = users.get(comment['user'],
                                          comment['user'].lower())
        try:
            bugs_outfile.write("""
  <comment>
    <sender name="%(lower_user)s" email="noreply@openstack.org">%(user)s</sender>
    <date>%(created_at)s</date>
    <text>%(body)s</text>
  </comment>""" % comment)
        except:
            print comment
            sys.exit(1)
    bugs_outfile.write("\n</bug>\n")

bugs_outfile.write("\n</launchpad-bugs>\n")
bugs_outfile.close()

os.system("rnv bug-export.rnc %s" % outfile_name)
