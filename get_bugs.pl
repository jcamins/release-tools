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

use Pod::Usage;
use POSIX qw(strftime);
use LWP::Simple;
use Text::CSV;
use Getopt::Long;
use Template;
use File::Basename;
use File::Spec;
use lib('.');
use encoding('utf8');
use Text::CSV; # used to store bugzilla full descriptions

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
my $html        = 0; # if set, will create a HTML version of the release notes
my $login       = '';
my $password    = '';

GetOptions(
    't|tag:s'       => \$tag,
    'head:s'      => \$HEAD,
    'template:s'    => \$template,
    'r|rnotes:s'    => \$rnotes,
    'v|version:s'   => \$version,
    'c|commit'      => \$commit_changes,
    'html'        => \$html,
    'help|h'        => \$help,
    'verbose'       => \$verbose,
    'u'             => \$login,
    'p'             => \$password,
);

if ($help) {
    pod2usage( -verbose => 2 );
    exit;
}

print "Creating release notes for version $version\n\n";
# variations on a theme of version numbers...

my $reltools = File::Spec->rel2abs( dirname(__FILE__) );
my $tt;
$tt = Template->new(
        {
        INCLUDE_PATH => File::Spec->rel2abs( dirname(__FILE__) ),
        ENCODING => 'utf8',
        }
    ) || die $tt->error(), "\n";
my %arguments;

die "No usable version" unless $version =~ m/(\d)\.(\d\d)\.(\d\d)(\.\d+)?(-\w*)?/g;
my $major = $1;
my $minor = $2;
my $release = $3;
my $expanded_minor = $2;
my $expanded_release = $3;
my $additional = $5;
$minor =~ s/^0*(\d+)$/$1/;
$release =~ s/^0*(\d+)$/$1/;
my $shortversion = "$major.$minor.$release";
$arguments{shortversion}     = $shortversion;
$arguments{shortversion}    .= "$additional" if ($additional);
$arguments{expandedversion}  = "$major.$expanded_minor.$expanded_release";
$arguments{expandedversion} .= "$additional" if ($additional);
$arguments{line}             = "$major." . ($minor % 2 ? $minor + 1 : $minor);
$arguments{MAJOR} = $release?0:1; # major release if the last number is 0

# description is a hash used to store bugzilla descriptions
# bugzilla descriptions are slow to retrieve from bugzilla, and can't be updated
# so, retrieve them once, and store them for re-use if needed
# we store them in a CSV file so, they can be modified manually if needed, for more clarity
# and we often need more clarity or clean some technical informations
my %descriptions;
if (-e "$reltools/descriptions/descriptions-$shortversion.csv") {
        my $csv = Text::CSV->new ( { sep_char => '|', binary => 1 } )  # should set binary attribute.
                        or die "Cannot use CSV: ".Text::CSV->error_diag ();

        open my $fh, "<:encoding(utf8)", "$reltools/descriptions/descriptions-$shortversion.csv" or die "$reltools/descriptions-$shortversion.csv: $!";
        while ( my $row = $csv->getline( $fh ) ) {
# uncomment the next line if you've problem of CSV reading (like "" in descriptions)
# you'll see the last valid line read
#           print "read : $row->[0]\n";
            $descriptions{$row->[0]} = $row->[2];
        }
        $csv->eof or $csv->error_diag();
        close $fh;
}

$template    = "release_notes_tmpl".($html?"_html":"").".tt" unless $template;
$rnotes      = "misc/release_notes/release_notes_${major}_${minor}_${release}.".($html?"html":"txt") unless $rnotes;

my $pootle = "http://translate.koha-community.org/projects/$major$minor/";
$pootle = "http://translate.koha-community.org/" unless defined(get($pootle));

my $translationpage = get($pootle);
my @translations = ( {language => 'English (USA)'} );

