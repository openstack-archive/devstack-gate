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


def calc_services(branch, features, configs, role):
    LOG.debug('Role: %s', role)
    services = set()
    for feature in features:
        grid_feature = GRID[role][feature]
        add_services = grid_feature['base'].get('services', [])
        if add_services:
            LOG.debug('Adding services for feature %s: %s',
                      feature, add_services)
            services.update(add_services)
        if branch in grid_feature:
            update_services = grid_feature[branch].get('services', [])
            if update_services:
                LOG.debug('Updating branch: %s specific services for '
                          'feature %s: %s', branch, feature, update_services)
                services.update(update_services)

    # deletes always trump adds
    for feature in features:
        grid_feature = GRID[role][feature]
        rm_services = grid_feature['base'].get('rm-services', [])
        if rm_services:
            LOG.debug('Removing services for feature %s: %s',
                      feature, rm_services)
            services.difference_update(rm_services)
        if branch in grid_feature:
            services.difference_update(
                grid_feature[branch].get('rm-services', []))

    # Finally, calculate any services to add/remove per config.
    # TODO(mriedem): This is not role-based so any per-config service
    # modifications are dealt with globally across all nodes.
    # do all the adds first
    for config in configs:
        if config in GRID['config']:
            add_services = GRID['config'][config].get('services', [])
            if add_services:
                LOG.debug('Adding services for config %s: %s',
                          config, add_services)
                services.update(add_services)

    # deletes always trump adds
    for config in configs:
        if config in GRID['config']:
            rm_services = GRID['config'][config].get('rm-services', [])
            if rm_services:
                LOG.debug('Removing services for config %s: %s',
                          config, rm_services)
                services.difference_update(rm_services)

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
            add_features = GRID['config'][config].get('features', [])
            if add_features:
                LOG.debug('Adding features for config %s: %s',
                          config, add_features)
                features.update(add_features)

    # removes always trump
    for config in configs:
        if config in GRID['config']:
            rm_features = GRID['config'][config].get('rm-features', [])
            if rm_features:
                LOG.debug('Removing features for config %s: %s',
                          config, rm_features)
                features.difference_update(rm_features)
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
    parser.add_argument('-v', '--verbose',
                        default=False, action='store_true',
                        help='Log verbose output')
    parser.set_defaults(ansible=True)
    return parser.parse_args()


def main():
    global GRID
    global ALLOWED_BRANCHES
    opts = get_opts()
    if opts.verbose:
        LOG.setLevel(logging.DEBUG)
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

    services = calc_services(branch, features, configs, role)
    LOG.debug("Services: %s " % services)

    if opts.ansible:
        ansible_module.exit_json(changed=True, services=services)
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
