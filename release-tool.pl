#!/usr/bin/perl -w

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

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use File::Spec;
use File::Copy;
use Data::Dumper;
use File::Basename;
use File::Path qw/make_path remove_tree/;
use Term::ANSIColor;
use Time::HiRes qw/time/;
use POSIX qw/strftime ceil/;
use TAP::Harness;
use DBI;
use MIME::Lite;
use Template;
use Config;

$SIG{INT} = \&interrupt;

sub usage {
    pod2usage( -verbose => 2 );
    exit;
}

$|                          = 1;
$Term::ANSIColor::AUTORESET = 1;

my %config = (

    # general run configuration options
    quiet   => 0,
    verbose => 0,

    # behavior options
    autoversion => 0,

    # actions
    clean   => 0,
    deploy  => 0,
    release => 0,
    sign    => 0,
    tag     => 0,

    # skips
    # file locations
    'build-result' => '',
    package        => '',
    tarball        => '',
    rnotes         => '',
    kohaclone      => '',

    # database settings
    database => $ENV{KOHA_DATABASE} || 'koharel',
    user     => $ENV{KOHA_USER}     || 'koharel',
    password => $ENV{KOHA_PASS}     || 'koharel',

    # announcement settings
    'email-template' => 'announcement.eml.tt',
    'email-recipients' =>
      'koha@lists.katipo.co.nz, koha-devel@lists.koha-community.org',
    'email-subject' => "New Koha version",
    'website-file'  => 'announcement.html.tt',
);

my $deployed        = 'no';
my $signed_tarball  = 'no';
my $signed_packages = 'no';
my $tagged          = 'no';
my $cleaned         = 'no';
my $skipped         = '';
my $finished_tests  = 'no';
my $built_tarball   = 'no';
my $built_packages  = 'no';
my $output;
my $drh;
my $repo;
my @tested_tarball_installs;
my @tested_package_installs;
my %cmdline;

my $options = GetOptions(
    \%cmdline,            'config=s',
    'quiet|q+',           'verbose|v+',
    'help|h',             'sign|s',
    'deploy|d',           'tag|g',
    'clean|c',            'autoversion|a',
    'release',            'skip-tests',
    'skip-deb',           'skip-tgz',
    'skip-install',       'skip-marc21',
    'skip-unimarc',       'skip-normarc',
    'skip-webinstall',    'skip-pbuilder',
    'skip-rnotes',        'database=s',
    'user=s',             'password=s',
    'kohaclone|k=s',      'build-result|b=s',
    'tarball|t=s',        'rnotes|r=s',
    'use-dist-rnotes',    'repository=s',
    'branch=s',           'version=s',
    'maintainer-name=s',  'maintainer-email=s',
    'email-recipients=s', 'email-subject=s',
    'email-template=s',   'email-file=s',
);

binmode( STDOUT, ":utf8" );

if ( $cmdline{help} ) {
    usage();
}

if ( defined( $cmdline{config} ) && -f $cmdline{config} ) {
    Config::Simple->import_from( $cmdline{config}, %config );
}
foreach my $key ( keys %cmdline ) {
    $config{$key} = $cmdline{$key};
}

if ( $cmdline{release} ) {
    $config{sign}    = 1;
    $config{deploy}  = 1;
    $config{tag}     = 1;
    $config{tarball} = "koha-$config{'version'}.tar.gz";
}

my $starttime = time();

chdir $repo if ( $repo && -d $repo );

my $reltools = File::Spec->rel2abs( dirname(__FILE__) );

$config{'kohaclone'} = File::Spec->rel2abs( File::Spec->curdir() )
  unless ( -d $config{'kohaclone'} );

my @marcflavours;
push @marcflavours, 'MARC21'  unless $config{'skip-marc21'};
push @marcflavours, 'UNIMARC' unless $config{'skip-unimarc'};
push @marcflavours, 'NORMARC' unless $config{'skip-normarc'};

chomp( $config{'branch'} =
      `git branch | grep '*' | sed -e 's/^* //' -e 's#/#-#'` )
  unless $config{'branch'};
chomp( $config{'version'} =
      `grep 'VERSION = ' kohaversion.pl | sed -e "s/^[^']*'//" -e "s/';//"` )
  unless $config{'version'};
chomp( $config{'maintainer-name'} = `git config --global --get user.name` )
  unless $config{'maintainer-name'};
chomp( $config{'maintainer-email'} = `git config --global --get user.email` )
  unless $config{'maintainer-email'};

