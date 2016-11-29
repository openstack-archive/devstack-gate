# (c) 2012-2014, Michael DeHaan <michael.dehaan@gmail.com>
#
# This file is part of Ansible
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# Make coding more python3-ish
from __future__ import absolute_import
from __future__ import division
from __future__ import print_function

from ansible import constants as C
from ansible.plugins.callback import CallbackBase
from ansible.vars import strip_internal_keys

import datetime
import yaml


def _get_timestamp():
    return str(datetime.datetime.now())[:-3]


class CallbackModule(CallbackBase):

    '''Callback plugin for devstack-gate.

    Based on the minimal callback plugin from the ansible tree. Adds
    timestamps to the start of the lines, squishes responses that are only
    messages, returns facts in yaml not json format and strips facter facts
    from the reported facts.
    '''

    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'devstack'

    def _command_generic_msg(self, host, result, task, caption):
        '''output the result of a command run'''

        if caption == 'SUCCESS':
            buf = "%s | %s | %s | %s >>\n" % (
                _get_timestamp(), host, caption, task.get_name().strip())
        else:
            buf = "%s | %s | %s | %s | rc=%s >>\n" % (
                _get_timestamp(), host, caption, task.get_name().strip(),
                result.get('rc', 0))
        buf += result.get('stdout', '')
        buf += result.get('stderr', '')
        buf += result.get('msg', '')

        return buf + "\n"

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if 'exception' in result._result:
            self._display.display(
                "An exception occurred during task execution."
                " The full traceback is:\n" + result._result['exception'])

        if result._task.action in C.MODULE_NO_JSON:
            self._display.display(
                self._command_generic_msg(
                    result._host.get_name(), result._result, result._task,
                    "FAILED"))
        else:
            self._display.display(
                "%s | %s | FAILED! => %s" % (
                    _get_timestamp(),
                    result._host.get_name(), self._dump_results(
                        result._result, indent=4)))

    def v2_runner_on_ok(self, result):
        self._clean_results(result._result, result._task.action)
        if 'ansible_facts' in result._result:
            return
        elif 'hostvars[inventory_hostname]' in result._result:
            facts = result._result['hostvars[inventory_hostname]']
            facter_keys = [k for k in facts.keys() if k.startswith('facter_')]
            for key in facter_keys:
                del facts[key]
            result._result['ansible_facts'] = facts
            self._display.display(
                "%s | %s | Gathered facts:\n%s" % (
                    _get_timestamp(),
                    result._host.get_name(),
                    yaml.safe_dump(facts, default_flow_style=False)))
            return

        if result._task.action in C.MODULE_NO_JSON:
            self._display.display(
                self._command_generic_msg(
                    result._host.get_name(), result._result, result._task,
                    "SUCCESS"))
        else:
            if 'changed' in result._result and result._result['changed']:
                self._display.display(
                    "%s | %s | SUCCESS => %s" % (
                        _get_timestamp(),
                        result._host.get_name(), self._dump_results(
                            result._result, indent=4)))
            else:
                abriged_result = strip_internal_keys(result._result)
                if 'msg' in abriged_result and len(abriged_result.keys()) == 1:
                    result_text = result._result['msg']
                else:
                    result_text = self._dump_results(result._result, indent=4)

                self._display.display(
                    "%s | %s | %s | %s" % (
                        _get_timestamp(),
                        result._host.get_name(),
                        result._task.get_name().strip(),
                        result_text))
            self._handle_warnings(result._result)

    def v2_runner_on_skipped(self, result):
        self._display.display(
            "%s | %s | SKIPPED" % (
                _get_timestamp(), result._host.get_name()))

    def v2_runner_on_unreachable(self, result):
        self._display.display(
            "%s | %s | UNREACHABLE! => %s" % (
                _get_timestamp(),
                result._host.get_name(), self._dump_results(
                    result._result, indent=4)))

    def v2_on_file_diff(self, result):
        if 'diff' in result._result and result._result['diff']:
            self._display.display(self._get_diff(result._result['diff']))