while ($translationpage =~ m#<td class="stats-name">\W*<a[^>]*>([^<]*)</a>\W*</td>\W*<td class="stats-graph">\W*<div class="sortkey">([0-9]*)<#g) {
    push @translations, {language => "$1 ($2%)"} if ($2 > 50);
}

while ($translationpage =~ m#<td class="language">\W*<a[^>]*>([^<]*)</a>\W*</td>\W*<td>\W*<div class="sortkey">([0-9]*)<#g) {
    push @translations, {language => "$1 ($2%)" } if ($2 > 50);
}

$arguments{translations} = \@translations;

$arguments{releaseteam} = "release_team_$arguments{line}".($html?'_html':'').".tt";

print "Using template: $template and release notes file: $rnotes\n\n";

my $git_add = 1 unless -e "misc/release_notes/$rnotes";

$tag = `git describe --abbrev=0` unless $tag;
chomp $tag;

my @bug_list = ();
my @git_log = qx|git log --pretty=format:'%s' $tag..$HEAD|;

$arguments{branch} = `git branch | grep '*' | sed -e 's/^* //' -e 's#/#-#'`;
chomp $arguments{branch};
my $lastrelease = `grep -E 'Koha [0-9.]* released' docs/history.txt | tail -1`;
$lastrelease =~ m/^([a-zA-Z]* [0-9]*) ([0-9]*)(  +|\t)Koha ([0-9.]*) released/;
$arguments{lastreleasedate} = "$1, $2";
$arguments{lastrelease} = $4;
$arguments{downloadlink} = "http://download.koha-community.org/koha-$arguments{expandedversion}.tar.gz";

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