$config{'build-result'} =
  "$ENV{HOME}/releases/$config{'branch'}/$config{'version'}"
  unless ( $config{'build-result'} );
make_path( $config{'build-result'} );

opendir( DIR, $config{'build-result'} );

while ( my $file = readdir(DIR) ) {

    # We only want files
    next unless ( -f "$config{'build-result'}/$file" );

    unlink "$config{'build-result'}/$file";
}

$ENV{TEST_QA} = 1;

if ( $config{'tarball'} =~ m#/# ) {
    $config{'tarball'} = '' unless ( -d dirname( $config{'tarball'} ) );
}
elsif ( $config{'tarball'} ) {
    $config{'tarball'} = "$config{'build-result'}/$config{'tarball'}";
}

$config{'tarball'} =
  "$config{'build-result'}/koha-$config{'branch'}-$config{'version'}.tar.gz"
  unless ( $config{'tarball'} );

$config{'rnotes'} = "$config{'build-result'}/release_notes.txt"
  unless $config{'rnotes'};

unlink $config{'tarball'};
unlink $config{'rnotes'} unless $config{'use-dist-rnotes'};
unlink "$config{'build-result'}/errors.log";

print_log(
    colored(
        "Starting release test at "
          . strftime( '%D %T', localtime($starttime) ),
        'blue'
    )
);
print_log("\tBranch:  $config{'branch'}\n\tVersion: $config{'version'}\n");

unless ( $config{'skip-tests'} ) {
    tap_task(
        "Running unit tests",
        0,
        undef,
        tap_dir("$config{'kohaclone'}/t"),
        tap_dir("$config{'kohaclone'}/t/db_dependent"),
        tap_dir("$config{'kohaclone'}/t/db_dependent/Labels"),
        "$config{'kohaclone'}/xt/author/icondirectories.t",
        "$config{'kohaclone'}/xt/author/podcorrectness.t",
        "$config{'kohaclone'}/xt/author/translatable-templates.t",
        "$config{'kohaclone'}/xt/author/valid-templates.t",
        "$config{'kohaclone'}/xt/permissions.t",
        "$config{'kohaclone'}/xt/tt_valid.t"
    );
    $finished_tests = 'yes';
}

unless ( $config{'skip-deb'} ) {
    unless ( $config{'skip-pbuilder'} ) {
        print_log("Updating pbuilder...");
        run_cmd("sudo pbuilder update 2>&1");
        warn colored( "Error updating pbuilder. Continuing anyway.",
            'bold red' )
          if ($?);
    }

    $ENV{DEBEMAIL}    = $config{'maintainer-email'};
    $ENV{DEBFULLNAME} = $config{'maintainer-name'};

    my $extra_args = '';
    $extra_args = '--noautoversion' unless ( $config{'autoversion'} );
    shell_task(
        "Building packages",
"debian/build-git-snapshot --distribution=$config{'branch'} -r $config{'build-result'} -v $config{'version'} $extra_args 2>&1"
    );

    fail('Building package')
      unless $output =~
          m#^dpkg-deb: building package `koha-common' in `[^'`/]*/([^']*)'.$#m;
    $config{'package'} = "$config{'build-result'}/$1";

    fail('Building package') unless ( -f $config{'package'} );

    $built_packages = 'yes';
}

unless ( $config{'skip-tgz'} ) {
    print_log("Preparing release tarball...");

    shell_task(
        "Creating archive",
"git archive --format=tar --prefix=koha-$config{'version'}/ $config{'branch'} | gzip > $config{'tarball'}",
        1
    );

    $built_tarball = 'yes';

    shell_task( "Signing archive", "gpg -sb $config{'tarball'}", 1 )
      if ( $config{'sign'} );

    shell_task( "md5summing archive",
        "md5sum $config{'tarball'} > $config{'tarball'}.MD5", 1 );

    if ( $config{'sign'} ) {
        shell_task( "Signing md5sum",
            "gpg --clearsign $config{'tarball'}.MD5", 1 );
        $signed_tarball = 'yes';
    }
}

unless ( $config{'skip-rnotes'} || $config{'use-dist-rnotes'} ) {
    shell_task(
        "Generating release notes",
"$reltools/get_bugs.pl -r $config{'rnotes'} -v $config{'version'} --verbose 2>&1"
    );
}

