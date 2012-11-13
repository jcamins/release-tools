#!/usr/bin/perl -w

# release-tool.pl - script to manage the Koha release process
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

=cut

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
use Config::Simple;
use Net::OpenSSH;

$SIG{INT} = \&interrupt;

sub usage {
    pod2usage( -verbose => 2 );
    exit;
}

$|                          = 1;
$Term::ANSIColor::AUTORESET = 1;

my %defaults = (
    alert                => '',
    autoversion          => 0,
    branch               => '',
    'build-result'       => '',
    clean                => 0,
    deploy               => 0,
    'email-file'         => '',
    errorlog             => '',
    kohaclone            => '',
    'maintainer-email'   => '',
    'maintainer-name'    => '',
    package              => '',
    'post-deploy-script' => [ '' ],
    quiet                => 0,
    rnotes               => '',
    sign                 => 0,
    since                => '',
    'skip-deb'           => 0,
    'skip-install'       => 0,
    'skip-marc21'        => 0,
    'skip-normarc'       => 0,
    'skip-pbuilder'      => 0,
    'skip-rnotes'        => 0,
    'skip-stats'         => 0,
    'skip-tests'         => 0,
    'skip-tgz'           => 0,
    'skip-unimarc'       => 0,
    'skip-webinstall'    => 0,
    stats                => '',
    tag                  => 0,
    tarball              => '',
    'use-dist-rnotes'    => 0,
    verbose              => 0,
    version              => '',

    # database settings
    database => $ENV{KOHA_DATABASE} || 'koha',
    user     => $ENV{KOHA_USER}     || 'kohaadmin',
    password => $ENV{KOHA_PASS}     || 'katikoan',

    # announcement settings
    'email-template' => 'announcement.eml.tt',
    'email-recipients' =>
      'koha@lists.katipo.co.nz, koha-devel@lists.koha-community.org',
    'email-subject'    => "New Koha version",
    'website-template' => 'announcement.html.tt',
);

my $deployed        = 'no';
my $signed_tarball  = 'no';
my $signed_packages = 'no';
my $tagged          = 'no';
my $cleaned         = 'no';
my $pushed          = 'no';
my $skipped         = '';
my $finished_tests  = 'no';
my $built_tarball   = 'no';
my $built_packages  = 'no';
my $version_mismatch;
my $output;
my @tested_tarball_installs;
my @tested_package_installs;
my %cmdline;
my $config = new Config::Simple( syntax => 'http' );
my $log = '';
my $lxc_host = '';

=head2 General options

=over 8

=item B<--help>

Prints this help

=item B<--quiet, -q>

Don't display any status information while running. When specified
twice, also suppress the summary.

=item B<--verbose, -v>

Provide verbose diagnostic information

=item B<--config>

Read configuration settings from the specified file. Options set on the
command line will override options in the configuration file.

=back

=head2 Action control options

=over 8

=item B<--clean, -c>

Delete all the files created in the course of the test

=item B<--deploy, -d>

Deploy the package to the apt repository

=item B<--release>

Equivalent to I<--sign --deploy --tag --tarball=koha-${VERSION}.tar.gz>

=item B<--sign, -s>

Sign the tarball and package and tag (if created)

=item B<--tag, -g>

Tag the git repository

=item B<--push, -p>

Push the branch to the specified remote(s).

=item B<--skip-THING>

Most actions are performed automatically, unless the user requests that they
be skipped. Skip THING. Currently the following can be skipped:

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

=item B<stats>
Generating git statistics

=back

=back
=cut

=head2 Source description options

=over 8

=item B<--kohaclone, -k>

Kohaclone directory. Defaults to the current working directory

=item B<--branch>

The name of the branch or distribution in use. Defaults to current git branch

=item B<--version>

The version of Koha that is being created. Defaults to the version listed in
kohaversion.pl

=item B<--autoversion, -a>

Automatically include the git commit id and timestamp in the package version

=item B<--since>

Tag or commit from which to generate release notes and statistics. Defaults
to last tag on branch.

=back

=head2 Execution options

=over 8

=item B<--database>

