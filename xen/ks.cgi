#!/usr/bin/perl -w

# $Id: ks.cgi 859 2010-02-17 01:14:00Z jhunter $
# $HeadURL: http://sfopsvn/iops/repo/cfe-config-tuk-prd/var/www/cgi-bin/ks.cgi $

# this CGI script is used to really only pull 2 values from IPPlan's DB.. namely
# hostname/IP address. once they're grabbed, the xen KS config is read in, with
# the hostname/IP regex'ed into the KS config. the MAC grabbed in this script
# isn't used - it's just in here for consistency since the same query is used
# to generate the actual xen configs.

use CGI ':standard';
use DBI;

sub not_found($$) {
    my ($thing, $hostname) = @_;
    print "$hostname: $thing not found. please double-check invdb/dom0.";
    exit 10;
}

my $debug   = 0;
my $ks_cfg  = "/var/www/html/xen-ks.cfg";
my ($hname, $ip, $mac);

# setup CGI object
my $q = new CGI;
print $q->header("text/plain");

# request method here *must* be GET
my $req_method = $ENV{'REQUEST_METHOD'};
if ($req_method ne "GET") {
    print "Invalid Requested Method!\n";
    exit 20;
}

my $query_string = $ENV{'QUERY_STRING'};
$debug && print "got: $query_string\n";

if ($query_string =~ /^$/) {
    print "Error: hostname/arch required!\n";
    exit 25;
}

if ($query_string !~ /\?/) {
    print "invalid query string received\n";
    print "must be of the form: $0/\$hostname?\$arch\n";
    exit 30;
}

my ($hostname, $arch) = split(/\?/,$query_string);

if ($arch !~ /^(i386)|(x86_64)$/) {
    print "invalid arch specified.";
    exit 35;
}

# we use kssendmac for baremetal KS hosts!
my $mac1 = $ENV{'HTTP_X_RHN_PROVISIONING_0'} || $ENV{'HTTP_X_RHN_PROVISIONING_MAC_0'};

# are we KSing baremetal or xen?
# check $ENV{'QUERY_STRING}.. is it a single hostname (xen) or a bunch of other stuff (bare metal)
# if xen, do this type of query. if baremetal, do that type. 

# ipplan stuff
my $dbhost  = "sfnetmon01.sfcolo.current.com";
my $dbase   = "ipplan";
my $dbuser  = "iops";
my $dbpass  = "iops";

my $dbh     = DBI->connect("dbi:mysql:db=$dbase;host=$dbhost", $dbuser, $dbpass, {AutoCommit => 0}) || die("error connecting to MySQL on $dbhost");
my $sth     = $dbh->prepare("SELECT hname, inet_ntoa(ipaddr) AS ip, macaddr FROM ipaddr WHERE hname LIKE '%$hostname%'");
$sth->execute;

while (my $row  = $sth->fetchrow_hashref) {
    while (my ($key, $val) = each %$row) {
        $hname  = $val if $key =~ /^hname$/;
        $ip     = $val if $key =~ /^ip$/;
        $mac    = $val if $key =~ /^macaddr$/;
        $count++ if $key =~ /^hname$/;
        $debug && print "$key: $val\n";
    }
}

$dbh->disconnect();

if ( $count > 1 ) { print "multiple host entries found for $hostname in $dbase. please double-check."; exit 40; }

not_found("hostname", $hostname) unless $hname;
not_found("MAC address", $hostname) unless $mac;
not_found("IP address", $hostname) unless $ip;

# reformat MAC address
$mac =~ s!(\w{2})(\w{2})(\w{2})(\w{2})(\w{2})(\w{2})!$1:$2:$3:$4:$5:$6!g;
$debug && print "$mac";

# clean up keys in case this IP was used prior
unlink("/var/cfengine/ppkeys/root-$ip.pub");

# default gatway
my $gateway     = "10.3.8.1";

if ($ip =~ /^10\.3\.4\./) {        # frontend subnet
    $gateway    = "10.3.4.1";
} elsif ($ip =~ /^10\.3\.5\./) {   # backend subnet
    $gateway    = "10.3.5.1";
}

# iterate over our KS config and regex in our hostname/IP info
open(FH,"<$ks_cfg") || die("can't open $ks_cfg: $!\n");
while(<FH>) {
    $_ =~ s!\$IP\$!$ip!g;
    $_ =~ s!\$HOSTNAME\$!$hname!g;
    $_ =~ s!\$GATEWAY\$!$gateway!g;
    $_ =~ s!\$ARCH\$!$arch!g;
    print "$_";
}
close(FH) || die("can't close $ks_cfg: $!\n");
