#!/bin/sh

set -e

if [ -z "$PROJECT" ]
then
	echo '$PROJECT not set.'
	exit 1
fi

RECORDFILE=$HOME/tarballversions
SEPARATOR=${SEPARATOR:-'~'}
revno=$(bzr revno)
datestamp="$(date +%Y%m%d)"

if grep "^$PROJECT $revno$" "$RECORDFILE";
then
	echo "Tarball already built. Not rebuilding."
	exit 0
fi
echo "$PROJECT $revno" '>>' "$RECORDFILE"

python setup.py sdist
tarball=$(echo dist/*.tar.gz)
mv "$tarball" "dist/$(basename $tarball .tar.gz)${SEPARATOR}bzr${revno}.tar.gz"