Name of the MySQL database to use for tarball installs. Defaults to koharel

=item B<--user>

Name of the MySQL user for tarball installs. Defaults to koharel

=item B<--password>

Name of the MySQL password for tarball installs. Defaults to koharel

=item B<--maintainer-name>

The name of the maintainer. Defaults to global git config user.name

=item B<--maintainer-email>

The e-mail address of the maintainer. Defaults to the value of git config
--global user.email

=item B<--use-dist-rnotes>

Use the release notes included in the distribution. I<--rnotes> moust be
specified if this option is used.

=item B<--post-deploy-script>

Run the specified script at the end of the deploy phase with the summary
config file as an argument.

=back

=head2 Output options

=over 8

=item B<--build-result, -b>

Directory to put the output into. Defaults to ~/releases/[branch]/[version]

=item B<--errorlog>

File to store error information in. Defaults to [build-result]/errors.log

=item B<--rnotes, -r>

The name of the release notes file to generate or use (see I<--use-dist-rnotes>).
Defaults to [build-result]/release_notes.txt

=item B<--stats>

The base name of the files into which statistics should be placed.
Defaults to [build-result]/statistics (statistics will be generated
in .txt and .html format)

=item B<--tarball, -t>

The name of the tarball file to generate. Defaults to
[build-result]/koha-[branch]-[version].tar.gz

=item B<--alert>

E-mail address to which an an alert summarizing the result should be sent.

=item B<--email-template>

Template file for the release announcement e-mail. Defaults to
"announcement.eml.tt" in the same directory as this script

=item B<--bzlogin>

Your login on bugzilla. If provided, it will be used to retrieve
the comment 0 for each enhancement. This information will be
added in the release notes

=item B<--bzpassword>

Your password on bugzilla. Must be provided if you provide bzlogin

=back

=head2 Announcement options

=over 8

=item B<--email-recipients>

Who to generate the e-mail announcement for. Defaults to 
"koha@lists.katipo.co.nz, koha-devel@lists.koha-community.org"

=item B<--email-subject>

Subject of the generated e-mail announcement. Defaults to "New Koha version"

=item B<--email-file>

File to store the generated e-mail announcement in. Defaults to
[build-result]/announcement.eml

=item B<--email-template>

Template file for the release announcement e-mail. Defaults to
"announcement.eml.tt" in the same directory as this script

=back
=cut

my $options = GetOptions(
    \%cmdline,

    # General options
    'help|h',     'quiet|q+',
    'verbose|v+', 'config=s',

    # Action control options
    'clean|c', 'deploy|d',
    'push|p:s@', 'release',
    'sign|s', 'tag|g',
    'skip-tests',
    'skip-deb',        'skip-tgz',
    'skip-install',    'skip-marc21',
    'skip-unimarc',    'skip-normarc',
    'skip-webinstall', 'skip-pbuilder',
    'skip-rnotes',     'skip-stats',

    # Source description options
    'version=s', 'autoversion|a',
    'kohaclone|k=s',
    'branch=s', 'since=s',

    # Execution options
    'database=s',
    'user=s', 'password=s',
    'use-dist-rnotes',
    'maintainer-name=s', 'maintainer-email=s',
    'post-deploy-script=s@',

    # Output options
    'build-result|b=s', 'errorlog=s',
    'tarball|t=s',      'rnotes|r=s',
    'stats=s', 'alert=s',

    # Announcement options
    'email-file=s',
    'email-recipients=s', 'email-subject=s',
    'email-template=s',

    # Bugzilla options
    'bzlogin:s','bzpassword:s',
);

binmode( STDOUT, ":utf8" );

if ( $cmdline{help} ) {
    usage();
}

if ( defined( $cmdline{config} ) && -f File::Spec->rel2abs( $cmdline{config} ) )
{
    $config->read( $cmdline{config} );
}
foreach my $key ( keys %defaults ) {
    $config->param( $key, $defaults{$key} ) unless $config->param($key);
}
foreach my $key ( keys %cmdline ) {
    $config->param( $key, $cmdline{$key} );
}

my $starttime = time();

