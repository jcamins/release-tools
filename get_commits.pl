#!/usr/bin/perl

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
# this software; if not, write to the Free Software Foundation, Inc., 59 Temple
# Place, Suite 330, Boston, MA  02111-1307 USA
#

use strict;
use warnings;

use LWP::Simple;
use Text::CSV;
use Data::Dumper;

# TODO:
#   1. Paramatize!
#   2. Add optional verbose output
#   3. Add exit status code
#   4. Add help

my @git_cherry = qx|git cherry -v 3.6.x master|;
my $commit_list = {};
my $no_bug_number = {};

foreach (@git_cherry) {
    $_ =~ m/^\+\s([0-9a-z]+)/;
    my $commit_id = $1;
    if ($_ =~ m/^\+.*([B|b]ug|BZ)?\s?(?<![a-z]|\.)(\d{4})[\s|:|,]/g) {
        push (@{$commit_list->{"$2"}}, $commit_id); # catalog commits with a bug number based on bug number
    }
    elsif ($_ !~ m/^\-/) {
        push (@{$no_bug_number->{"$commit_id"}}, $_); # catalog commits without a bug number based on commit id
    }
}

my @bug_list = keys(%$commit_list);

@bug_list = sort {$a <=> $b} @bug_list;

my $url = "http://bugs.koha-community.org/bugzilla3/buglist.cgi?order=bug_id&columnlist=bug_severity&content=";
$url .= join '%2C', @bug_list;
$url .= "&ctype=csv";

my @csv_file = split /\n/, get($url);

my $csv = Text::CSV->new();

# Extract the column names
$csv->parse(shift @csv_file);
my @columns = $csv->fields;

my $enhancements = {};
my $bug_fixes = {};

while (scalar @csv_file) {
    $csv->parse(shift @csv_file);
    my @fields = $csv->fields;
    if ($fields[1] =~ m/(enhancement)/) {
        push (@{$enhancements->{"$fields[0]"}}, @{$commit_list->{"$fields[0]"}});
    }
    else {
        push (@{$bug_fixes->{"$fields[0]"}}, @{$commit_list->{"$fields[0]"}});
    }
}


use Data::Dumper;
print "ENHANCEMENTS:\n";
print Dumper($enhancements);
print "\nBUGFIXES:\n";
print Dumper($bug_fixes);
print "\nNO BUG NUMBER:\n";
print Dumper($no_bug_number);
