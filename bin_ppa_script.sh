#!/bin/sh

set -e

if [ -z "$PROJECT" ]
then
	echo '$PROJECT not set.'
	exit 1
fi

HUDSON=http://localhost:8080/
VERSIONDIR=$HOME/versions
PKGRECORDFILE=$VERSIONDIR/binpkgversions
JENKINS_TARBALL_JOB=${JENKINS_TARBALL_JOB:-$PROJECT-tarball}
BZR_BRANCH=${BZR_BRANCH:-lp:~openstack-ubuntu-packagers/$PROJECT/ubuntu}
PPAS=${PPAS:-ppa:$PROJECT-core/trunk}
PACKAGING_REVNO=${PACKAGING_REVNO:--1}

if [ ! -d "$VERSIONDIR" ]
then
        bzr co bzr://jenkins.openstack.org/ "$VERSIONDIR"
else
        ( cd $VERSIONDIR ; bzr up )
fi

# Clean up after previous build
rm -rf build dist.zip
mkdir build

# Grab the most recently built artifacts
wget $HUDSON/job/${JENKINS_TARBALL_JOB}/lastBuild/artifact/dist/*zip*/dist.zip

# Shove them in build/
unzip dist.zip -d build

cd build

tarball="$(echo dist/$PROJECT*.tar.gz)"
version="${tarball%.tar.gz}"
version="${version#*$PROJECT-}"
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
	pkgversion="${version}-0ubuntu0ppa1~${buildno}"
	if grep "$PROJECT $pkgversion" "$PKGRECORDFILE"
	then
		echo "We've already built a $pkgversion of $PROJECT. Incrementing build number."
		buildno=$(($buildno + 1))
	else
		echo "$PROJECT $pkgversion" >> "$PKGRECORDFILE"
		cat "$PKGRECORDFILE" | sort > "$PKGRECORDFILE"
		( cd $VERSIONDIR ;
		 bzr up ;
		 bzr commit -m"Added $PROJECT $snapshotversion" )
		break
	fi
done
# Doing this in here so that we have buildno
server_name=${PACKAGE}-`echo ${pkgversion} | sed 's/\~//g'`
echo "Launching a Cloud Server"
python ${HOME}/launch_node.py ${server_name}
cp node.sh ..
dch -b --force-distribution --v "${pkgversion}" "Automated PPA build. Packaging revision: ${PACKAGING_REVNO}." -D maverick
dpkg-buildpackage -rfakeroot -sa -k32EE128C
cd ..