chdir $config->param('kohaclone')
  if ( $config->param('kohaclone') && -d $config->param('kohaclone') );

my $reltools = File::Spec->rel2abs( dirname(__FILE__) );

$config->param( 'kohaclone', File::Spec->rel2abs( File::Spec->curdir() ) )
  unless ( $config->param('kohaclone') && -d $config->param('kohaclone') );

$ENV{PERL5LIB} = $config->param('kohaclone');
my @marcflavours;
push @marcflavours, 'MARC21'  unless $config->param('skip-marc21');
push @marcflavours, 'UNIMARC' unless $config->param('skip-unimarc');
push @marcflavours, 'NORMARC' unless $config->param('skip-normarc');

set_default( 'branch', `git branch | grep '*' | sed -e 's/^* //' -e 's#/#-#'` );

my $kohaversion = `grep 'VERSION = ' kohaversion.pl | sed -e "s/^[^']*'//" -e "s/';//"`;
set_default( 'version', $kohaversion );

set_default( 'maintainer-name', `git config --global --get user.name` );

set_default( 'maintainer-email', `git config --global --get user.email` );

set_default( 'build-result',
        "$ENV{HOME}/releases/"
      . $config->param('branch') . '/'
      . $config->param('version') );

make_path( $config->param('build-result') );

opendir( DIR, $config->param('build-result') );

while ( my $file = readdir(DIR) ) {

    # We only want files
    $file = $config->param('build-result') . "$file";
    next unless ( -f $file );

    unlink $file;
}

$ENV{TEST_QA} = 1;

if ( $config->param('tarball') =~ m#/# ) {
    $config->param( 'tarball', '' )
      unless ( -d dirname( $config->param('tarball') ) );
}
elsif ( $config->param('tarball') ) {
    $config->param( 'tarball', build_result( $config->param('tarball') ) );
}

set_default( 'email-file', build_result('announcement.eml') );

set_default(
    'tarball',
    build_result(
            'koha-'
          . $config->param('branch') . '-'
          . $config->param('version')
          . '.tar.gz'
    )
);

set_default( 'rnotes', build_result('release_notes.txt') );

set_default( 'stats', build_result('statistics') );

my $lasttag = `git describe --abbrev=0`;
chomp $lasttag;

set_default( 'since', $lasttag );

set_default( 'errorlog', build_result('errors.log') );

unlink $config->param('tarball');
unlink $config->param('rnotes') unless $config->param('use-dist-rnotes');
unlink $config->param('errorlog');

print_log(
    colored(
        "Starting release test at "
          . strftime( '%D %T', localtime($starttime) ),
        'blue'
    )
);
print_log( "\tBranch:  "
      . $config->param('branch')
      . "\n\tVersion: "
      . $config->param('version')
      . "\n" );

unless ( index $config->param('version'), $kohaversion ) {
    $version_mismatch = 1;
}

unless ( $config->param('skip-tests') ) {
    tap_task(
        "Running unit tests",
        0,
        undef,
        tap_dir( $config->param('kohaclone') . '/t' ),
        tap_dir( $config->param('kohaclone') . '/t/db_dependent' ),
        tap_dir( $config->param('kohaclone') . '/t/db_dependent/Labels' ),
        $config->param('kohaclone') . '/xt/author/icondirectories.t',
        $config->param('kohaclone') . '/xt/author/podcorrectness.t',
        $config->param('kohaclone') . '/xt/author/translatable-templates.t',
        $config->param('kohaclone') . '/xt/author/valid-templates.t',
        $config->param('kohaclone') . '/xt/permissions.t',
        $config->param('kohaclone') . '/xt/tt_valid.t'
    );
    $finished_tests = 'yes';
}

