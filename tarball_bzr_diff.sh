#!/bin/sh

retval=0

STATEPATH=${JENKINS_HOME:-$HOME}
BNT=in_bzr_but_not_in_tarball.txt
TNB=in_tarball_but_not_in_bzr.txt
BNTSAVED=$STATEPATH/$BNT.saved
TNBSAVED=$STATEPATH/$TNB.saved

bzr ls -R . --versioned | sort > bzr.lst
tar tzf nova-*.tar.gz  | cut -f2- -d/ | grep -v ^$ | sort -g > tarball.lst
rm -rf dist dist.zip
diff -u bzr.lst tarball.lst | grep -v ^--- | grep -v ^+++  > diff
grep ^- diff | sed -e s/^.// > $BNT
grep ^+ diff | sed -e s/^.// > $TNB

if [ "$1" = "ack" ]
then
        cp $BNT $BNTSAVED
        cp $TNB $TNBSAVED
        exit 0
fi

> report.txt

if ! diff -Nq $BNTSAVED $BNT > /dev/null
then
        retval=1
        echo "The list of files in bzr, but not in the tarball changed." >> report.txt
        echo "Lines beginning with - denote files that were either removed from bzr or recently included in the tarball." >> report.txt
        echo "Lines beginning with + denote files that were either got added to bzr recently or got removed from the tarball." >> report.txt
        diff -uN $BNTSAVED $BNT >> report.txt
fi
if ! diff -qN $TNBSAVED $TNB > /dev/null
then
        retval=1
        echo "The list of files in the tarball, but not in bzr changed." >> report.txt
        echo "Lines beginning with - denote files that were removed from the tarball, but is still in bzr." >> report.txt
        echo "Lines beginning with + denote files that were either got added to the tarball recently or which disappeared from bzr, but stayed in the tarball." >> report.txt
	diff -uN $TNBSAVED $TNB >> report.txt
fi

mkdir -p html/

echo '<html><title>Tarball vs bzr delta changes</title><body><pre>' > html/report.html
cat report.txt >> html/report.html
echo '</pre>' >> html/report.html

if [ $retval = 1 ]
then
	echo "<p>If these differences are ok, <a href="http://hudson.openstack.org/job/nova-tarball-bzr-delta/build">run the job again</a> and check the 'ack' box.</p>" >> report.txt
fi

echo '</body></html>' >> html/report.html

exit $retval
