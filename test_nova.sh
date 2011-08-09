#!/bin/sh

bash run_tests.sh -N && python setup.py sdist && pep8 --repeat nova
