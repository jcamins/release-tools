#!/usr/bin/perl

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

# Usage: install-fresh.pl intranet-URL opac-URL marcflavour dbuser dbpass
#
# This script uses Test::WWW::Mechanize to go through the Koha webinstaller
# process, and confirm that the end result is a functional Koha installation.

use Test::More tests => 14;
use Test::WWW::Mechanize;
use Data::Dumper;
use HTML::Form;

my ($intranet, $opac, $flavour, $user, $password) = @ARGV;
my $agent = Test::WWW::Mechanize->new();

$agent->get_ok("$intranet/cgi-bin/koha/installer/install.pl", 'open installer');
$agent->form_name('mainform');
$agent->field('password', $password);
$agent->field('userid', $user);
$agent->click_ok('', 'log in to installer');

$agent->form_name('language');
$agent->field('language', 'en');
$agent->click_ok('', 'choose language');

$agent->form_name('checkmodules');
$agent->click_ok('', 'check modules');

$agent->form_name('checkinformation');
$agent->click_ok('', 'check information');

$agent->form_name('checkdbparameters');
$agent->click_ok('', 'check db parameters');

$agent->form_number(1);
$agent->click();

$agent->form_number(1);
$agent->click();

$agent->follow_link(text => 'install basic configuration settings', n => '1');
$agent->form_name('frameworkselection');
$agent->field('marcflavour', $flavour);
$agent->click_ok('', 'framework selection');

$agent->form_name('frameworkselection');
for (my $_ = $agent->content(); pos($_) < length($_) && $_ =~ m/<input type="checkbox" name="framework" value="([^"]*)"/g; ) {
    $agent->tick('framework', $1);
}
$agent->click_ok('', 'additional data');

$agent->form_name('finish');
$agent->click_ok('', 'finish');

$agent->follow_link(text => 'here', n => '1');
$agent->form_name('loginform');
$agent->field('password', $password);
$agent->field('userid', $user);
$agent->field('branch', '');
$agent->click_ok('', 'login to staff client');

$agent->get_ok("$intranet");
$agent->content_contains("Welcome to Koha", "intranet news");


$agent->get_ok("$opac");
$agent->content_contains("Welcome to Koha...", "opac main user block");

