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

$SIG{INT} = \&interrupt;

sub usage {
    pod2usage( -verbose => 2 );
    exit;
}

$| = 1;
$Term::ANSIColor::AUTORESET = 1;

# command-line parameters
my $quiet           = 0;
my $want_help       = 0;
my $full            = 0;
my $deploy          = 0;
my $tag             = 0;
my $clean           = 0;
my $autoversion     = 0;
my $database        = $ENV{KOHA_DATABASE};
my $db_user         = $ENV{KOHA_USER};
my $db_pass         = $ENV{KOHA_PASS};
my $build_result    = '';
my $pkg_file        = '';
my $tgz_file        = '';
my $rnotes_file     = '';
my $kohaclone       = '';
my $verbose         = 0;
my $deployed        = 'no';
my $signed_tarball  = 'no';
my $signed_packages = 'no';
my $tagged          = 'no';
my $cleaned         = 'no';
my $skipped         = '';
my $finished_tests  = 'no';
my $built_tarball   = 'no';
my $built_packages  = 'no';
my $sign            = 0;
my %skip;
my $package;
my $branch;
my $version;
my $output;
my $maintainername;
my $maintaineremail;
my $drh;
my @tested_tarball_installs;
my @tested_package_installs;

my $options = GetOptions(
    'q|quiet+'           => \$quiet,
    'h|help'             => \$want_help,
    's|sign'             => \$sign,
    'd|deploy'           => \$deploy,
    'g|tag'              => \$tag,
    'c|clean'            => \$clean,
    'a|autoversion'      => \$autoversion,
    'v|verbose+'         => \$verbose,
    'full'               => \$full,
    'skip-tests'         => \$skip{tests},
    'skip-deb'           => \$skip{deb},
    'skip-tgz'           => \$skip{tgz},
    'skip-install'       => \$skip{install},
    'skip-marc21'        => \$skip{marc21},
    'skip-unimarc'       => \$skip{unimarc},
    'skip-normarc'       => \$skip{normarc},
    'skip-webinstall'    => \$skip{webinstall},
    'skip-pbuilder'      => \$skip{pbuilder},
    'skip-rnotes'        => \$skip{rnotes},
    'database=s'         => \$database,
    'user=s'             => \$db_user,
    'password=s'         => \$db_pass,
    'k|kohaclone=s'      => \$kohaclone,
    'b|build-result=s'   => \$build_result,
    't|tarball=s'        => \$tgz_file,
    'r|rnotes=s'         => \$rnotes_file,
    'branch=s'           => \$branch,
    'version=s'          => \$version,
    'maintainer-name=s'  => \$maintainername,
    'maintainer-email=s' => \$maintaineremail,
);

binmode( STDOUT, ":utf8" );

if ( $want_help ) {
    usage();
}

if ( $full ) {
    $sign = 1;
    $deploy = 1;
    $tag = 1;
}

$database = 'koharel' unless ($database);
$db_user  = 'koharel' unless ($db_user);
$db_pass  = 'koharel' unless ($db_pass);

my $starttime = time();

my $reltools = File::Spec->rel2abs(dirname(__FILE__));

$kohaclone = File::Spec->rel2abs(File::Spec->curdir()) unless (-d $kohaclone);

my @marcflavours;
push @marcflavours, 'MARC21' unless $skip{marc21};
push @marcflavours, 'UNIMARC' unless $skip{unimarc};
push @marcflavours, 'NORMARC' unless $skip{normarc};

chomp($branch = `git branch | grep '*' | sed -e 's/^* //' -e 's#/#-#'`) unless $branch;
chomp($version = `grep 'VERSION = ' kohaversion.pl | sed -e "s/^[^']*'//" -e "s/';//"`) unless $version;
chomp($maintainername  = `git config --global --get user.name`) unless $maintainername;
chomp($maintaineremail = `git config --global --get user.email`) unless $maintaineremail;

$build_result = "$ENV{HOME}/releases/$branch/$version" unless ($build_result);
make_path($build_result);

opendir(DIR, $build_result);

while (my $file = readdir(DIR)) {
    # We only want files
    next unless (-f "$build_result/$file");

    unlink "$build_result/$file";
}

$ENV{TEST_QA} = 1;

$tgz_file = "$build_result/koha-$branch-$version.tar.gz" unless $tgz_file;
$rnotes_file = "$build_result/release_notes.txt" unless $rnotes_file;
unlink $tgz_file;
unlink $rnotes_file;
unlink "$build_result/errors.log";

print_log(colored("Starting release test at " . strftime('%D %T', localtime($starttime)), 'blue'));
print_log("\tBranch:  $branch\n\tVersion: $version\n");