unless ( $config{'skip-deb'} || $config{'skip-install'} ) {
    shell_task( "Installing package...",
        "sudo dpkg -i $config{'package'} 2>&1" );
    run_cmd('sudo koha-remove pkgrel  2>&1');

    open( my $koha_sites, '>', '/tmp/koha-sites.conf' );
    print $koha_sites <<EOF;
OPACPORT=9003
INTRAPORT=9004
EOF
    close $koha_sites;
    run_cmd('sudo mv /tmp/koha-sites.conf /etc/koha/koha-sites.conf');

    for my $flavour (@marcflavours) {
        my $lflavour = lc $flavour;
        print_log("Installing from package for $flavour...");

        shell_task( "Running koha-create for $flavour",
            "sudo koha-create --marcflavor=$lflavour --create-db pkgrel 2>&1",
            1 );

        unless ( $config{'skip-webinstall'} ) {
            my $pkg_user =
`sudo xmlstarlet sel -t -v 'yazgfs/config/user' '/etc/koha/sites/pkgrel/koha-conf.xml'`;
            my $pkg_pass =
`sudo xmlstarlet sel -t -v 'yazgfs/config/pass' '/etc/koha/sites/pkgrel/koha-conf.xml'`;
            chomp $pkg_user;
            chomp $pkg_pass;
            my $harness_args = {
                test_args => [
                    "http://localhost:9004", "http://localhost:9003",
                    "$flavour",              "$pkg_user",
                    "$pkg_pass"
                ]
            };
            tap_task( "Running webinstaller for $flavour",
                1, $harness_args, "$reltools/install-fresh.pl" );

            push @tested_package_installs, $flavour;

            clean_pkg_webinstall();
        }
    }
}

if ( $config{'sign'} && !$config{'skip-deb'} ) {
    shell_task( "Signing packages",
        "debsign $config{'build-result'}/*.changes" );
    $signed_packages = 'yes';
}

if ( $config{'deploy'} && !$config{'skip-deb'} ) {
    shell_task( "Importing packages to apt repo",
        "dput koha $config{'build-result'}/*.changes" );
    $deployed = 'yes';
}

unless ( $config{'skip-tgz'} || $config{'skip-install'} ) {
    $drh = DBI->install_driver("mysql");
    for my $flavour (@marcflavours) {
        my $lflavour = lc $flavour;
        print_log("Installing from tarball for $flavour...");
        $ENV{INSTALL_BASE}     = "$config{'build-result'}/fresh/koha";
        $ENV{DESTDIR}          = "$config{'build-result'}/fresh";
        $ENV{KOHA_CONF_DIR}    = "$config{'build-result'}/fresh/etc";
        $ENV{ZEBRA_CONF_DIR}   = "$config{'build-result'}/fresh/etc/zebradb";
        $ENV{PAZPAR2_CONF_DIR} = "$config{'build-result'}/fresh/etc/pazpar2";
        $ENV{ZEBRA_LOCK_DIR} = "$config{'build-result'}/fresh/var/lock/zebradb";
        $ENV{ZEBRA_DATA_DIR} = "$config{'build-result'}/fresh/var/lib/zebradb";
        $ENV{ZEBRA_RUN_DIR}  = "$config{'build-result'}/fresh/var/run/zebradb";
        $ENV{LOG_DIR}        = "$config{'build-result'}/fresh/var/log";
        $ENV{INSTALL_MODE}   = "standard";
        $ENV{DB_TYPE}        = "mysql";
        $ENV{DB_HOST}        = "localhost";
        $ENV{DB_NAME}        = "$config{'database'}";
        $ENV{DB_USER}        = "$config{'user'}";
        $ENV{DB_PASS}        = "$config{'password'}";
        $ENV{INSTALL_ZEBRA}  = "yes";
        $ENV{INSTALL_SRU}    = "no";
        $ENV{INSTALL_PAZPAR2}     = "no";
        $ENV{ZEBRA_MARC_FORMAT}   = "$lflavour";
        $ENV{ZEBRA_LANGUAGE}      = "en";
        $ENV{ZEBRA_USER}          = "kohauser";
        $ENV{ZEBRA_PASS}          = "zebrastripes";
        $ENV{KOHA_USER}           = "`id -u -n`";
        $ENV{KOHA_GROUP}          = "`id -g -n`";
        $ENV{PERL_MM_USE_DEFAULT} = "1";
        mkdir "$config{'build-result'}/fresh";
        shell_task( "Untarring tarball for $flavour",
            "tar zxvf $config{'tarball'} -C /tmp 2>&1", 1 );
        chdir "/tmp/koha-$config{'version'}";

        shell_task( "Running perl Makefile.PL for $flavour",
            "perl Makefile.PL 2>&1", 1 );

        shell_task( "Running make for $flavour...", "make 2>&1", 1 );

        shell_task( "Running make test for $flavour...", "make test 2>&1", 1 );

        shell_task( "Running make install for $flavour...",
            "make install 2>&1", 1 );

        run_cmd(
"sed -i -e 's/<VirtualHost 127.0.1.1:80>/<VirtualHost *:9001>/' -e 's/<VirtualHost 127.0.1.1:8080>/<VirtualHost *:9002>/' $config{'build-result'}/fresh/etc/koha-httpd.conf"
        );

        unless ( $config{'skip-webinstall'} ) {
            clean_tgz_webinstall();
            print_log(" Creating database for $flavour...");
            $drh->func( 'createdb', $config{'database'}, 'localhost',
                $config{'user'}, $config{'password'}, 'admin' )
              or fail("Creating database for $flavour");

            shell_task(
                "Adding to sites-available for $flavour",
"sudo ln -s $config{'build-result'}/fresh/etc/koha-httpd.conf /etc/apache2/sites-available/release-fresh 2>&1",
                1
            );

            shell_task( "Enabling site for $flavour",
                "sudo a2ensite release-fresh 2>&1", 1 );

            shell_task( "Restarting Apache for $flavour",
                "sudo apache2ctl restart 2>&1", 1 );

            my $harness_args = {
                test_args => [
                    "http://localhost:9002", "http://localhost:9001",
                    "$flavour",              "$config{'user'}",
                    "$config{'password'}"
                ]
            };
            tap_task( "Running webinstaller for $flavour",
                1, $harness_args, "$reltools/install-fresh.pl" );

            clean_tgz_webinstall();
            clean_tgz();
            push @tested_tarball_installs, $flavour;
        }
        else {
            clean_tgz();
        }

    }
}

