#!/usr/bin/perl

use Test::More tests => 5;
use Test::WWW::Mechanize;

my $agent = Test::WWW::Mechanize->new();

$agent->get_ok("$ARGV[0]/cgi-bin/koha/installer/install.pl");
$agent->form_name('mainform');
$agent->field('password', 'koharel');
$agent->field('userid', 'koharel');
$agent->click();

$agent->form_name('language');
$agent->field('language', 'en');
$agent->click();

$agent->form_name('checkmodules');
$agent->click();

$agent->form_name('checkinformation');
$agent->click();

$agent->form_name('checkdbparameters');
$agent->click();

$agent->form_number(1);
$agent->click();

$agent->form_number(1);
$agent->click();

$agent->follow_link(text => 'install basic configuration settings', n => '1');
$agent->form_name('frameworkselection');
$agent->field('marcflavour', 'MARC21');
$agent->click();

$agent->form_name('frameworkselection');
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_creator_data.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/userflags.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/sample_notices_message_transports.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_libraries.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_news.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/patron_atributes.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/patron_categories.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/sample_notices.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/marcflavour/marc21/mandatory/marc21_framework_DEFAULT.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_itemtypes.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_holidays.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/marc21_holdings_coded_values.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/sample_notices_message_attributes.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/auth_val.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/marcflavour/marc21/mandatory/authorities_normal_marc21.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/message_transport_types.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/auth_values.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/marcflavour/marc21/optional/marc21_simple_bib_frameworks.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_patrons.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/userpermissions.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/parameters.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/stopwords.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/marcflavour/marc21/optional/marc21_fastadd_framework.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/marcflavour/marc21/optional/marc21_default_matching_rules.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/subtag_registry.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/optional/sample_z3950_servers.sql");
$agent->tick('framework', "$ARGV[2]/koha/intranet/cgi-bin/installer/data/mysql/en/mandatory/class_sources.sql");
$agent->click();

$agent->form_name('finish');
$agent->click();

$agent->follow_link(text => 'here', n => '1');
$agent->form_name('loginform');
$agent->field('password', 'koharel');
$agent->field('userid', 'koharel');
$agent->field('branch', '');
$agent->click();

$agent->get_ok("$ARGV[0]");
$agent->content_contains("Welcome to Koha", "intranet news");


$agent->get_ok("$ARGV[1]");
$agent->content_contains("Welcome to Koha...", "opac main user block");