unless ($skip{tests}) {
    tap_task("Running unit tests", 0, undef, tap_dir("$kohaclone/t"),
        tap_dir("$kohaclone/t/db_dependent"),
        tap_dir("$kohaclone/t/db_dependent/Labels"),
        "$kohaclone/xt/author/icondirectories.t",
        "$kohaclone/xt/author/podcorrectness.t",
        "$kohaclone/xt/author/translatable-templates.t",
        "$kohaclone/xt/author/valid-templates.t",
        "$kohaclone/xt/permissions.t",
        "$kohaclone/xt/tt_valid.t"
        );
        $finished_tests = 'yes';
}
    
unless ($skip{deb}) {
    unless ($skip{pbuilder}) {
        print_log("Updating pbuilder...");
        run_cmd("sudo pbuilder update 2>&1");
        warn colored("Error updating pbuilder. Continuing anyway.", 'bold red') if ($?);
    }

    $ENV{DEBEMAIL} = $maintaineremail;
    $ENV{DEBFULLNAME} = $maintainername;

    my $extra_args = '';
    $extra_args = '--noautoversion' unless ($autoversion);
    shell_task("Building packages", "debian/build-git-snapshot --distribution=$branch -r $build_result -v $version $extra_args 2>&1");
    
    fail('Building package') unless $output =~ m#^dpkg-deb: building package `koha-common' in `[^'`/]*/([^']*)'.$#m;
    $pkg_file = "$build_result/$1";

    fail('Building package') unless (-f $pkg_file);

    $built_packages = 'yes';
}

unless ($skip{tgz}) {
    print_log("Preparing release tarball...");

    shell_task("Creating archive", "git archive --format=tar --prefix=koha-$version/ $branch | gzip > $tgz_file", 1);

    $built_tarball = 'yes';

    shell_task("Signing archive", "gpg -sb $tgz_file", 1) if ($sign);

    shell_task("md5summing archive", "md5sum $tgz_file > $tgz_file.MD5", 1);

    if ($sign) {
        shell_task("Signing md5sum", "gpg --clearsign $tgz_file.MD5", 1);
        $signed_tarball = 'yes';
    }
}

unless ($skip{deb} || $skip{install}) {
    shell_task("Installing package...", "sudo dpkg -i $pkg_file 2>&1");
    run_cmd('sudo koha-remove pkgrel  2>&1');

    open (my $koha_sites, '>', '/tmp/koha-sites.conf');
    print $koha_sites <<EOF;
OPACPORT=9003
INTRAPORT=9004
EOF
    close $koha_sites;
    run_cmd('sudo mv /tmp/koha-sites.conf /etc/koha/koha-sites.conf');

    for my $flavour (@marcflavours) {
        my $lflavour = lc $flavour;
        print_log("Installing from package for $flavour...");

        shell_task("Running koha-create for $flavour", "sudo koha-create --marcflavor=$lflavour --create-db pkgrel 2>&1", 1);

        unless ($skip{webinstall}) {
            my $pkg_user = `sudo xmlstarlet sel -t -v 'yazgfs/config/user' '/etc/koha/sites/pkgrel/koha-conf.xml'`;
            my $pkg_pass = `sudo xmlstarlet sel -t -v 'yazgfs/config/pass' '/etc/koha/sites/pkgrel/koha-conf.xml'`;
            chomp $pkg_user;
            chomp $pkg_pass;
            my $harness_args = { test_args => [ "http://localhost:9004",
                                                "http://localhost:9003",
                                                "$flavour",
                                                "$pkg_user",
                                                "$pkg_pass" ]
            };
            tap_task("Running webinstaller for $flavour", 1, $harness_args, "$reltools/install-fresh.pl");

            push @tested_package_installs, $flavour;
            
            clean_pkg_webinstall();
        }
    }
}

if ($sign && !$skip{deb}) {
    shell_task("Signing packages", "debsign $build_result/*.changes");
    $signed_packages = 'yes';
}

if ($deploy && !$skip{deb}) {
    shell_task("Importing packages to apt repo", "dput koha $build_result/*.changes");
    $deployed = 'yes';
}

