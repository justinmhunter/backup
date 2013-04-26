#!/usr/bin/perl -w

=pod

this script:
- does a git pull.
- does a git log over the last X hours.
- iterates over the git log and creates a hash of previous commits in the last X hours:
  -  key = commit hash
  -  val(s) = the committed file(s).
- it then iterates over each hash key, and knife uploads the ones that are cookbooks.

=cut

use POSIX;
use Data::Dumper;

sub usage() {
  print "Usage: $0 TOTAL_PREVIOUS_HOURS\n";
  print "Ex: $0 24\n";
  exit;
}

usage if scalar(@ARGV) != 1;
usage if not isdigit($ARGV[0]);

my $previousHours = $ARGV[0];

my $gitLocation = "/home/jhunter/wikia/chef-repo/.git";
my $chefRepo = "/home/jhunter/wikia/chef-repo/";

print "Doing a git pull first.. ";
$ret = system("git --git-dir='$gitLocation' --work-tree='$chefRepo' pull 2>/dev/null");
if($ret != 0){
  print "ERR. Something's wrong. Exiting.\n";
  exit;
}

my $command = `git --git-dir="/home/jhunter/wikia/chef-repo/.git" --work-tree="/home/jhunter/wikia/chef-repo/cookbooks/" whatchanged --since="$previousHours hour ago" --oneline`;
my @commits = split("\n", $command);

if(scalar(@commits) == 0) {
  print "Either there's a problem with git or there were no commits made in the past $previousHours hour(s) (I'm showing no commits). Please retry again later or check that 'git log' is behaving properly.\n";
  exit;
}

my $debug = 0;
$debug && print Dumper @commits;

my %cookbooksPerCommit;
my %totalCommits;
my $hashKey;

foreach $commit (@commits) {
  if($commit =~ m/^[a-z0-9]{7}/i) {
    my @commitHash = split(" ", $commit);
    $cookbooksPerCommit{$commitHash[0]} = {};
    $hashKey = $commitHash[0];
    next;
  }
  if($commit =~ m/cookbooks\/([a-zA-Z0-9_-]+)\//) {
    $cookbooksPerCommit{$hashKey}{$1}++;
    $totalCommits{$1}++;
  }elsif($commit =~ m/(roles|data_bags)\//) {
    $cookbooksPerCommit{$hashKey}{$1}++;
    $totalCommits{$1}++;
  }

}

print "Chef-Repo Commits Over The Past $previousHours Hours\n";

print "\n";

foreach my $key (keys %cookbooksPerCommit) {
  print "Commit $key Has The Following Commits:\n";
    foreach my $hashKey (keys %{ $cookbooksPerCommit{$key} }) {
      print ">> $hashKey: $cookbooksPerCommit{$key}{$hashKey}\n";  
    }
}

print "\n";

print "Total Commits Per Cookbook:\n";
foreach my $key (keys %totalCommits) {
  print ">> $key - $totalCommits{$key}\n";
}

print "\n";

print "Knife Cookbook Upload Proceeding For The Following:\n";
foreach my $key (keys %totalCommits) {
  next if $key =~ m/roles|data_bags/;
  print ">> knife cookbook upload $key: ";
  #$ret = system(\"knife cookbook upload $key\")";
  $ret = 0;
  if($ret == 0) {
    print "OK\n";
  }else{
    print "FAIL. exiting out.\n";
    exit;
  }
}