unless ( $config->param('skip-deb') ) {
    unless ( $config->param('skip-pbuilder') ) {
        print_log("Updating pbuilder...");
        run_cmd("sudo pbuilder update --keyring '$reltools/debian.koha-community.org.gpg' 2>&1");
        warn colored( "Error updating pbuilder. Continuing anyway.",
            'bold red' )
          if ($?);
    }

    $ENV{DEBEMAIL}    = $config->param('maintainer-email');
    $ENV{DEBFULLNAME} = $config->param('maintainer-name');

    my $extra_args = '';
    $extra_args = ' --noautoversion' unless ( $config->param('autoversion') );
    shell_task(
        "Building packages",
        "debian/build-git-snapshot --distribution="
          . $config->param('branch') . " -r "
          . $config->param('build-result') . " -v "
          . $config->param('version')
          . "$extra_args 2>&1"
    );

    fail('Building package')
      unless $output =~
          m#^dpkg-deb: building package `koha-common' in `[^'`/]*/([^']*)'.$#m;
    $config->param( 'package', build_result($1) );

    fail('Building package') unless ( -f $config->param('package') );

    $built_packages = 'yes';
}

unless ( $config->param('skip-tgz') ) {
    print_log("Preparing release tarball...");

    shell_task(
        "Creating archive",
        'git archive --format=tar --prefix=koha-'
          . $config->param('version') . '/ '
          . $config->param('branch')
          . ' | gzip > '
          . $config->param('tarball'),
        1
    );

    $built_tarball = 'yes';

    shell_task( "Signing archive", "gpg -sb " . $config->param('tarball'), 1 )
      if ( $config->param('sign') );

    shell_task(
        "md5summing archive",
        "md5sum "
          . $config->param('tarball') . " > "
          . $config->param('tarball') . ".MD5",
        1
    );

    if ( $config->param('sign') ) {
        shell_task( "Signing md5sum",
            "gpg --clearsign " . $config->param('tarball') . ".MD5", 1 );
        $signed_tarball = 'yes';
    }

    if ( $config->param('deploy') ) {
        $config->param('staging', build_result('staging'));
        mkdir $config->param('staging');
        symlink $config->param('tarball'), $config->param('staging') . '/' . basename($config->param('tarball'));
        symlink $config->param('tarball') . '.MD5', $config->param('staging') . '/' . basename($config->param('tarball') . '.MD5');
        if ($signed_tarball) {
            symlink $config->param('tarball') . '.MD5.asc', $config->param('staging') .'/' .  basename($config->param('tarball') . '.MD5.asc');
            symlink $config->param('tarball') . '.sig', $config->param('staging') .'/' .  basename($config->param('tarball') . '.sig');
        }
    }
}

unless ( $config->param('skip-rnotes') || $config->param('use-dist-rnotes') ) {
    print_log("Generating release notes...");
    run_cmd(
        "$reltools/get_bugs.pl -r "
          . $config->param('rnotes') . " -t "
          . $config->param('since') . " -v "
          . $config->param('version')
          .($config->param('bzlogin')?" -u ".$config->param('bzlogin')." -p ".$config->param('bzpassword'):"")
          . " --verbose 2>&1"
          );
    warn colored( "Error generating release notes. Continuing anyway.",
            'bold red' ) if ($?);
}

system('which gitdm 2>&1 > /dev/null');
$config->param('skip-stats', 1) if $?;
unless ( $config->param('skip-stats') ) {
    shell_task(
        "Generating statistics",
        "git log -p -M " . $config->param('since')
          . "..HEAD | gitdm -b $reltools -c $reltools/gitdm.config -u -s -a -o "
          . $config->param('stats') . ".txt -h "
          . $config->param('stats') . ".html 2>&1"
    );
}