unless ($skip{tgz} || $skip{install}) {
    $drh= DBI->install_driver("mysql");
    for my $flavour (@marcflavours) {
        my $lflavour = lc $flavour;
        print_log("Installing from tarball for $flavour...");
        $ENV{INSTALL_BASE}="$build_result/fresh/koha";
        $ENV{DESTDIR}="$build_result/fresh";
        $ENV{KOHA_CONF_DIR}="$build_result/fresh/etc";
        $ENV{ZEBRA_CONF_DIR}="$build_result/fresh/etc/zebradb";
        $ENV{PAZPAR2_CONF_DIR}="$build_result/fresh/etc/pazpar2";
        $ENV{ZEBRA_LOCK_DIR}="$build_result/fresh/var/lock/zebradb";
        $ENV{ZEBRA_DATA_DIR}="$build_result/fresh/var/lib/zebradb";
        $ENV{ZEBRA_RUN_DIR}="$build_result/fresh/var/run/zebradb";
        $ENV{LOG_DIR}="$build_result/fresh/var/log";
        $ENV{INSTALL_MODE}="standard";
        $ENV{DB_TYPE}="mysql";
        $ENV{DB_HOST}="localhost";
        $ENV{DB_NAME}="$database";
        $ENV{DB_USER}="$db_user";
        $ENV{DB_PASS}="$db_pass";
        $ENV{INSTALL_ZEBRA}="yes";
        $ENV{INSTALL_SRU}="no";
        $ENV{INSTALL_PAZPAR2}="no";
        $ENV{ZEBRA_MARC_FORMAT}="$lflavour";
        $ENV{ZEBRA_LANGUAGE}="en";
        $ENV{ZEBRA_USER}="kohauser";
        $ENV{ZEBRA_PASS}="zebrastripes";
        $ENV{KOHA_USER}="`id -u -n`";
        $ENV{KOHA_GROUP}="`id -g -n`";
        $ENV{PERL_MM_USE_DEFAULT}="1";
        mkdir "$build_result/fresh";
        shell_task("Untarring tarball for $flavour", "tar zxvf $tgz_file -C /tmp 2>&1", 1);
        chdir "/tmp/koha-$version";

        shell_task("Running perl Makefile.PL for $flavour", "perl Makefile.PL 2>&1", 1);

        shell_task("Running make for $flavour...", "make 2>&1", 1);

        shell_task("Running make test for $flavour...", "make test 2>&1", 1);

        shell_task("Running make install for $flavour...", "make install 2>&1", 1);

        run_cmd("sed -i -e 's/<VirtualHost 127.0.1.1:80>/<VirtualHost *:9001>/' -e 's/<VirtualHost 127.0.1.1:8080>/<VirtualHost *:9002>/' $build_result/fresh/etc/koha-httpd.conf");
     
        unless ($skip{webinstall}) {
            clean_tgz_webinstall();
            print_log(" Creating database for $flavour...");
            $drh->func('createdb', $database, 'localhost', $db_user, $db_pass, 'admin') or fail("Creating database for $flavour");

            shell_task("Adding to sites-available for $flavour", "sudo ln -s $build_result/fresh/etc/koha-httpd.conf /etc/apache2/sites-available/release-fresh 2>&1", 1);

            shell_task("Enabling site for $flavour", "sudo a2ensite release-fresh 2>&1", 1);

            shell_task("Restarting Apache for $flavour", "sudo apache2ctl restart 2>&1", 1);

            my $harness_args = { test_args => [ "http://localhost:9002",
                                                "http://localhost:9001",
                                                "$flavour",
                                                "$db_user",
                                                "$db_pass" ]
            };
            tap_task("Running webinstaller for $flavour", 1, $harness_args, "$reltools/install-fresh.pl");

            clean_tgz_webinstall();
            clean_tgz();
            push @tested_tarball_installs, $flavour;
        } else {
            clean_tgz();
        }
     
    }
}

if ($tag) {
    my $tag_action = $sign ? '-s' : '-a';
    shell_task("Tagging current commit", "git tag $tag_action -m 'Koha release $version' v$version 2>&1");
    $tagged = 'yes';
}

unless ($skip{rnotes}) {
    shell_task("Generating release notes", "$reltools/get_bugs.pl -r $rnotes_file -v $version --verbose 2>&1");
}

if ($clean) {
    clean_tgz_webinstall();
    clean_tgz();
    remove_tree($build_result);
    $cleaned = 'yes';
}

success();

sub clean_tgz_webinstall {
    print_log(" Cleaning up tarball install...");
    $drh->func('dropdb', $database, 'localhost', $db_user, $db_pass, 'admin');
    run_cmd("sudo a2dissite release-fresh 2>&1");
    run_cmd("sudo apache2ctl restart 2>&1");
    run_cmd("sudo rm /etc/apache2/sites-available/release-fresh 2>&1");
}

sub clean_tgz {
    chdir($kohaclone);
    remove_tree("/tmp/koha-$version", "$build_result/fresh");
}

sub clean_pkg_webinstall {
    shell_task("Cleaning up package install", "sudo koha-remove pkgrel  2>&1", 1);
}

