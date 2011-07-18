#!/bin/sh
# This needs to always run on the Jenkins master because it does signing and
# uploading, which would be monstrously difficult (at this point) to do on a 
# slave. At some point, perhaps we can get key management done differently
# and rework this - but for now it's not really a burden to have this stuff
# on the master (you don't need build depends to make a source package)

set -e

if [ -z "$PROJECT" ]
then
	echo '$PROJECT not set.'
	exit 1
fi

HUDSON=http://localhost:8080/
VERSIONDIR=$HOME/versions
PKGRECORDFILE=$VERSIONDIR/pkgversions
BZR_BRANCH=${BZR_BRANCH:-lp:~openstack-ubuntu-packagers/$PROJECT/ubuntu}
PPAS=${PPAS:-ppa:$PROJECT-core/trunk}
PACKAGING_REVNO=${PACKAGING_REVNO:--1}
series=${series:-lucid}

if [ ! -d "$VERSIONDIR" ]
then
        bzr co bzr://jenkins.openstack.org/ "$VERSIONDIR"
else
        ( cd $VERSIONDIR ; bzr up )
fi

cd build

tarball="$(echo dist/$PROJECT*.tar.gz)"
version="${tarball%.tar.gz}"
version="${version#*$PROJECT-}"
base_version=$version
if [ -n "${EXTRAVERSION}" ]
then
    version="${version%~*}${EXTRAVERSION}~${version#*~}"
fi
tar xvzf "${tarball}"
echo ln -s "${tarball}" "${PROJECT}_${version}.orig.tar.gz"
ln -s "${tarball}" "${PROJECT}_${version}.orig.tar.gz"

# Overlay packaging
# (Intentionally using the natty branch. For these PPA builds, we don't need to diverge
# (yet, at least), so it makes the branch management easier this way.
# Note: Doing a checkout and deleting .bzr afterwards instead of just doing an export,
# because export refuses to overlay over an existing directory, so this was easier.
# (We need to not have the .bzr in there, otherwise vcsversion.py might get overwritten)
echo bzr checkout -r ${PACKAGING_REVNO} --lightweight $BZR_BRANCH $PROJECT-*
bzr checkout -r ${PACKAGING_REVNO} --lightweight $BZR_BRANCH $PROJECT-*
cd $PROJECT-*
PACKAGING_REVNO="$(bzr revno --tree)"
rm -rf .bzr

# Please don't change this. It's the only way I'll get notified
# if an upload fails.
export DEBFULLNAME="Soren Hansen"
export DEBEMAIL="soren@openstack.org"

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
		break
	fi
done
dch -b --force-distribution --v "${pkgversion}" "Automated PPA build. Packaging revision: ${PACKAGING_REVNO}." -D $series
dpkg-buildpackage -rfakeroot -S -sa -k32EE128C
if ! [ "$DO_UPLOAD" = "no" ]
then
	for ppa in $PPAS
	do
		dput --force $ppa "../${PROJECT}_${pkgversion}_source.changes"
	done
fi
cd ..
