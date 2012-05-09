#!/usr/bin/perl -w

use WWW::Mechanize;
use Data::Dumper;

my ($user, $password, $version, $tag) = @ARGV;

my $agent = WWW::Mechanize->new();
$agent->get('http://bugs.koha-community.org/bugzilla3/');
$agent->follow_link(text => 'Log In', n => '1');
$agent->form_name('login');
$agent->tick('Bugzilla_restrictlogin', 'on');
$agent->field('Bugzilla_password', "$password");
$agent->field('Bugzilla_login', "$user");
$agent->click('GoAheadAndLogIn');

my @git_log = qx|git log --pretty=format:'%s' $tag..$HEAD|;
my @bugs = (  );

foreach (@git_log) {
    if ($_ =~ m/([B|b]ug|BZ)?\s?(?<![a-z]|\.)(\d{4})[\s|:|,]/g) {
#        print "$&\n"; # Uncomment this line and the die below to view exact matches
        push @bugs, $2;
    }
}

my @problems;
my $branch = 'rel_3_6';

foreach my $bug (@bugs) {
    my $change = 0;
    $agent->form_number(1);
    $agent->field('quicksearch', $bug);
    $agent->click();

    $agent->form_name('changeform');
    my $status = $agent->value('bug_status');
    if ($status eq 'Pushed to Master') {
        $agent->field('bug_status', 'Pushed to Stable');
        $change = 1;
    }
    if ($status eq 'RESOLVED' || $status eq 'Pushed to Stable') {
        $change = 1;
    }
    $agent->field('comment', "This bug will be included in the Koha $version release.");
    $change = 0 unless $agent->value('version') eq "$branch";
    if ($change) {
        $agent->click();
        print "Changing $bug ($status)\n";
    } else {
        push @problems, $bug;
    }
}
print "Bugs to check: @problems\n";

