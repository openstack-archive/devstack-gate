#!/bin/bash

set -e

# This script assumes it's being run inside of a checkout of the packaging
# for a project
PROJECT=`grep Source: debian/control | awk '{print $2}'`
VERSIONDIR=$HOME/versions
PKGRECORDFILE=$VERSIONDIR/pkgversions
PPAS=${PPAS:-ppa:$PROJECT-core/trunk}
PACKAGING_REVNO=${PACKAGING_REVNO:--1}
series=${series:-lucid}

if [ ! -d "$VERSIONDIR" ]
then
        bzr co bzr://jenkins.openstack.org/ "$VERSIONDIR"
else
        ( cd $VERSIONDIR ; bzr up )
fi

tarball="$(echo $PROJECT*.tar.gz)"
version="${tarball%.tar.gz}"
version="${version#*$PROJECT-}"
base_version=$version
if [ -n "${EXTRAVERSION}" ]
then
    version="${version%~*}${EXTRAVERSION}~${version#*~}"
fi

if [ -d .git ]
then
    PACKAGING_REVNO="$(git log --oneline | wc -l)"
else
    PACKAGING_REVNO="$(bzr revno --tree)"
fi

buildno=1
while true
do
	pkgversion="${version}-0ubuntu0ppa1~${series}${buildno}"
	if grep "$PROJECT $pkgversion" "$PKGRECORDFILE"
	then
		echo "We've already built a $pkgversion of $PROJECT. Incrementing build number."
		buildno=$(($buildno + 1))
	else
		echo "$PROJECT $pkgversion" >> "$PKGRECORDFILE"
		sort "$PKGRECORDFILE" > "$PKGRECORDFILE".tmp
                mv "$PKGRECORDFILE".tmp "$PKGRECORDFILE"
		( cd $VERSIONDIR ;
		 bzr up ;
		 bzr commit -m"Added $PROJECT $snapshotversion" )
		break
	fi
done
dch -b --force-distribution --v "${pkgversion}" "Automated PPA build. Packaging revision: ${PACKAGING_REVNO}." -D $series
debcommit
bzr bd -S --builder='debuild -S -sa -rfakeroot' --build-dir=build
if ! [ "$DO_UPLOAD" = "no" ]
then
	for ppa in $PPAS
	do
		dput --force $ppa "../${PROJECT}_${pkgversion}_source.changes"
	done
fi
