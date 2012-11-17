#!/usr/bin/perl -w

# $Id: xen_ks.pl 857 2010-02-17 01:06:57Z jhunter $
# HeadURL: $

# this script contacts IPPlan and generates 2 files: a kickstart file and a 'normal' file.
# after generating the kickstart file, the xen is built simply via 'xm create'. upon completion
# the only file left is the 'normal' file, which is used to boot the xen.

use DBI;
use Sys::Hostname;

sub usage {
    print "usage: $0 <hostname> <arch>\n";
    print "ex: $0 tuk-ops-admin01 32\n";
    print "ex: $0 tuk-ops-www02 64\n";
    exit 10;
}

sub not_found($$) {
    my ($thing, $hostname) = @_;
    print "$hostname: $thing not found. please double-check invdb/dom0.\n";
    exit 20;
}

sub verify_file($) {
    my $file = shift;
    my $valid_overwrite = "";
    if ( -e "$file" ) {
        print "$file exists. overwrite? (y/n): ";
        chomp($valid_overwrite = <STDIN>);
        $valid_overwrite = lc($valid_overwrite);
        exit unless $valid_overwrite eq 'y';
    }
}

my ($domU, $build) = @ARGV;
usage() unless $domU && $build;

if ($build !~ /^(32)|(64)$/) {
    print "invalid arch specified.";
    usage();
}

my $debug       = 0;
my $count       = 0;
my $dir         = "/etc/xen/configs/";     
my $dev_dir     = "/dev/$domU";
my $config      = "$dir$domU";
my ($hname, $ip, $mac);

my $dom0        = hostname();
if ($dom0 !~ /xen/)    { print "this script must be run on a dom0 only.\n"; exit 30; }

my $is_running  = `/usr/sbin/xm list | /bin/grep $domU | /usr/bin/wc -l`;
if ( $is_running > 0 )  { print "$domU seems to be running. please shut it down and try again.\n"; exit 40; }
not_found("/dev directory", $domU) unless -d $dev_dir;

# ipplan stuff
my $dbhost  = "sfnetmon01.sfcolo.current.com";
my $dbase   = "ipplan";
my $dbuser  = "iops";
my $dbpass  = "iops";

my $dbh     = DBI->connect("dbi:mysql:db=$dbase;host=$dbhost", $dbuser, $dbpass, {AutoCommit => 0}) || die("error connecting to MySQL on $dbhost");
my $sth     = $dbh->prepare("SELECT hname, inet_ntoa(ipaddr) AS ip, macaddr FROM ipaddr WHERE hname LIKE '%$domU%'");
$sth->execute;

while (my $row  = $sth->fetchrow_hashref) {
    while (my ($key, $val) = each %$row) {
        $hname  = $val if $key =~ /^hname$/;
        $ip     = $val if $key =~ /^ip$/;
        $mac    = $val if $key =~ /^macaddr$/;
        $count++ if $key =~ /^hname$/;
        $debug && print "FOUND: $key: $val\n";
    }
}

$dbh->disconnect();

if ( $count > 1 ) { print "multiple host entries found for $domU in $dbase. please double-check.\n"; exit 50; }

not_found("hostname", $domU) unless $hname;
not_found("MAC address", $domU) unless $mac;
not_found("IP address", $domU) unless $ip;

# reformat MAC address
$mac =~ s!(\w{2})(\w{2})(\w{2})(\w{2})(\w{2})(\w{2})!$1:$2:$3:$4:$5:$6!g;
$debug && print "MAC: $mac\n";

# default gateway / xen bridge set
my $gateway     = "10.3.8.1";
my $xen_bridge  = "xenbr0";

if ($ip =~ /^10\.3\.4\./) {        # frontend subnet
    $gateway    = "10.3.4.1";  
    $xen_bridge = "xenbr1";
} elsif ($ip =~ /^10\.3\.5\./) {   # backend subnet
    $gateway    = "10.3.5.1";  
    $xen_bridge = "xenbr2";
}

# arch set
my $arch;
$arch = "i386" if $build =~ /^32$/;
$arch = "x86_64" if $build =~ /^64$/;

# write KS xen config
my $ks_cfg  = <<XXX;
name        = "$domU"
kernel      = "/etc/xen/ks/5.4/i386/vmlinuz"
ramdisk     = "/etc/xen/ks/5.4/i386/initrd.img"
extra       = "text ks=http://10.3.8.10/cgi-bin/ks.cgi?$domU?$arch ip=$ip netmask=255.255.255.0 gateway=$gateway dns=10.118.1.13"
memory      = "2048"
disk        = [ 'phy:$domU/root,xvda,w', 'phy:$domU/var,xvdb,w', 'phy:$domU/opt,xvdc,w', 'phy:$domU/swap,xvdd,w', ]
vif         = [ 'mac=$mac, bridge=$xen_bridge', ]
vcpus       = 1
on_reboot   = 'destroy'
on_crash    = 'destroy'
XXX

my $ks_config = "$config" . "-ks";
verify_file($ks_config);

open(FH,">$ks_config") || die("can't open $ks_config: $!");
print FH $ks_cfg;
close(FH) || die("can't close $ks_config: $!");

print "initial xen kickstart config built. beginning in 5 seconds..\n";
sleep 5;
system("/usr/sbin/xm create -c $ks_config"); # redir to stderr to get back console when done?

# write 'regular' config
my $reg_cfg = <<XXX;
name        = "$domU"
memory      = "2048"
disk        = [ 'phy:$domU/root,xvda,w', 'phy:$domU/var,xvdb,w', 'phy:$domU/opt,xvdc,w', 'phy:$domU/swap,xvdd,w', ]
vif         = [ 'mac=$mac, bridge=$xen_bridge', ]
bootloader  = "/usr/bin/pygrub"
vcpus       = 1
on_reboot   = 'destroy'
on_crash    = 'destroy'
XXX

verify_file($config);

open(FH,">$config") || die("can't open $config: $!");
print FH $reg_cfg;
close(FH) || die("can't close $config: $!");

print "initial xen kickstart complete.\n";
print "erasing original $domU KS file.\n";
unlink($ks_config) || die "can't delete $ks_config: $!";
print "starting $domU via 'xm create'..\n";
sleep 5;
system("/usr/sbin/xm destroy $config > /dev/null 2>&1");
sleep 5;
system("/usr/sbin/xm create $config");
