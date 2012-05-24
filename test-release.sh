#!/bin/bash

# Copyright 2012 C & P Bibliography Services
#
# This is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# This is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA
#

# Usage: test-release.sh [output directory]
#
# This script runs the tests necessary to ensure that a Koha release can be
# produced from the current git repository. It should be run from the root
# of the git repository. The results of the package and tarball builds will
# be placed in ~/releases or the directory specified by the command-line
# argument.
#
# This script honors the following environment variables:
# SKIP_TESTS: skip the unit test step
# SKIP_DEB: skip all steps related to package building and installation
# SKIP_TGZ: skip all steps related to tarball building and installation
# SKIP_INSTALL: skip testing the package and tarball installation

export PERL5LIB=`pwd`
RELTOOLS=$(cd $(dirname "$0"); pwd)

START=$(date +%s)
START_FMT=`date`

if [ -n "$1" ]; then
    RELDIR=$1
else
    RELDIR=$HOME/releases
fi

MARCFLAVOURS='MARC21 UNIMARC NORMARC'

BRANCH=`git branch | grep '*' | sed -e 's/^* //' -e 's#/#-#'`
VERSION=`grep 'VERSION = ' kohaversion.pl | sed -e "s/^[^']*'//" -e "s/';//"`
TEST_QA=1
TMPFILE=`tempfile`
PKGFILE=/dev/null
ARCHIVEFILE=$RELDIR/koha-$BRANCH-$VERSION.tar.gz
rm -f $ARCHIVEFILE
rm -f $RELDIR/errors.log

echo "[0;34;48mStarting release test at $START_FMT[0;30;48m"
echo -e "\tBranch:  $BRANCH"
echo -e "\tVersion: $VERSION"
echo ""

if [ -z "$FAILURE" ] && [ -z "$SKIP_TESTS" ]; then
    echo "Running unit tests..."
    prove t/ t/db_dependent/ t/db_dependent/Labels xt/author/icondirectories.t xt/author/podcorrectness.t xt/author/translatable-templates.t xt/author/valid-templates.t xt/permissions.t xt/tt_valid.t > $TMPFILE 2>&1 || FAILURE='Unit tests'
fi
if [ -z "$FAILURE" ] && [ -z "$SKIP_DEB" ]; then
    echo "Updating pbuilder..."
    sudo pbuilder update > $TMPFILE 2>&1 || echo "[1;31;48mError updating pbuilder. Continuing anyway.[0;30;48m";
fi
if [ -z "$FAILURE" ] && [ -z "$SKIP_DEB" ]; then
    echo "Building packages..."
    DEBEMAIL=jcamins@cpbibliography.com debian/build-git-snapshot -D $BRANCH -r $RELDIR > $TMPFILE 2>&1 || FAILURE='Building package';
    PKGFILE=$RELDIR/`grep "dpkg-deb: building package .koha-common." $TMPFILE | sed -e 's#^[^/]*/##' | sed -e "s/'\.$//"`
    if [ "$PKGFILE" = "$RELDIR/" ]; then FAILURE='Building package'; fi
fi
if [ -z "$FAILURE" ] && [ -z "$SKIP_TGZ" ]; then
    echo "Preparing release tarball..."
    git archive --format=tar --prefix=koha-$VERSION/ $BRANCH | gzip > $ARCHIVEFILE 2> $TMPFILE || FAILURE='Creating archive';
    gpg -sb $ARCHIVEFILE || FAILURE='Signing archive';
    md5sum $ARCHIVEFILE > $ARCHIVEFILE.MD5 || FAILURE='Md5summing archive';
    gpg --clearsign $ARCHIVEFILE.MD5 || FAILURE='Signing md5sum';
fi
if [ -z "$FAILURE" ] && [ -z "$SKIP_DEB" ] && [ -z "$SKIP_INSTALL" ]; then
    echo "Installing package..."
    sudo dpkg -i $PKGFILE > $TMPFILE 2>&1 || FAILURE='Installing package';
    cat > /tmp/koha-sites.conf <<EOF
OPACPORT=9003
INTRAPORT=9004
EOF
    sudo mv /tmp/koha-sites.conf /etc/koha/koha-sites.conf