sub summary {
    my $endtime = time();
    my $totaltime = ceil (($endtime - $starttime) * 1000);
    $starttime = strftime('%D %T', localtime($starttime));
    $endtime = strftime('%D %T', localtime($endtime));
    my $skipped = '';
    my $tested_tarball_install = 'no';
    my $tested_package_install = 'no';
    $tested_tarball_install = join(', ', @tested_tarball_installs) if (scalar(@tested_tarball_installs));
    $tested_package_install = join(', ', @tested_package_installs) if (scalar(@tested_package_installs));
    foreach my $key (sort keys %skip) {
        $skipped .= ", $key" if ($skip{$key});
    }
    $skipped =~ s/^, //;
    $pkg_file = 'none' unless (-s $pkg_file && not $skip{deb});
    $tgz_file = 'none' unless (-s $tgz_file && not $skip{tgz});
    $rnotes_file = 'none' unless (-s $rnotes_file && not $skip{rnotes});
    return if $quiet > 1;
    print <<_SUMMARY_;

Release test report
=======================================================
Branch:                 $branch
Version:                $version
Maintainer:             $maintainername <$maintaineremail>
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
Tarball file:           $tgz_file
Package file:           $pkg_file
Release notes:          $rnotes_file
_SUMMARY_
}

sub success {
    summary();
    print colored("Successfully finished release test", 'green'), "\n" unless $quiet > 1;

    exit 0;
}

sub fail {
    my $component = shift;
    my $callback = shift;

    print colored($component, 'bold red'), colored(" failed in release test", 'red'), "\n" unless $quiet > 1;

    summary();
    print colored($component, 'bold red'), colored(" failed in release test", 'red'), "\n" unless $quiet > 1;

    if ($output) {
        open(my $errorlog, ">", "$build_result/errors.log") or die "Unable to open error log for writing";
        print $errorlog $output;
        close($errorlog);
    }

    print colored("Error report at $build_result/errors.log", 'red'), "\n" unless $quiet > 1;

    $callback->() if (ref $callback eq 'CODE');

    exit 1;
}

sub print_log {
    print @_, "\n" unless $quiet;
}

sub tap_dir {
    my $directory = shift;
    my @tests;

    opendir(DIR, $directory);

    while (my $file = readdir(DIR)) {
        # We only want files
        next unless (-f "$directory/$file");

        # Use a regular expression to find files ending in .t
        next unless ($file =~ m/\.t$/);
        push @tests, "$directory/$file";
    }
    return sort @tests;
}

sub run_cmd {
    my $command = shift;
    print colored("> $command\n", 'cyan') if ($verbose >= 1);
    my $pid = open(my $outputfh, "-|", "$command") or die "Unable to run $command\n";
    while (<$outputfh>) {
        print $_ if ($verbose >= 2);
        $output .= $_;
    }
    close ($outputfh);
}

sub shell_task {
    my $message = shift;
    my $command = shift;
    my $callback;
    $callback = pop @_ if ($#_ && ref $_[$#_] eq 'CODE');
    my $subtask = shift || 0;
    my $logmsg = (' ' x $subtask) . $message;
    print_log("$logmsg...");
    $output = '';
    run_cmd($command);
    fail($message, $callback) if ($?);
}

sub tap_task {
    my $message = shift;
    my $subtask = shift;
    my $harness_args = shift;
    my $callback;
    $callback = pop @_ if (ref $_[$#_] eq 'CODE');
    my @tests = @_;
    my $logmsg = (' ' x $subtask) . $message;

    if ($verbose) {
        $harness_args->{'verbosity'} = 1;
    } elsif ($quiet) {
        $harness_args->{'verbosity'} = -1;
    }
    $harness_args->{'lib'} = [ $kohaclone ];
    $harness_args->{'merge'} = 1;

    print_log("$logmsg...");

    if ($verbose >= 1) {
        my $command = 'prove ';
        foreach my $test (@tests) {
            $command .= "$test ";
        }
        print colored("> $command\n", 'cyan');
    }

    my $pid = open(my $testfh, '-|') // die "Can't fork to run tests: $!\n";
    if ($pid) {
        while (<$testfh>) {
            print $_ if ($verbose >= 2);
            $output .= $_;
        }
        waitpid($pid, 0);
        fail($message, $callback) if ($?);
        close($testfh);
    } else {
        my $harness = TAP::Harness->new( $harness_args );
        my $aggregator = $harness->runtests(@tests);
        exit 1 if $aggregator->failed;
        exit 0;
    }
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

dch(1), dput(1), pbuilder(8), reprepro(1)

=head1 AUTHOR

Jared Camins-Esakov <jcamins@cpbibliography.com>

=cut
