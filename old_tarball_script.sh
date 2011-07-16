#!/bin/sh

set -e

if [ -z "$PROJECT" ]
then
	echo '$PROJECT not set.'
	exit 1
fi

VERSIONDIR="$HOME/versions"
RECORDFILE="$VERSIONDIR/tarballversions"

if [ ! -d "$VERSIONDIR" ]
then
	bzr co bzr://jenkins.openstack.org/ "$VERSIONDIR"
else
	( cd $VERSIONDIR ; bzr up )
fi

SEPARATOR=${SEPARATOR:-'~'}
revno=$(bzr revno)
datestamp="$(date +%Y%m%d)"

if grep "^$PROJECT $revno$" "$RECORDFILE";
then
	echo "Tarball already built. Not rebuilding."
	exit 0
fi
echo "$PROJECT $revno" '>>' "$RECORDFILE"
cat "$RECORDFILE" | sort > "$RECORDFILE"
( cd $VERSIONDIR ; bzr up ;  bzr commit -m"Added $PROJECT $snapshotversion" )

python setup.py sdist
tarball=$(echo dist/*.tar.gz)
mv "$tarball" "dist/$(basename $tarball .tar.gz)${SEPARATOR}bzr${revno}.tar.gz"