fi

for FLAVOUR in $MARCFLAVOURS; do
    VAR=SKIP_$FLAVOUR
    if [ -z "$FAILURE" ] && [ -z "$SKIP_DEB" ] && [ -z "$SKIP_INSTALL" ] && [ -z "${!VAR}" ]; then
        echo "Installing from package for $FLAVOUR..."
        if [ -z "$FAILURE" ]; then
            echo " Running koha-create for $FLAVOUR..."
            sudo koha-create --marcflavor=`echo $FLAVOUR | tr '[:upper:]' '[:lower:]'` --create-db pkgrel > $TMPFILE 2>&1 ||  FAILURE="Koha-create for $FLAVOUR";
        fi
        if [ -z "$FAILURE" ] && [ -z "$SKIP_WEBINSTALL" ]; then
            echo " Running webinstaller for $FLAVOUR..."
            prove $RELTOOLS/install-fresh.pl :: http://localhost:9004 http://localhost:9003 $FLAVOUR `sudo xmlstarlet sel -t -v 'yazgfs/config/user' '/etc/koha/sites/pkgrel/koha-conf.xml'` `sudo xmlstarlet sel -t -v 'yazgfs/config/pass' '/etc/koha/sites/pkgrel/koha-conf.xml'` > $TMPFILE 2>&1 || FAILURE="Running webinstaller for $FLAVOUR";
        fi
        echo " Cleaning up package install for $FLAVOUR..."
        sudo koha-remove pkgrel > $TMPFILE 2>&1 || FAILURE="Koha-remove for $FLAVOUR"
    fi
done

