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

    if false  # Because we only need this madness if we're using git, that's why!
    then
        while true
        do
            version="$milestonever"
            if [ -n "$version" ]
            then
                version="${version}~"
            fi
            version="$(printf %s%s.%s%d "${version}" "$datestamp" "$REVNOPREFIX" "$index")"
            if grep -q "^$PROJECT $version$" "$RECORDFILE"
            then
                echo "$version of $PROJECT already exists. Bumping index." >&2
                index="$(($index + 1))"
            else
                break
            fi
        done
    else
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
	( cd $VERSIONDIR ; bzr up )
fi


snapshotversion=$(find_next_version)


# Should be ~ if tarball version is the one we're working *toward*. (By far preferred!)
# Should be + if tarball version is already released and we're moving forward after it.
SEPARATOR=${SEPARATOR:-'~'}

rm -f dist/*.tar.gz
python setup.py sdist

# There should only be one, so this should be safe.
tarball=$(echo dist/*.tar.gz)

echo mv "$tarball" "dist/$(basename $tarball .tar.gz)${SEPARATOR}${snapshotversion}.tar.gz"
mv "$tarball" "dist/$(basename $tarball .tar.gz)${SEPARATOR}${snapshotversion}.tar.gz"

echo "$PROJECT $revno" >> "$RECORDFILE"
sort "$RECORDFILE" > "$RECORDFILE".tmp
mv "$RECORDFILE".tmp "$RECORDFILE"

