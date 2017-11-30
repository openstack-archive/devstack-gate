#!/usr/bin/env python

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

import argparse
import logging
import os
import sys
import yaml

GRID = None
ALLOWED_BRANCHES = []
FALSE_VALUES = [None, '', '0', 'false', 'False', 'FALSE']

FORMAT = '%(asctime)s %(levelname)s: %(message)s'
logging.basicConfig(format=FORMAT)
LOG = logging.getLogger(__name__)


def parse_features(fname):
    with open(fname) as f:
        return yaml.load(f)


def normalize_branch(branch):
    if branch.startswith(("feature/", "bug/")):
        # Feature and bug branches chase master and should be tested
        # as if they were the master branch.
        branch = GRID['branches']['default']
    elif branch.startswith("stable/"):
        branch = branch[len("stable/"):]
    elif branch.startswith("proposed/"):
        branch = branch[len("proposed/"):]
        for allowed in GRID['branches']['allowed']:
            # If the branch name starts with one of our known
            # named integrated release names treat that branch
            # as belonging to the integrated release. This means
            # proposed/foo* will be treated as the foo release.
            if branch.startswith(allowed):
                branch = allowed
                break
        else:
            # Releases that are not named integreated releases
            # should be tested as if they were the master branch
            # as they occur between integrated releases when other
            # projects are developing master.
            branch = GRID['branches']['default']
    if branch not in ALLOWED_BRANCHES:
        LOG.error("branch not allowed by features matrix: %s" % branch)
        sys.exit(1)
    return branch


def configs_from_env():
    configs = []
    for k, v in os.environ.items():
        if k.startswith('DEVSTACK_GATE_'):
            if v not in FALSE_VALUES:
                f = k.split('DEVSTACK_GATE_')[1]
                configs.append(f.lower())
    return configs


def calc_services(branch, features, role):
    services = set()
    for feature in features:
        grid_feature = GRID[role][feature]
        services.update(grid_feature['base'].get('services', []))
        if branch in grid_feature:
            services.update(
                grid_feature[branch].get('services', []))

    # deletes always trump adds
    for feature in features:
        grid_feature = GRID[role][feature]
        services.difference_update(
            grid_feature['base'].get('rm-services', []))

        if branch in grid_feature:
            services.difference_update(
                grid_feature[branch].get('rm-services', []))
    return sorted(list(services))


def calc_features(branch, configs=[]):
    LOG.debug("Branch: %s" % branch)
    LOG.debug("Configs: %s" % configs)
    if os.environ.get('DEVSTACK_GATE_NO_SERVICES') not in FALSE_VALUES:
        features = set(GRID['config']['default']['no_services'])
    else:
        features = set(GRID['config']['default'][branch])
    # do all the adds first
    for config in configs:
        if config in GRID['config']:
            features.update(GRID['config'][config].get('features', []))

    # removes always trump
    for config in configs:
        if config in GRID['config']:
            features.difference_update(
                GRID['config'][config].get('rm-features', []))
    return sorted(list(features))


def get_opts():
    usage = """
Compute the test matrix for devstack gate jobs from a combination
of environmental feature definitions and flags.
"""
    parser = argparse.ArgumentParser(description=usage)
    parser.add_argument('-f', '--features',
                        default='roles/test-matrix/files/features.yaml',
                        help="Yaml file describing the features matrix")
    parser.add_argument('-b', '--branch',
                        default="master",
                        help="Branch to compute the matrix for")
    parser.add_argument('-m', '--mode',
                        default="services",
                        help="What to return (services, compute-ext)")
    parser.add_argument('-r', '--role',
                        default='primary',
                        help="What role this node will have",
                        choices=['primary', 'subnode'])
    parser.add_argument('-a', '--ansible',
                        dest='ansible',
                        help="Behave as an Ansible Module",
                        action='store_true')
    parser.add_argument('-n', '--not-ansible',
                        dest='ansible',
                        help="Behave as python CLI",
                        action='store_false')
    parser.set_defaults(ansible=True)
    return parser.parse_args()


def main():
    global GRID
    global ALLOWED_BRANCHES
    opts = get_opts()
    if opts.ansible:
        ansible_module = get_ansible_module()
        features = ansible_module.params['features']
        branch = ansible_module.params['branch']
        role = ansible_module.params['role']
        configs = ansible_module.params['configs']
    else:
        features = opts.features
        branch = opts.branch
        role = opts.role
        configs = configs_from_env()

    GRID = parse_features(features)
    ALLOWED_BRANCHES = GRID['branches']['allowed']
    branch = normalize_branch(branch)

    features = calc_features(branch, configs)
    LOG.debug("Features: %s " % features)

    services = calc_services(branch, features, role)
    LOG.debug("Services: %s " % services)

    if opts.ansible:
        ansible_module.exit_json(changed='True', services=services)
    else:
        if opts.mode == "services":
            print(",".join(services))


def get_ansible_module():

    from ansible.module_utils.basic import AnsibleModule

    return AnsibleModule(
        argument_spec=dict(
            features=dict(type='str'),
            branch=dict(type='str'),
            role=dict(type='str'),
            configs=dict(type='list')
        )
    )


if __name__ == "__main__":
    sys.exit(main())
