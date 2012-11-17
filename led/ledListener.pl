#!/usr/bin/perl -w

use strict;
use IO::Socket;

sub daemonize {
  if (fork) { exit 0; }
  $SIG{'HUP'} = 'IGNORE';
  open(STDIN,  "+>/dev/null");
  open(STDOUT, "+>&STDIN");
  open(STDERR, "+>&STDIN");
}

sub send {
    my $pre = shift;
    my $hack = " " x 100;
    my $len = length($pre);
    $hack =~ s!^.{$len}!$pre!g;
    my $post = "\001"."Z"."00"."\002"."AA"."\x1B"." t".$hack."\004";
    system("/bin/echo \"$post\" > /dev/ttyUSB0");
}

sub snooze {
    select(undef,undef,undef,8.25);
}

my $hash = { song => "" };

my $listener = IO::Socket::INET->new(
    LocalAddr => '10.0.0.122',
    LocalPort => 5555,
    Proto     => 'tcp',
    Listen    => 5,
    Reuse     => 1,
);

die "Could not create listener socket: $!\n" unless $listener;

daemonize();

while(1) {
    my $new_sock = $listener->accept();
    while(<$new_sock>) {
            my $curr = $_;
            if ($hash->{song} ne $curr) {
                &send($curr);
                $hash->{song} = $curr;
                &snooze();
                &send(""); 
        }
    }
}

close($listener);