if ( $config{'tag'} ) {
    my $tag_action = $config{'sign'} ? '-s' : '-a';
    shell_task(
        "Tagging current commit",
"git tag $tag_action -m 'Koha release $config{'version'}' v$config{'version'} 2>&1"
    );
    $tagged = 'yes';
}

generate_email();

if ( $config{'clean'} ) {
    clean_tgz_webinstall();
    clean_tgz();
    remove_tree( $config{'build-result'} );
    $cleaned = 'yes';
}

success();

sub clean_tgz_webinstall {
    print_log(" Cleaning up tarball install...");
    $drh->func( 'dropdb', $config{'database'}, 'localhost', $config{'user'},
        $config{'password'}, 'admin' );
    run_cmd("sudo a2dissite release-fresh 2>&1");
    run_cmd("sudo apache2ctl restart 2>&1");
    run_cmd("sudo rm /etc/apache2/sites-available/release-fresh 2>&1");
}

sub clean_tgz {
    chdir( $config{'kohaclone'} );
    remove_tree( "/tmp/koha-$config{'version'}",
        "$config{'build-result'}/fresh" );
}

sub clean_pkg_webinstall {
    shell_task( "Cleaning up package install",
        "sudo koha-remove pkgrel  2>&1", 1 );
}

sub summary {
    my $endtime = time();
    my $totaltime = ceil( ( $endtime - $starttime ) * 1000 );
    $starttime = strftime( '%D %T', localtime($starttime) );
    $endtime   = strftime( '%D %T', localtime($endtime) );
    my $skipped                = '';
    my $tested_tarball_install = 'no';
    my $tested_package_install = 'no';
    $tested_tarball_install = join( ', ', @tested_tarball_installs )
      if ( scalar(@tested_tarball_installs) );
    $tested_package_install = join( ', ', @tested_package_installs )
      if ( scalar(@tested_package_installs) );

    foreach my $key ( sort keys %config ) {
        if ( $key =~ m/^skip-([a-z]+)$/ ) {
            $skipped .= ", $1" if ( $config{$key} );
        }
    }
    $skipped =~ s/^, //;
    $config{'package'} = 'none'
      unless ( -s $config{'package'} && not $config{'skip-deb'} );
    $config{'tarball'} = 'none'
      unless ( -s $config{'tarball'} && not $config{'skip-tgz'} );
    $config{'rnotes'} = 'none'
      unless ( -s $config{'rnotes'} && not $config{'skip-rnotes'} );
    return if $config{'quiet'} > 1;
    print <<_SUMMARY_;

Release test report
=======================================================
Branch:                 $config{'branch'}
Version:                $config{'version'}
Maintainer:             $config{'maintainer-name'} <$config{'maintainer-email'}>
Run started at:         $starttime
Run ended at:           $endtime
Total run time:         $totaltime ms
Skipped:                $skipped
Finished tests:         $finished_tests
Built packages:         $built_packages
Tested package install: $tested_package_install
Deployed packages:      $deployed
Signed packages:        $signed_packages
Built tarball:          $built_tarball
Tested tarball install: $tested_tarball_install
Signed tarball:         $signed_tarball
Tagged git repository:  $tagged
Cleaned:                $cleaned
Tarball file:           $config{'tarball'}
Package file:           $config{'package'}
Release notes:          $config{'rnotes'}
E-mail file:            $config{'email-file'}
_SUMMARY_
}

