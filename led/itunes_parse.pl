#!/usr/bin/perl -w

# this script continually polls the iTunes database and (if it's running)
# publishes it to a web page which is then curled and pushed to the LED. 

# comment
# TODO: daemonize!

sub get_itunes_data {
    my ($artist, $track, $album) = @_;
    my $stuff = "/usr/bin/osascript -e 'tell app \"iTunes\" to $artist of current track & (ASCII character 32) & (ASCII character 58) & (ASCII character 32) & $track of current track & (ASCII character 32) & (ASCII character 91) & $album of current track & (ASCII character 93)'";
    chomp(my $results = `$stuff`);
    $results =~ s/\[\]//g;
    $results =~ s/^\s://g;
    return($results);
}

sub daemonize {
  if (fork) { exit 0; }
  $SIG{'HUP'} = 'IGNORE';
  open(STDIN,  "+>/dev/null");
  open(STDOUT, "+>&STDIN");
  open(STDERR, "+>&STDIN");
}

&daemonize();

while(1)
{
    sleep 1;
    chomp(my $state = `/usr/bin/osascript -e \'tell application \"iTunes\" to player state as string\'`);
    if ($state eq "playing") {
	my $music  = get_itunes_data("artist","name","album");
	system("/bin/echo \"$music\" | /usr/bin/nc -w 1 10.0.0.122 5555");
	#print "$music\n";
	#nc -w 1 10.0.0.117 5555
    }   
}
