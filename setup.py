import os
import sys
import setuptools


setuptools.setup(
    name="devstack-gate",
    version="2012.2",
    description="Devstack gate scripts used by Openstack CI team for testing longest line in this screen",
    url='https://github.com/openstack-ci/devstack-gate',
    license='Apache',
    author='Openstack CI team',
    author_email='openstack@lists.launchpad.net',
    packages=setuptools.find_packages(exclude=['tests', 'tests.*']),
    classifiers=[
        'Development Status :: 4 - Beta',
        'Environment :: Console',
        'Intended Audience :: Developers',
        'Intended Audience :: Information Technology',
        'License :: OSI Approved :: Apache Software License',
        'Operating System :: OS Independent',
        'Programming Language :: Python',
    ],
    test_suite="nose.collector",
)