sub success {
    summary();
    print colored( "Successfully finished release test", 'green' ), "\n"
      unless $config{'quiet'} > 1;

    exit 0;
}

sub fail {
    my $component = shift;
    my $callback  = shift;

    print colored( $component, 'bold red' ),
      colored( " failed in release test", 'red' ), "\n"
      unless $config{'quiet'} > 1;

    summary();
    print colored( $component, 'bold red' ),
      colored( " failed in release test", 'red' ), "\n"
      unless $config{'quiet'} > 1;

    if ($output) {
        open( my $errorlog, ">", "$config{'build-result'}/errors.log" )
          or die "Unable to open error log for writing";
        print $errorlog $output;
        close($errorlog);
    }

    print colored( "Error report at $config{'build-result'}/errors.log",
        'red' ), "\n"
      unless $config{'quiet'} > 1;

    $callback->() if ( ref $callback eq 'CODE' );

    exit 1;
}

sub print_log {
    print @_, "\n" unless $config{'quiet'};
}

sub tap_dir {
    my $directory = shift;
    my @tests;

    opendir( DIR, $directory );

    while ( my $file = readdir(DIR) ) {

        # We only want files
        next unless ( -f "$directory/$file" );

        # Use a regular expression to find files ending in .t
        next unless ( $file =~ m/\.t$/ );
        push @tests, "$directory/$file";
    }
    return sort @tests;
}

sub run_cmd {
    my $command = shift;
    print colored( "> $command\n", 'cyan' ) if ( $config{'verbose'} >= 1 );
    my $pid = open( my $outputfh, "-|", "$command" )
      or die "Unable to run $command\n";
    while (<$outputfh>) {
        print $_ if ( $config{'verbose'} >= 2 );
        $output .= $_;
    }
    close($outputfh);
}

