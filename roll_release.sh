#!/bin/bash

# Copyright 2011 Chris Nighswonger
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

# TODO:
#   1. More parameterization
#   2. Add code to produce exit status

VERSION=$1;
BRANCH=$2;

git archive --format=tar --prefix=koha-$VERSION/ $BRANCH | gzip > releases/koha-$VERSION.tar.gz
cd releases
gpg -sb koha-$VERSION.tar.gz
md5sum koha-$VERSION.tar.gz > koha-$VERSION.tar.gz.MD5
gpg --clearsign koha-$VERSION.tar.gz.MD5

