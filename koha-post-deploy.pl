#!/usr/bin/perl -w

# koha-post-deploy.pl - script to automatically deploy Koha tarball
#
# Copyright (C) 2012  C & P Bibliography Services
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use Config::Simple;

my $cfg_file = shift;

die "Please provide a summary config file\n" unless $cfg_file;

my $config  = new Config::Simple("$cfg_file");
my $staging = $config->param('staging');
my $server  = $config->param('upload-tgz-to');

exit 0 unless $server;

opendir( DIR, $staging );
while ( my $file = readdir(DIR) ) {
    next unless -s $file;
    system("scp $staging/$file $server$file");
}

exit 0;