unless ( $config->param('skip-deb') || $config->param('skip-install') ) {
    for my $flavour (@marcflavours) {
        my $lflavour = lc $flavour;

        print_log("Installing from package for $flavour...");
        my ($lxc_ip, $ssh) = create_lxc();
        ssh_task( $ssh, "Downloading package...", "wget -nv http://10.0.3.1" . $config->param('package') . ' 2>&1', '', 1 );
        ssh_task( $ssh, "Installing package...", "sudo dpkg --no-debsig -i " . basename($config->param('package')) . ' 2>&1; sudo apt-get -y -f install 2>&1', '', 1 );
        ssh_task( $ssh, "Running koha-create for $flavour",
            "sudo koha-create --marcflavor=$lflavour --create-db pkgrel 2>&1", '',
            1 );

        unless ( $config->param('skip-webinstall') ) {
            my $pkg_user = $ssh->capture("sudo xmlstarlet sel -t -v 'yazgfs/config/user' '/etc/koha/sites/pkgrel/koha-conf.xml'");
            my $pkg_pass = $ssh->capture("sudo xmlstarlet sel -t -v 'yazgfs/config/pass' '/etc/koha/sites/pkgrel/koha-conf.xml'");
            chomp $pkg_user;
            chomp $pkg_pass;
            my $harness_args = {
                test_args => [
                    "http://$lxc_ip:8080", "http://$lxc_ip",
                    "$flavour",              "$pkg_user",
                    "$pkg_pass"
                ]
            };
            tap_task( "Running webinstaller for $flavour",
                1, $harness_args, "$reltools/install-fresh.pl" );

            push @tested_package_installs, $flavour;
        }
    clean_lxc();
    $lxc_host = '';
    }
}

if ( $config->param('sign') && !$config->param('skip-deb') ) {
    shell_task( "Signing packages", "debsign " . build_result('*.changes') );
    $signed_packages = 'yes';
}

if ( $config->param('deploy') && !$config->param('skip-deb') ) {
    shell_task(
        "Importing packages to apt repo",
        "dput koha " . build_result('*.changes')
    );
    $deployed = 'yes';
}

unless ( $config->param('skip-tgz') || $config->param('skip-install') ) {
    for my $flavour (@marcflavours) {
        my $lflavour = lc $flavour;
        print_log("Installing from tarball for $flavour...");

        my ($lxc_ip, $ssh) = create_lxc();
        my $subdir = 'koha-' . $config->param('version');
        ssh_task( $ssh, "Downloading tarball...", "wget -nv http://10.0.3.1" . $config->param('tarball') . ' 2>&1', '', 1 );
        ssh_task( $ssh, "Untarring tarball...", "tar zxvf " . basename($config->param('tarball')) . ' 2>&1', '', 1 );
        ssh_task( $ssh, "Installing dependencies...", "sudo apt-get -y install `cat install_misc/ubuntu.12.04.packages | grep install | sed -e 's/install\$//' | tr -d ' \\t' | tr '\\n' ' '` 2>&1", $subdir, 1 );
        my $env_vars = "DB_HOST=localhost DB_NAME=" . $config->param('database') . " DB_USER=" . $config->param('user') . " DB_PASS=" . $config->param('password') . " ZEBRA_MARC_FORMAT=$lflavour PERL_MM_USE_DEFAULT=1";
        ssh_task( $ssh, "Running perl Makefile.PL for $flavour",
            "$env_vars perl Makefile.PL 2>&1", $subdir, 1 );
        ssh_task( $ssh, "Running make for $flavour...", "make 2>&1", $subdir, 1 );

        ssh_task( $ssh, "Rewriting Apache config for $flavour",
            "sed -i -e 's/<VirtualHost 127.0.1.1:80>/<VirtualHost *:80>/' -e 's/<VirtualHost 127.0.1.1:8080>/<VirtualHost *:8080>/' blib/KOHA_CONF_DIR/koha-httpd.conf",
            $subdir, 1 );

        ssh_task( $ssh, "Running make test for $flavour...", "make test 2>&1", $subdir, 1 );
        ssh_task( $ssh, "Running make install for $flavour...",
            "sudo make install 2>&1", $subdir, 1 );
        ssh_task( $ssh, "Linking and loading Apache site for $flavour...", "sudo ln -s /etc/koha/koha-httpd.conf /etc/apache2/sites-available/koha && sudo a2ensite koha && sudo apache2ctl restart", '', 1 );

        unless ( $config->param('skip-webinstall') ) {
            my $harness_args = {
                test_args => [
                    "http://$lxc_ip:8080", "http://$lxc_ip",
                    "$flavour",            $config->param('user'),
                    $config->param('password')
                ]
            };
            tap_task( "Running webinstaller for $flavour",
                1, $harness_args, "$reltools/install-fresh.pl" );

            push @tested_tarball_installs, $flavour;
        }
        clean_lxc();
        $lxc_host = '';
    }
}

