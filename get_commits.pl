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

use Git;
use LWP::Simple;
use Text::CSV;
use Data::Dumper;
use Getopt::Long;
use IO::Prompt;

# TODO:
#   1. Paramatize!
#   2. Add optional verbose output
#   3. Add exit status code
#   4. Add help

my $branch  = undef;
my $HEAD    = 'master';
my $limit   = 0;
my $help    = 0;
my $verbose = 0;

GetOptions(
    'b|branch:s'    => \$branch,
    'h|head:s'      => \$HEAD,
    'l|limit:s'     => \$limit,
    'h|help|?'      => \$help,
    'v|verbose'     => \$verbose,
);

my $usage = << 'ENDUSAGE';

This script retrieves the output of 'git cherry' and parses through it
creating a list of enhancements and bugfixes found in master (or at the
user's option an alternative 'HEAD') but not in the 'branch' passed in.
The script will then auto-cherry-pick the missing bugfixes and produce
a list for manual review of the missing enhancements.

This script has the following parameters :
    -b --branch: branch to compare against 'HEAD' ('HEAD' is 'master' by default)
    -h --head: 'HEAD' other than 'master' against which to compare 'branch'
    -h --help: this message
    -v --verbose: provides verbose output to STDOUT

ENDUSAGE

die $usage if $help;

my @unapplied_bugfixes = ();
my @unapplied_anonfixes = ();
my @unapplied_enhancements = ();
my @unclean_commits = ();

if (-e "unapplied_bugfixes.$branch.txt") {
    open(BF, "<unapplied_bugfixes.$branch.txt");
    @unapplied_bugfixes = <BF>;
    close BF;
}
if (-e "unapplied_anonfixes.$branch.txt") {
    open(AF, "<unapplied_anonfixes.$branch.txt");
    @unapplied_anonfixes = <AF>;
    close AF;
}
if (-e "unapplied_enhancements.$branch.txt") {
    open(EN, "<unapplied_enhancements.$branch.txt");
    @unapplied_enhancements = <EN>;
    close EN;
}
if (-e "unclean_commits.$branch.txt") {
    open(UC, "<unclean_commits.$branch.txt");
    @unclean_commits = <UC>;
    close UC;
}

my $repo = Git->repository (Directory => '/home/cnighs/koha.3.2.test');

my @git_command = ('cherry', '-v', $branch, $HEAD);
push @git_command, $limit if $limit;

my ($fh, $c) = $repo->command_output_pipe(@git_command);
my @git_cherry = <$fh>;
$repo->command_close_pipe($fh, $c);

my $commit_list = {};
my $no_bug_number = {};
my $enhancements = {};
my $bug_fixes = {};

foreach (@git_cherry) {
    $_ =~ m/^\+\s([0-9a-z]+)/;
    my $commit_id = $1;
    if ($_ =~ m/^\+.*([B|b]ug|BZ)?\s?(?<=\s)(\d+)(?=[\s|:|,])/g) {
        my $bug_number = $2;
        next if grep (/$bug_number/, @unapplied_bugfixes);
        next if grep (/$bug_number/, @unapplied_enhancements);
        next if grep (/$bug_number/, @unclean_commits);
        push (@{$commit_list->{"$bug_number"}}, $commit_id); # catalog commits with a bug number based on bug number
    }
    elsif ($_ !~ m/^\-/) {
        next if grep (/$commit_id/, @unapplied_anonfixes);
        push (@{$no_bug_number->{"$commit_id"}}, $commit_id); # catalog commits without a bug number based on commit id
    }
    elsif ($_ =~ m/^\-/) {
        # do some stuff
    }
    else {
        # do some other stuff
    }
}

if (scalar(keys(%$commit_list)) == 0 && scalar(keys(%$no_bug_number)) == 0) {
    print "\nCongratulations!! There are no new commits to pick!\n\n";
    exit 1;
}

if (scalar(keys(%$commit_list))) {
    my @bug_list = keys(%$commit_list);

    @bug_list = sort {$a <=> $b} @bug_list;

    my $url = "http://bugs.koha-community.org/bugzilla3/buglist.cgi?order=bug_id&columnlist=bug_severity%2Cshort_desc&bug_id=";
    $url .= join '%2C', @bug_list;
    $url .= "&ctype=csv";

    $verbose && print "URL: $url\n";

    my @csv_file = split /\n/, get($url);

    my $csv = Text::CSV->new();

# Extract the column names
    $csv->parse(shift @csv_file);
    my @columns = $csv->fields;

    while (scalar @csv_file) {
        $csv->parse(shift @csv_file);
        my @fields = $csv->fields;
        #print "Bug Number: $fields[0], Bug Type: $fields[1]\n";
        if ($fields[1] =~ m/(enhancement)/) {
            push (@{$enhancements->{"$fields[0]"}}, @{$commit_list->{"$fields[0]"}});
        }
        else {
            push (@{$bug_fixes->{"$fields[0]"}}, @{$commit_list->{"$fields[0]"}});
        }
    }

    foreach my $bug_number (keys(%$bug_fixes)) {
        while( prompt "Shall I apply the bugfix(s) for $bug_number? (Y/n)") {
            if ($_ =~ m/^[Y|y]/) {
                    foreach my $commit_id (@{$bug_fixes->{$bug_number}}) {
#                        my @cherry_pick = ();
#                        {exec ("git cherry-pick -x -s $commit_id") };
                        my @git_command = ('cherry-pick', '-x', '-s', $commit_id);
                        my ($fh, $c) = $repo->command_output_pipe(@git_command);
                        my @cherry_pick = <$fh>;
                        eval { $repo->command_close_pipe($fh, $c); };
                        if ($@) {
                            _revert($repo, $bug_number, $branch);
                            next;
                        }
                    }
                last;
                }
            else {
                open(BF, ">>unapplied_bugfixes.$branch.txt");
                print BF "$bug_number\n";
                close BF;
                last;
            }
        }
    }
}

while (scalar(keys(%$no_bug_number)) && prompt "Shall we review commits without bug numbers now? (Y/n)") {
    last if $_ =~ m/^[N|n]/;
    foreach my $commit_number (keys(%$no_bug_number)) {
        while( prompt "Shall I apply commit number $commit_number? (Y/n)") {
            if ($_ =~ m/^[Y|y]/) {
                    foreach my $commit_id (@{$no_bug_number->{$commit_number}}) {
                        my $cherry_pick = qx|git cherry-pick -x -s $commit_id|;
                        print $cherry_pick;
                    }
                last;
                }
            else {
                open(AF, ">>unapplied_anonfixes.$branch.txt");
                print AF "$commit_number\n";
                close AF;
                last;
            }
        }
    }
    last;
}

while (scalar(keys(%$enhancements)) && prompt "Shall we review enhancements now? (Y/n)") {
    last if $_ =~ m/^[N|n]/;
    foreach my $bug_number (keys(%$enhancements)) {
        while( prompt "Shall I apply enhancement $bug_number? (Y/n)") {
            if ($_ =~ m/^[Y|y]/) {
                    foreach my $commit_id (@{$enhancements->{$bug_number}}) {
                        my $cherry_pick = qx|git cherry-pick -x -s $commit_id|;
                        print $cherry_pick;
                    }
                last;
                }
            else {
                open(EN, ">>unapplied_enhancements.$branch.txt");
                print EN "$bug_number\n";
                close EN;
                last;
            }
        }
    }
    last;
}

print "Please review the following unclean commits:\n" . join '', @unclean_commits;

exit 0;

sub _revert {
    my ($repo, $branch, $bug_number) = @_;
    open(UC, ">>unclean_commits.$branch.txt");
    print UC "$bug_number\n";
    push @unclean_commits, $bug_number;
    print "\n\nReverting failed cherry-pick...\n\n";
    my ($fh, $c) = $repo->command_output_pipe('reset', '--hard', 'HEAD');
    print <$fh>;
    $repo->command_close_pipe($fh, $c);
    close UC;
}
