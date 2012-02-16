#!/bin/sh

set -e

find_next_version() {
    datestamp="${datestamp:-$(date +%Y%m%d)}"
    index=1
    MILESTONEDIR="${MILESTONEDIR:-$HOME/versions/milestone}"
    BRANCH=${BRANCH:-trunk}

    milestonefile="${MILESTONEDIR}/${PROJECT}-${BRANCH}"

    if [ ! -e "${milestonefile}" ]
    then
        if [ "$NOMILESTONE" = "true" ]
        then
            milestonever=""
        else
            echo "Milestone file ${milestonefile} not found. Bailing out." >&2
            exit 1
        fi
    else
        milestonever="$(cat ${milestonefile})"
    fi

    version="$milestonever"
    if [ -n "$version" ]
    then
        version="${version}~"
    fi
    if [ -d .git ]
    then
        revno="${revno:-$(git log --oneline |  wc -l)}"
    else
        revno="${revno:-$(bzr revno)}"
    fi
    version="$(printf %s%s.%s%d "$version" "$datestamp" "$REVNOPREFIX" "$revno")"
    if grep -q "^$PROJECT $version$" "$RECORDFILE"
    then
        echo "$version of $PROJECT already exists. Bailing out." >&2
        exit 1
    fi

    printf "%s" "$version"
}
    
if [ "$1" = "test" ]
then
    PROJECT="testproj"
    datestamp="12345678"
    RECORDFILE=$(mktemp)
    MILESTONEDIR=$(mktemp -d)
    BRANCH=foo
    revno="99923"
    REVNOPREFIX="r"
    
    # Verify that we skip already built versions
    echo "d2" > "${MILESTONEDIR}/$PROJECT-${BRANCH}"
    echo "$PROJECT d2~$datestamp.001" > $RECORDFILE
    expected_version="d2~12345678.r99923"
    actual_version="$(find_next_version)"
    test "${actual_version}" = "${expected_version}" || (echo Got ${actual_version}, expected ${expected_version} ; exit 1)
    echo "For a milestoned project, we'd get: ${expected_version}"

    PROJECT="testproj2"
    NOMILESTONE=true
    expected_version="12345678.r99923"
    actual_version="$(find_next_version)"
    test "${actual_version}" = "${expected_version}" || (echo Got ${actual_version}, expected ${expected_version} ; exit 1)
    echo "For a non-milestoned project, we'd get: ${expected_version}"

    echo All tests passed
    exit 0
fi

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
	( cd $VERSIONDIR ; bzr up ; bzr revert)
fi


snapshotversion=$(find_next_version)


# Should be ~ if tarball version is the one we're working *toward*. (By far preferred!)
# Should be + if tarball version is already released and we're moving forward after it.
SEPARATOR=${SEPARATOR:-'~'}

rm -f dist/*.tar.gz
if [ -f setup.py ] ; then
    # swift has no virtualenv information in its tree.
    if [ -d .venv -o -f tools/with_venv.sh ] ; then
        tools/with_venv.sh python setup.py sdist
    else
        python setup.py sdist
    fi
    # There should only be one, so this should be safe.
    tarball=$(echo dist/*.tar.gz)

    echo mv "$tarball" "dist/$(basename $tarball .tar.gz)${SEPARATOR}${snapshotversion}.tar.gz"
    mv "$tarball" "dist/$(basename $tarball .tar.gz)${SEPARATOR}${snapshotversion}.tar.gz"
else
    # This handles the horizon case until we get it refactored
    upcoming_version=`cat ${VERSIONDIR}/upcoming_version`
    projectversion=${PROJECT}-${upcoming_version}${SEPARATOR}${snapshotversion}
    projectversion=${PROJECT}-${upcoming_version}
    mkdir ${projectversion}
    for f in * .??* ; do
        if [ "${f}" != "${projectversion}" ] ; then
            mv "$f" ${projectversion}
        fi
    done
    if [ -d ${projectversion}/.git ] ; then
        mv ${projectversion}/.git .
    fi
    mkdir dist
    tar cvfz dist/${projectversion}${SEPARATOR}${snapshotversion}.tar.gz ${projectversion}
fi

(cd $VERSIONDIR; bzr up)

echo "$PROJECT ${snapshotversion}" >> "$RECORDFILE"
sort "$RECORDFILE" > "$RECORDFILE".tmp
mv "$RECORDFILE".tmp "$RECORDFILE"

(cd $VERSIONDIR; bzr commit -m"Added $PROJECT ${snapshotversion}")