for FLAVOUR in $MARCFLAVOURS; do
    VAR=SKIP_$FLAVOUR
    if [ -z "$FAILURE" ] && [ -z "$SKIP_TGZ" ] && [ -z "$SKIP_INSTALL" ] && [ -z "${!VAR}" ]; then
        echo "Installing from tarball for $FLAVOUR..."
        export INSTALL_BASE=$RELDIR/fresh/koha
        export DESTDIR=$RELDIR/fresh
        export KOHA_CONF_DIR=$RELDIR/fresh/etc
        export ZEBRA_CONF_DIR=$RELDIR/fresh/etc/zebradb
        export PAZPAR2_CONF_DIR=$RELDIR/fresh/etc/pazpar2
        export ZEBRA_LOCK_DIR=$RELDIR/fresh/var/lock/zebradb
        export ZEBRA_DATA_DIR=$RELDIR/fresh/var/lib/zebradb
        export ZEBRA_RUN_DIR=$RELDIR/fresh/var/run/zebradb
        export LOG_DIR=$RELDIR/fresh/var/log
        export INSTALL_MODE=standard
        export DB_TYPE=mysql
        export DB_HOST=localhost
        export DB_NAME=koharel
        export DB_USER=koharel
        export DB_PASS=koharel
        export INSTALL_ZEBRA=yes
        export INSTALL_SRU=no
        export INSTALL_PAZPAR2=no
        export ZEBRA_MARC_FORMAT=`echo $FLAVOUR | tr '[:upper:]' '[:lower:]'`
        export ZEBRA_LANGUAGE=en
        export ZEBRA_USER=kohauser
        export ZEBRA_PASS=zebrastripes
        export KOHA_USER=`id -u -n`
        export KOHA_GROUP=`id -g -n`
        mkdir -p $RELDIR/fresh
        tar zxvf $ARCHIVEFILE -C /tmp > $TMPFILE 2>&1 || FAILURE="Untarring tarball for $FLAVOUR"
        cd /tmp/koha-$VERSION
        if [ -z "$FAILURE" ]; then
            echo -e " Running perl Makefile.PL for $FLAVOUR..."
            yes '' | perl Makefile.PL > $TMPFILE 2>&1 || FAILURE="Running Makefile.PL for $FLAVOUR";
        fi
        if [ -z "$FAILURE" ]; then
            echo -e " Running make for $FLAVOUR..."
            make > $TMPFILE 2>&1 || FAILURE="Running make for $FLAVOUR";
        fi
        if [ -z "$FAILURE" ]; then
            echo -e " Running make test for $FLAVOUR..."
            make test > $TMPFILE 2>&1 || FAILURE="Running make test for $FLAVOUR";
        fi
        if [ -z "$FAILURE" ]; then
            echo -e " Running make install for $FLAVOUR..."
            make install > $TMPFILE 2>&1 || FAILURE="Running make install for $FLAVOUR";
            sed -i -e 's/<VirtualHost 127.0.1.1:80>/<VirtualHost *:9001>/' -e 's/<VirtualHost 127.0.1.1:8080>/<VirtualHost *:9002>/' $RELDIR/fresh/etc/koha-httpd.conf
        fi
     
     
        if [ -z "$SKIP_WEBINSTALL" ]; then
            if [ -z "$FAILURE" ]; then
                mysql -u koharel -pkoharel -e "CREATE DATABASE koharel;" > $TMPFILE 2>&1 || FAILURE="Creating database for $FLAVOUR";
            fi
            if [ -z "$FAILURE" ]; then
                echo " Adding to sites-available for $FLAVOUR..."
                sudo ln -s $RELDIR/fresh/etc/koha-httpd.conf /etc/apache2/sites-available/release-fresh > $TMPFILE 2>&1 || FAILURE="Adding to sites-available for $FLAVOUR";
            fi
            if [ -z "$FAILURE" ]; then
                echo " Enabling site for $FLAVOUR..."
                sudo a2ensite release-fresh > $TMPFILE 2>&1 || FAILURE="Enabling site for $FLAVOUR";
            fi
            if [ -z "$FAILURE" ]; then
                echo " Restarting Apache for $FLAVOUR..."
                sudo apache2ctl restart > $TMPFILE 2>&1 || FAILURE="Restarting Apache for $FLAVOUR";
            fi

            if [ -z "$FAILURE" ]; then
                echo " Running webinstaller for $FLAVOUR..."
                prove $RELTOOLS/install-fresh.pl :: http://localhost:9002 http://localhost:9001 $FLAVOUR koharel koharel > $TMPFILE 2>&1 || FAILURE="Running webinstaller for $FLAVOUR";
            fi
     
            echo " Cleaning up for $FLAVOUR..."
            mysql -u koharel -pkoharel -e "DROP DATABASE koharel;" > /dev/null 2>&1
            sudo a2dissite release-fresh > /dev/null 2>&1
            sudo apache2ctl restart > /dev/null 2>&1
            sudo rm /etc/apache2/sites-available/release-fresh > /dev/null 2>&1
        fi
     
        rm -Rf /tmp/koha-$VERSION > /dev/null 2>&1
        rm -Rf $RELDIR/fresh > /dev/null 2>&1
    fi
done

if [ -n "$FAILURE" ]; then cp $TMPFILE $RELDIR/errors.log; fi

END=$(date +%s)
END_FMT=`date`
DIFF=$(( $END - $START ))

rm -f $TMPFILE
if [ -f $PKGFILE ]; then
    echo "[0;32;48mPackage at [1;32;48m`ls $PKGFILE`[0;30;48m";
else
    echo "[1;31;48mNo package built.[0;30;48m";
fi
if [ -f $ARCHIVEFILE ]; then
    echo "[0;32;48mTarball at [1;32;48m`ls $ARCHIVEFILE`[0;30;48m";
else
    echo "[1;31;48mNo tarball built.[0;30;48m";
fi

if [ -z "$FAILURE" ]; then
    echo "[0;32;48mSuccessfully finished release test at $END_FMT in $DIFF seconds[0;30;48m";
    echo -e "\tBranch:  $BRANCH";
    echo -e "\tVersion: $VERSION";
else
    echo "[4;31;48m[1;31;48m$FAILURE[0;31;48m[1;31;48m failed in release test at $END_FMT in $DIFF seconds[0;30;48m";
    echo "[0;31;48mError report at [1;31;48m$RELDIR/errors.log[0;30;48m";
    echo -e "\tBranch:  $BRANCH";
    echo -e "\tVersion: $VERSION";
    echo ""
    read -p "Would you like to view the error log? (Y/n) " VIEWERROR;
    if [ ! "x$VIEWERROR" = "xn" ]; then
        less $RELDIR/errors.log
    fi
fi