if ( $config->param('tag') ) {
    my $tag_action = $config->param('sign') ? '-s' : '-a';
    shell_task(
        "Tagging current commit",
        "git tag $tag_action -m 'Koha release "
          . $config->param('version') . "' v"
          . $config->param('version') . " 2>&1"
    );
    $tagged = 'yes';
}

generate_email() unless $config->param('skip-rnotes');

if ( defined $config->param('push') ) {
    foreach my $target ($config->param('push')) {
        if ( $target =~ m/^([^:]*):(.*)$/ ) {
            shell_task( "Pushing to branch $2 on remote $1",
                "git push $1 " . $config->param('branch') . ":$2" );
            if ( $config->param('tag') ) {
                shell_task( "Pushing tag to remote $1",
                    "git push $1 v" . $config->param('version') );
            }
        } else {
            shell_task( "Pushing to default remote/branch",
                "git push" );
            if ( $config->param('tag') ) {
                shell_task( "Pushing tag to default remote",
                    "git push v" . $config->param('version') );
            }
        }
    }
    $pushed = 'yes';
}

my $configfile = build_result('summary.cfg');
$config->write($configfile);

if ( $config->param('deploy') && $config->param('post-deploy-script') ) {
    foreach my $script ($config->param('post-deploy-script')) {
        shell_task( "Running post-deploy script",
            $script . ' ' . $configfile );
    }
}

if ( $config->param('clean') ) {
    clean_lxc();
    remove_tree( $config->param('build-result') );
    $cleaned = 'yes';
}

success();

sub build_result {
    my @components = @_;
    my $path       = $config->param('build-result');

    foreach my $component (@components) {
        $path .= "/$component";
    }
    return $path;
}

sub set_default {
    my $key   = shift;
    my $value = shift;

    chomp($value);
    $config->param( $key, $value ) unless $config->param($key);
}

sub clean_lxc {
    shell_task( "Shutting down lxc container...", "sudo lxc-stop -n $lxc_host", 1 ) if $lxc_host;
}