sub shell_task {
    my $message = shift;
    my $command = shift;
    my $callback;
    $callback = pop @_ if ( $#_ && ref $_[$#_] eq 'CODE' );
    my $subtask = shift || 0;
    my $logmsg = ( ' ' x $subtask ) . $message;
    print_log("$logmsg...");
    $output = '';
    run_cmd($command);
    fail( $message, $callback ) if ($?);
}

sub tap_task {
    my $message      = shift;
    my $subtask      = shift;
    my $harness_args = shift;
    my $callback;
    $callback = pop @_ if ( ref $_[$#_] eq 'CODE' );
    my @tests  = @_;
    my $logmsg = ( ' ' x $subtask ) . $message;

    if ( $config{'verbose'} ) {
        $harness_args->{'verbosity'} = 1;
    }
    elsif ( $config{'quiet'} ) {
        $harness_args->{'verbosity'} = -1;
    }
    $harness_args->{'lib'}   = [ $config{'kohaclone'} ];
    $harness_args->{'merge'} = 1;

    print_log("$logmsg...");

    if ( $config{'verbose'} >= 1 ) {
        my $command = 'prove ';
        foreach my $test (@tests) {
            $command .= "$test ";
        }
        print colored( "> $command\n", 'cyan' );
    }

    my $pid = open( my $testfh, '-|' ) // die "Can't fork to run tests: $!\n";
    if ($pid) {
        while (<$testfh>) {
            print $_ if ( $config{'verbose'} >= 2 );
            $output .= $_;
        }
        waitpid( $pid, 0 );
        fail( $message, $callback ) if ($?);
        close($testfh);
    }
    else {
        my $harness    = TAP::Harness->new($harness_args);
        my $aggregator = $harness->runtests(@tests);
        exit 1 if $aggregator->failed;
        exit 0;
    }
}

sub process_tt_task {
    my $message  = shift;
    my $subtask  = shift;
    my $template = shift;
    my $args     = shift;
    my $logmsg   = ( ' ' x $subtask ) . $message;

    print_log("$logmsg...");

    my $tt = Template->new(
        {
            INCLUDE_PATH => "$reltools:$config{'build-result'}",
            ABSOLUTE     => 1,
        }
    );
    my $output;
    $tt->process( $template, $args, \$output ) || fail($message);
    return $output;
}

sub generate_email {
    my $content = process_tt_task(
        'Generating e-mail',
        0,
        $config{'email-template'},
        { VERSION => $config{'version'}, RELNOTES => $config{'rnotes'} }
    );
    $content =~ s/^####.*$//m;
    my $msg = MIME::Lite->new(
        From    => $config{'maintainer-email'},
        To      => $config{'email-recipients'},
        Subject => $config{'email-subject'},
        Data    => $content,
    );
    open( my $emailfh, ">", $config{'email-file'} );
    $msg->print();
    close($emailfh);
}

sub interrupt {
    undef $SIG{INT};
    warn "**** YOU INTERRUPTED THE SCRIPT ****\n";
    summary();
    die "**** YOU INTERRUPTED THE SCRIPT ****\n";
}

=head1 NAME

release-tool.pl

=head1 SYNOPSIS

  release-tool.pl
  release-tool.pl --version 3.06.05

=head1 DESCRIPTION

This script takes care of most of the Koha release process, as it is
done by Jared Camins-Esakov and C & P Bibliography Services. This may
not perfectly meet the needs of other Release Maintainers and/or
organizations.

=over 8

=item B<--help>

Prints this help

=item B<--quiet, -q>

Don't display any status information while running. When specified
twice, also suppress the summary.

=item B<--verbose, -v>

Provide verbose diagnostic information

=item B<--sign, -s>

Sign the tarball and package and tag (if created)

=item B<--deploy, -d>

Deploy the package to the apt repository

=item B<--tag, -g>

Tag the git repository

=item B<--clean, -c>

Delete all the files created in the course of the test

=item B<--release>

Equivalent to I<--sign --deploy --tag --tarball=koha-${VERSION}.tar.gz>

=item B<--skip-THING>

Skip THING. Currently the following can be skipped:

=over 4

=item B<tests>
Unit tests

=item B<deb>
Debian package-related tasks

=item B<tgz>
Tarball-related tasks

=item B<install>
Installation-related tasks

=item B<marc21>
MARC21 instance installation

=item B<unimarc>
UNIMARC instance installation

=item B<normarc>
NORMARC instance installation

=item B<webinstall>
Running the webinstaller

=item B<pbuilder>
Updating the pbuilder environment

=item B<rnotes>
Generating release notes

=back


=item B<--database>

Name of the MySQL database to use for tarball installs. Defaults to koharel

=item B<--user>

Name of the MySQL user for tarball installs. Defaults to koharel

=item B<--password>

Name of the MySQL password for tarball installs. Defaults to koharel

=item B<--kohaclone, -k>

Kohaclone directory. Defaults to the current working directory

=item B<--build-result, -b>

Result to put the output into. Defaults to ~/releases/[branch]/[version]

=item B<--tarball, -t>

The name of the tarball file to generate

=item B<--branch>

The name of the branch or distribution in use. Defaults to current git branch

=item B<--version>

The version of Koha that is being created. Defaults to the version listed in
kohaversion.pl

=item B<--autoversion, -a>

Automatically include the git commit id and timestamp in the package version

=item B<--maintainer-name>

The name of the maintainer. Defaults to global git config user.name

=item B<--maintainer-email>

The e-mail address of the maintainer. Defaults to the value of git config
--global user.email

=back

=head1 DPUT CONFIGURATION

In order for the deploy step to work, you will need to have a signed apt repository
set up. Once you have set up your repo, put the following in your  ~/.dput.cf:

    [koha]
    method = local
    incoming = /home/apt/koha/incoming
    run_dinstall = 0
    post_upload_command = reprepro -b /home/apt/koha processincoming default

=head1 SEE ALSO

L<dch(1)>, L<dput(1)>, L<pbuilder(8)>, L<reprepro(1)>

=head1 AUTHOR

Jared Camins-Esakov <jcamins@cpbibliography.com>

=cut
