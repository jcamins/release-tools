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
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA
#

use strict;
use warnings;

use POSIX qw(strftime);
use LWP::Simple;
use Text::CSV;
use Getopt::Long;

# TODO:
#   1. Paramatize!
#   2. Add optional verbose output
#   3. Add exit status code

# git log --pretty=format:'%s' v3.04.05..HEAD | grep -Eo '([B|b]ug|BZ)?(\s|:|-|_|,)?\s?[0-9]{4}\s' | grep -Eo '[0-9]{4}' -  | sort -u 

#release_notes_3_6_0.txt

# try to retrieve the current version number from kohaversion.pl
my $version = undef;
eval {
    require 'kohaversion.pl';
    $version = kohaversion();
};

my $tag         = undef;
my $HEAD        = "HEAD";
my $template    = undef;
my $rnotes      = undef;
my $commit_changes  = 0;
my $help        = 0;
my $verbose     = 0;

GetOptions(
    't|tag:s'       => \$tag,
    'h|head:s'      => \$HEAD,
    'template:s'    => \$template,
    'r|rnotes:s'    => \$rnotes,
    'v|version:s'   => \$version,
    'c|commit'      => \$commit_changes,
    'help|?'        => \$help,
    'verbose'       => \$verbose,
);

print "Creating release notes for version $version\n\n";
# variations on a theme of version numbers...

$version =~ m/(\d)\.\d(\d)\.\d(\d)\.\d+/g;
my $simplified_version = "$1.$2.$3";
my $expanded_version = "$1.0$2.0$3";

$version =~ m/(\d)\.\d(\d)\.\d(\d)\.\d+/g;
$template    = "release_notes_$1_$2_x.tmpl";
$rnotes      = "release_notes_$1_$2_$3.txt";

print "Using template: $template and release notes file: $rnotes\n\n";

my $git_add = 1 unless -e "misc/release_notes/$rnotes";

die "-t missing: a tag is required" if !$tag;
die "Useful information goes here..." if $help;

my @bug_list = ();
my @git_log = qx|git log --pretty=format:'%s' $tag..$HEAD|;

foreach (@git_log) {
    if ($_ =~ m/([B|b]ug|BZ)?\s?(?<![a-z]|\.)(\d{4})[\s|:|,]/g) {
#        print "$&\n"; # Uncomment this line and the die below to view exact matches
        push @bug_list, $2;
    }
}
#die "Done for now...\n"; #XXX
#@bug_list = sort {$a <=> $b} @bug_list;
my %seen = ();
@bug_list = grep{!$seen{$_}++} (sort {$a <=> $b} @bug_list);

print "Found " . scalar @bug_list . " bugs in this search\n\n" if $verbose;

# http://bugs.koha-community.org/bugzilla3/buglist.cgi?bug_id=2629%2C2847%2C3958%2C4161%2C5150%2C5885%2C5945%2C5974%2C6390%2C6471%2C6475%2C6628%2C6629%2C6679%2C6799%2C6895%2C6955%2C6963%2C6977%2C6989%2C6994%2C7061%2C7069%2C7076%2C7084%2C7085%2C7095%2C7117%2C7128%2C7134%2C7138%2C7146%2C7184%2C7185%2C7188%2C7207%2C7221&bug_id_type=anyexact&query_format=advanced&ctype=csv

my $url = "http://bugs.koha-community.org/bugzilla3/buglist.cgi?order=bug_severity%2Cbug_id&bug_id=";
$url .= join '%2C', @bug_list;
$url .= "&bug_id_type=anyexact&query_format=advanced&ctype=csv&columnlist=bug_severity%2Cshort_desc";

print "URL: $url\n" if $verbose;

my @csv_file = split /\n/, get($url);
my $csv = Text::CSV->new();

# Extract the column names
$csv->parse(shift @csv_file);
my @columns = $csv->fields;

my $highlights = '';
my $bugfixes = '';
my $sysprefs = '';