sub summary {
    my ($capsule_summary) = @_;
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

    my %vars = $config->vars();
    foreach my $key ( sort keys %vars ) {
        if ( $key =~ m/^skip-([a-z]+)$/ ) {
            $skipped .= ", $1" if ( $config->param($key) );
        }
    }
    $skipped =~ s/^, //;
    $skipped = 'none' unless $skipped;
    $config->param( 'package', 'none' )
      unless ( -s $config->param('package') && not $config->param('skip-deb') );
    $config->param( 'tarball', 'none' )
      unless ( -s $config->param('tarball') && not $config->param('skip-tgz') );
    $config->param( 'rnotes', 'none' )
      unless ( -s $config->param('rnotes')
        && not $config->param('skip-rnotes') );
    return if $config->param('quiet') > 1;
    my $branch  = $config->param('branch');
    my $version = $config->param('version');
    my $maintainer =
        $config->param('maintainer-name') . ' <'
      . $config->param('maintainer-email') . '>';
    my $tarball    = $config->param('tarball');
    my $package    = $config->param('package');
    my $rnotes     = $config->param('rnotes');
    my $stats      = $config->param('stats');
    my $emailfile  = $config->param('email-file');
    my $summary = <<_SUMMARY_;
$capsule_summary

Release test report
=======================================================
Branch:                 $branch
Version:                $version
Maintainer:             $maintainer
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
Pushed git branch:      $pushed
Cleaned:                $cleaned
Tarball file:           $tarball
Package file:           $package
Release notes:          $rnotes
Statistics:             $stats\[.txt/.html\]
E-mail file:            $emailfile
Summary config file:    $configfile
_SUMMARY_

    $summary .= colored( "Version mismatch between requested version " .
      $config->param('version') . " and Koha version $kohaversion!", 'red' ) .  "\n"
      if $version_mismatch;
    $summary .= $capsule_summary;

    print $summary unless $config->param('quiet') > 1;

    if ( $config->param('alert') ) {
        $summary =~ s/\x1b\[[0-9]*m//g;
        $summary .= "=======================================================\n\n";
        my $msg = MIME::Lite->new(
            From    => $config->param('maintainer-email'),
            To      => $config->param('alert'),
            Subject => 'Release tool completed',
            Data    => $summary,
            Type    => 'multipart/mixed'
        );
        $msg->attach(
            Type    => 'text/plain',
            Data    => $summary
        );
        $log =~ s/\x1b\[[0-9]*m//g;
        $msg->attach(
            Type     => 'text/plain',
            Data     => $log,
            Filename => 'release-tool.log'
        );
        $msg->send;
    }
}

sub success {
    summary(colored( "Successfully finished release test", 'green' ) . "\n");

    exit 0;
}

sub fail {
    my $component = shift;
    my $callback  = shift;

    summary(colored( $component, 'bold red' ) . ' ' .
      colored( " failed in release test", 'red' ) . "\n");

    if ($output) {
        open( my $errorlog, ">", $config->param('errorlog') )
          or die "Unable to open error log for writing";
        print $errorlog $output;
        close($errorlog);
    }

    print colored( "Error report at " . $config->param('errorlog'), 'red' ),
      "\n"
      unless $config->param('quiet') > 1;

    $callback->() if ( ref $callback eq 'CODE' );

    exit 1;
}

sub print_log {
    $log .= join(' ', @_) . "\n";
    print @_, "\n" unless $config->param('quiet');
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

sub create_lxc {
    # Sorry, creating the lxc container sucks. Deal with it.
    print_log(" Creating lxc container...");
    my $command = "sudo lxc-start-ephemeral -d -o ubuntu";
    $log .= "> $command\n";
    print colored( "> $command\n", 'cyan' )
        if ( $config->param('verbose') >= 1 );
    my $pid = open( my $outputfh, "-|", "$command" )
        or die "Unable to run $command\n";
    while (<$outputfh>) {
        print $_ if ( $config->param('verbose') >= 2 );
        $output .= $_;
        if ($_ =~ /^([^ ]*) is running/) {
            $lxc_host = $1;
            last;
        }
    }
    close($outputfh);

    my $lxc_ip = `host -s $lxc_host 10.0.3.1 | grep 'has address' | sed -e 's/^.*has address //'`;
    chomp($lxc_ip);
    print_log(" Connecting to lxc container...");
    my $ssh = Net::OpenSSH->new("ubuntu\@$lxc_ip", master_opts => [-o => "StrictHostKeyChecking=no"]);

    return ($lxc_ip, $ssh);
}

sub run_cmd {
    my $command = shift;
    $log .= "> $command\n";
    print colored( "> $command\n", 'cyan' )
      if ( $config->param('verbose') >= 1 );
    my $pid = open( my $outputfh, "-|", "$command" )
      or die "Unable to run $command\n";
    while (<$outputfh>) {
        print $_ if ( $config->param('verbose') >= 2 );
        $output .= $_;
    }
    close($outputfh);
    $log .= $output . "\n";
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

sub ssh_task {
    my $ssh = shift;
    my $message = shift;
    my $command = shift;
    my $dir = shift;
    my $callback;
    $callback = pop @_ if ( $#_ && ref $_[$#_] eq 'CODE' );
    my $subtask = shift || 0;
    my $logmsg = ( ' ' x $subtask ) . $message;
    print_log("$logmsg...");
    $command = "cd $dir && $command" if $dir;
    $log .= "> $command\n";
    print colored( "> $command\n", 'cyan' )
      if ( $config->param('verbose') >= 1 );
    $output = '';
    my ($outputfh, $pid) = $ssh->pipe_out($command);
    die "Unable to run $command\n" unless $pid;
    while (<$outputfh>) {
        print $_ if ( $config->param('verbose') >= 2 );
        $output .= $_;
    }
    close($outputfh);
    $log .= $output . "\n";
    fail( $message, $callback ) if ($ssh->error);
}

sub tap_task {
    my $message      = shift;
    my $subtask      = shift;
    my $harness_args = shift;
    my $callback;
    $callback = pop @_ if ( ref $_[$#_] eq 'CODE' );
    my @tests  = @_;
    my $logmsg = ( ' ' x $subtask ) . $message;

    if ( $config->param('verbose') ) {
        $harness_args->{'verbosity'} = 1;
    }
    elsif ( $config->param('quiet') ) {
        $harness_args->{'verbosity'} = -1;
    }
    $harness_args->{'lib'}   = [ $config->param('kohaclone') ];
    $harness_args->{'merge'} = 1;

    print_log("$logmsg...");

    if ( $config->param('verbose') >= 1 ) {
        my $command = 'prove ';
        foreach my $test (@tests) {
            $command .= "$test ";
        }
        print colored( "> $command\n", 'cyan' );
        $log .= "> $command\n";
    }

    my $pid = open( my $testfh, '-|' ) // die "Can't fork to run tests: $!\n";
    if ($pid) {
        while (<$testfh>) {
            print $_ if ( $config->param('verbose') >= 2 );
            $output .= $_;
        }
        $log .= $output . "\n";
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
            INCLUDE_PATH => "$reltools",
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
        $config->param('email-template'),
        {
            VERSION  => $config->param('version'),
            RELNOTES => $config->param('rnotes')
        }
    );
    $content =~ s/^####.*$//m;
    my $msg = MIME::Lite->new(
        From    => $config->param('maintainer-email'),
        To      => $config->param('email-recipients'),
        Subject => $config->param('email-subject'),
        Data    => $content,
    );
    open( my $emailfh, ">", $config->param('email-file') );
    $msg->print($emailfh);
    close($emailfh);
}

sub interrupt {
    undef $SIG{INT};
    warn "**** YOU INTERRUPTED THE SCRIPT ****\n";
    summary();
    die "**** YOU INTERRUPTED THE SCRIPT ****\n";
}

=head1 DPUT CONFIGURATION

In order for the deploy step to work, you will need to have a signed apt repository
set up. Once you have set up your repo, put the following in your  ~/.dput.cf:

    [koha]
    method = local
    incoming = /home/apt/koha/incoming
    run_dinstall = 0
    post_upload_command = reprepro -b /home/apt/koha processincoming default

=head1 PBUILDER CONFIGURATION

Koha's C<build-git-snapshot> script uses uses L<pbuilder(8)> for building the
Debian packages, so you will need a working pbuilder environment. To create
one, you can use the following command:

    sudo pbuilder create \
        --othermirror 'deb http://debian.koha-community.org/koha squeeze main' \
        --mirror http://ftp.debian.org/debian \
        --keyring '${release-tools-repo}/debian.koha-community.org.gpg'

=head1 LXC CONFIGURATION

Testing the Koha installation process requires an LXC container called "ubuntu"
configured with the following features:

=over 8

=item Ubuntu Precise chosen as the distro

=item The following line in the sudoers file:

    ubuntu  ALL=NOPASSWD: /usr/bin/make, /usr/bin/apt-get, /sbin/poweroff, \
    /bin/ln, /usr/sbin/apache2ctl, /usr/sbin/a2ensite, /usr/bin/dpkg, \
    /usr/sbin/koha-create, /usr/bin/xmlstarlet

=item The current user's SSH key must be in /home/ubuntu/.ssh/authorized_keys2
in the container.

=item mysql-server must be installed and a database and user created for the
tarball installation.

=item You must make your build result directory available via HTTP on the
lxcbr interface. A configuration similar to the one nginx configuration below
is recommended:

    server {
        listen 10.0.3.1:80;
        server_name 10.0.3.1;
        root /var/www;

        location /home/jcamins/releases {
            alias /home/jcamins/releases;
        }
    }

=item An apt cache set up with apt-cacher-ng is recommended to speed up the
process.

=back

=head1 SEE ALSO

L<dch(1)>, L<dput(1)>, L<lxc(7)>, L<pbuilder(8)>, L<reprepro(1)>

=head1 AUTHOR

Jared Camins-Esakov <jcamins@cpbibliography.com>

=cut