if (scalar @bug_list) {
    my $url = "http://bugs.koha-community.org/bugzilla3/buglist.cgi?order=component%2Cbug_severity%2Cbug_id&bug_id=";
    $url .= join '%2C', @bug_list;
    $url .= "&bug_id_type=anyexact&query_format=advanced&ctype=csv&columnlist=bug_severity%2Cshort_desc%2Ccomponent";

    print "URL: $url\n" if $verbose;

    my @csv_file = split /\n/, get($url);
    my $csv = Text::CSV->new();

# Extract the column names
    $csv->parse(shift @csv_file);
    my @columns = $csv->fields;

    # the current component for the 3 cases (highlights, bugfixes, enhancements)
    my ($current_highlight,$current_bugfix,$current_enhancement) = ('','','');
    #The lists of highlights, bugfixes and enhancement
    # the component_xxx contains an array of hash reset for each component
    # the xxx contains an array of hash with component & component_xxx array of hash
    my (@component_highlights,@highlights);
    my (@component_bugfixes,@bugfixes);
    my (@component_enhancements,@enhancements);
    my $nb_enhancements = 0;
    my $nb_bugfixes     = 0;
    while (scalar @csv_file) {
        $csv->parse(shift @csv_file);
        my @fields = $csv->fields;
        $fields[2] = ucfirst($fields[2]);
        if ($fields[1] =~ m/(blocker|critical|major)/) {
            if ($current_highlight && $fields[3] ne $current_highlight) {
                my @t=@component_highlights;
                push @highlights, { component => $current_highlight, list => \@t };
                @component_highlights=();
            }
            $current_highlight=$fields[3];
            push @component_highlights, { number=> $fields[0],severity=> $fields[1], short_desc=> $fields[2] };
            $nb_bugfixes++;
        }
        elsif ($fields[1] =~ m/(normal|minor|trivial)/) {
            if ($current_bugfix && $fields[3] ne $current_bugfix) {
                my @t=@component_bugfixes;
                push @bugfixes, { component => $current_bugfix, list => \@t };
                @component_bugfixes=();
            }
            $current_bugfix=$fields[3];
            push @component_bugfixes, { number=> $fields[0],severity=> $fields[1], short_desc=> $fields[2] };
            $nb_bugfixes++;
        } else { # enhancements
            #
            # if bugzilla login and password have been provided, retrieve the description of the bug
            #
            my $description;
            if ($login && $password) {
                if ( $descriptions{$fields[0]} ) {
#                    print "stored $fields[0]\n";
                    $description = $descriptions{$fields[0]};
                } else {
#                    print "retrieving $fields[0]\n";
                    my $bugdetail = `bugz -u $login -p $password -b http://bugs.koha-community.org/bugzilla3/ get $fields[0]`;
                    $bugdetail =~ /\[Comment \#0\].*?\n-------------------------------------------------------------------------------\n(.*)\[Comment \#1\]/s;
                    $description = $1;
                    #
                    # append this to the storable description
                    # no one can change bug description, so once we've got it, remember it !
                    $descriptions{$fields[0]} = $description;
                    # OK, save the file with the new bug found
                    # FIXME not very efficient to save on each bug added
                    my $csv = Text::CSV->new ();
                    my $fh;
                    open $fh, ">:encoding(utf8)", "$reltools/descriptions/descriptions-$shortversion.csv" or die "$reltools/descriptions/descriptions-$shortversion.csv: $!";
                    print $fh "number|shortdesc|fulldesc\n";

                    foreach my $desc (keys %descriptions) {
                        $descriptions{$desc} =~ s/\|/ /g;
                        $descriptions{$desc} =~ s/"/ /g;
                        print $fh $desc."||\"".$descriptions{$desc}."\"\n";
                    }
                    close $fh or die "$reltools/descriptions/descriptions-$shortversion.csv: $!";

                }

                if ($html) {
                    # do some basic formatting if we are in html mode, if the description is multilined
                    $description =~ s/^    /&nbsp;&nbsp;&nbsp;&nbsp;/mg;
                    $description =~ s/^  /&nbsp;&nbsp;/mg; 
                    $description =~ s/([a-zA-Z0-9 ,])\n/$1 /mg;
                    $description =~ s/</&lt;/g;
                    $description =~ s/>/&gt;/g;
                    $description =~ s/\n/<br\/>/g;
                }
            }
            if ($current_enhancement && $fields[3] ne $current_enhancement) {
                my @t=@component_enhancements;
                push @enhancements, { component => $current_enhancement, list => \@t };
                @component_enhancements=();
            }
            $current_enhancement=$fields[3];
            push @component_enhancements, { number=> $fields[0],severity=> $fields[1], short_desc=> $fields[2], description => $description };
            $nb_enhancements++;
        }
    }
    # push the last components
    push @highlights, { component => $current_highlight, list => \@component_highlights };
    push @bugfixes, { component => $current_bugfix, list => \@component_bugfixes };
    push @enhancements, { component => $current_enhancement, list => \@component_enhancements };
    $arguments{highlights}      = \@highlights;
    $arguments{bugfixes}        = \@bugfixes;
    $arguments{enhancements}    = \@enhancements;
    $arguments{nb_bugfixes}     = $nb_bugfixes;
    $arguments{nb_enhancements} = $nb_enhancements;
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
    push @sysprefs, { name => $variable };
}
$arguments{sysprefs} = \@sysprefs;

# Now we'll alphabetize the contributors based on surname (or at least the last word on their line)
# WARNING!!! Obfuscation ahead!!!
my @contribs;
my @contributor_list = map { { name => $_->[1]} }
    sort { $a->[0] cmp $b->[0] }
    map { [(split /\s+/, $_)[scalar(@contribs = split /\s+/, $_)-1], $_] }
    qx(git log --pretty=short $tag..$HEAD | git shortlog -s | sort -k3 -);

my @signers;
my @signer_list = map { { name => $_->[1]} }
    sort { $a->[0] cmp $b->[0] }
    map { [(split /\s+/, $_)[scalar(@signers = split /\s+/, $_)-1], $_] }
    qx(git log $tag..$HEAD | grep 'Signed-off-by' | sed -e 's/^.*Signed-off-by: //' | sed -e 's/ <.*\$//' | sort -k3 - | uniq -c);

my @sponsor_list = map { {name => $_} }
            qx(git log $tag..$HEAD | grep 'Sponsored-by' | sed -e 's/^.*Sponsored-by: //' | sort | uniq);

# contributing companies, with their number of commits, by alphabetical order
# companies are retrieved from the email address.
# generic emails like hotmail.com, gmail.com are cumulated in a "unitentified" contributor
my %domain_map;

open (my $domainmapfh, File::Spec->rel2abs( dirname(__FILE__) . '/gitdm/domain-map' ));
while (<$domainmapfh>) {
    chomp $_;
    $_ =~ m/^([^# ]*) (.*)$/;
    $domain_map{$1} = $2;
}
close ($domainmapfh);
    

my %companies_list;
foreach (map { {name => $_->[1]} }
    sort { $a->[0] cmp $b->[0] }
    map { [(split /\s+/, $_)[scalar(@contribs = split /\s+/, $_)-1], $_] }
    qx(git log --pretty=short $tag..$HEAD | git shortlog -s -e | sort -k3 -) ) {
        $_->{name} =~ /(\d+).*@(.*)>/;
        my ($nbpatch,$company) = ($1,$2);
        if ($company =~ /o2\.pl|gmail\.com|hotmail\.com|\(none\)/) {
            $companies_list{unidentified} += $nbpatch;
        } else {
            if ($domain_map{$company}) {
                $company = $domain_map{$company};
            }
            $companies_list{$company} += $nbpatch;
        }
    }
my @companies_list;
foreach (sort {$a cmp $b} keys %companies_list) {
    push @companies_list, {name => sprintf("% 7d %s", $companies_list{$_}, $_)};
}

$arguments{contributors} = \@contributor_list;
$arguments{signers} = \@signer_list;
$arguments{sponsors} = \@sponsor_list;
$arguments{companies} = \@companies_list;
$arguments{date} = strftime "%d %b %Y", gmtime;

# Add autogenerated blurb to the bottom
my $time_stamp = strftime("%d %b %Y %T", gmtime);
$arguments{timestamp} = "##### Autogenerated release notes updated last on $time_stamp Z #####";

$tt->process($template, \%arguments, $rnotes, {binmode => ":utf8"})|| die $tt->error(), "\n";

if ($commit_changes) {
    if ($git_add) {
        print "Adding file to repo...\n";
        my @add_results = qx|git add misc/release_notes/$rnotes|;
    }
    print "Commiting changes...\n";
    my @commit_results = qx|git commit -m "Release Notes for $version $time_stamp Z" misc/release_notes/$rnotes|;
}

exit 0;
=head1 NAME

get_bugs.pl - Generate release notes

=head1 USAGE

=over

=item get_bugs.pl [-t] [-h] [--template:template] [-r:notes] [-v:version] [-c] [--html][--help][--verbose][-u bugzilla_login][-p bugzilla password]

This script will generate releases notes from a template file (that can be specified), by retrieving all bugs in git since a given tag
The script retrieve the patch description from bugzilla, and, if login/password provided, the comment 0 (detailled description)
It also generate contributors & signers & sponsor list (using git informations)


=back

=head1 PARAMETERS

    t|tag       specify where the release start from. If not specified, it's the last stable .0 release
    head        NEED DOC,
    template    The template file to use to generate the release notes,
    r|rnotes    NEED DOC,
    v|version   the version to generate. Calculated from kohaversion if not provided
    c|commit    NEED DOC
    html        if set, the notes will be generated in HTML format (useful for koha-community.org)
    help|h      display this help
    verbose     verbose
    u           a bugzilla login. If provided, will append the description/comment 0 to each enhancement
    p           a bugzilla password. If provided, will append the description/comment 0 to each enhancement


=cut