while (scalar @csv_file) {
    $csv->parse(shift @csv_file);
    my @fields = $csv->fields;
    if ($fields[1] =~ m/(blocker|critical|major)/) {
        $highlights .= "$fields[0]\t$fields[1]" . ($1 =~ /blocker|major/ ? "\t\t" : "\t") ."$fields[2]\n";
    }
    elsif ($fields[1] =~ m/(normal|enhancement)/) {
        $bugfixes .= "$fields[0]\t$fields[1]" . ($1 eq 'normal' ? "\t\t" : "\t") ."$fields[2]\n";
    }
}

open (SYSPREFS, "git diff $tag installer/data/mysql/sysprefs.sql | grep '^+[^+]' | sed -e 's/^\+//' |");
my @syspref_queries = <SYSPREFS>;
close SYSPREFS;

my @sysprefs;
foreach my $queryline (@syspref_queries) {
    $queryline =~ m/\(([^)]*)\)\s*VALUES\s*\(([^)]*)\)/;
    my @columns = split(/,/, $1);
    my @values = split(/,/, $2);
    my $variable = $values[(grep { $columns[$_] eq 'variable' } 0..$#columns) - 1];
    $variable =~ s/['"`]//g;
    push @sysprefs, $variable;
}
$sysprefs = '  * ' . join("\n  * ", sort(@sysprefs)) . "\n";

open (RNOTESTMPL, "< misc/release_notes/$template");
my @release_notes = <RNOTESTMPL>;
close RNOTESTMPL;

open (RNOTES, "> misc/release_notes/$rnotes");

foreach my $line (@release_notes) {
    if ($line =~ m/<<([a-z|_]+)>>(.*?)/g) { # why?
        my $key_word = $1;
        print "Keyword found: $key_word\n\n" if $verbose;
        #   Find and replace template markers
        if ($key_word eq 'highlights') {
            $line =~ s/<<highlights>>/$highlights/;
        }
        if ($key_word eq 'bugfixes') {
            $line =~ s/<<bugfixes>>/$bugfixes/;
        }
        if ($key_word eq 'sysprefs') {
            $line =~ s/<<sysprefs>>/$sysprefs/;
        }
        if ($key_word eq 'contributors') {
            # Now we'll alphabetize the contributors based on surname (or at least the last word on their line)
            # WARNING!!! Obfuscation ahead!!!
            my @contributor_list =
                map { $_->[1] }
                sort { $a->[0] cmp $b->[0] }
                map { [(split /\s+/, $_)[scalar(split /\s+/, $_)-1], $_] }
                qx(git log --pretty=short $tag..$HEAD | git shortlog -s | sort -k3 -);

            my $contributors = join "", @contributor_list;
            $line =~ s/<<contributors>>/$contributors/;
        }
        if ($key_word eq 'version') {
            print "Simplified version number: $simplified_version\n\n" if $verbose;
            $line =~ s/<<version>>/$simplified_version/;
        }
        if ($key_word eq 'expanded_version') {
            print "Expanded version number: $expanded_version\n\n" if $verbose;
            $line =~ s/<<expanded_version>>/$expanded_version/;
        }
        if ($key_word eq 'date') {
            my $current_date = strftime "%d %b %Y", gmtime;
            print "Datestamp of release notes: $current_date\n\n" if $verbose;
            $line =~ s/<<date>>/$current_date/;
        }
    }
    print RNOTES "$line";
}

# Add autogenerated blurb to the bottom
my $time_stamp = strftime("%d %b %Y %T", gmtime);
print RNOTES "\n##### Autogenerated release notes updated last on $time_stamp Z #####";

close RNOTES;

if ($commit_changes) {
    if ($git_add) {
        print "Adding file to repo...\n";
        my @add_results = qx|git add misc/release_notes/$rnotes|;
    }
    print "Commiting changes...\n";
    my @commit_results = qx|git commit -m "Release Notes for $version $time_stamp Z" misc/release_notes/$rnotes|;
}
