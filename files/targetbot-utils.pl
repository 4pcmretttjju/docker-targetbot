#!/usr/bin/perl -w

use strict;
use warnings;
use Storable;

use POE qw(Component::IRC::State Component::IRC::Plugin::Connector Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::BotAddressed Component::IRC::Plugin::BotTraffic Component::IRC::Plugin::CTCP Component::IRC::Plugin::NickReclaim Component::IRC::Plugin::NickServID Component::IRC::Plugin::BotCommand);
use POE::Component::IRC::Common qw( :ALL );
use HTML::TreeBuilder -weak; # Ensure weak references in use (no need to call $tree = $tree->delete; when done)
use MediaWiki::API;
use Time::Seconds;
use Date::Parse;						# used for str2time
use List::Util 'max';

STDOUT->autoflush(1);

# Used by the bot
my ($nickname, $username, $ircname) = $ENV{'NICK'};
my $server = $ENV{'SERVER'}; ;
my $nickservpw = $ENV{'NS_PASS'};
my @channels = split(',', $ENV{'CHANNELS'});
my $ownernick = 'Rick';					# Ensures owner has full access

my $wikiuser = 'TargetReport';			# Wiki pages to update, e.g. 
										# http://wiki.urbandead.com/index.php/User:TargetReport/Ridleybank
my $stale_interval = 86400;				# 24h = 86400 seconds

################################################################################
# Some common regular expressions and templates
################################################################################
my $wit_re =		    qr/(https?:\/\/iamscott\.net\/\d+\.html|
				    https?:\/\/udwitness\.oddnetwork\.org\/.*html)/i;
#my $datetime_re =	      qr/(
#       (\w\w\w \w\w\w \d\d? \d\d:\d\d:\d\d -?\d\d\d\d \d\d\d\d)|
#       (\d\d\d\d\-\d\d\-\d\d \d\d:\d\d:\d\d)
#			       )/;
my $xy_re =		     qr/(\d\d?)[,\-] ?(\d\d?)/;
my $outside_re =		qr/(Street|Park|Carpark|Cemetery|Wasteland|Monument)/i;
my $junkyard_re =	       qr/(Junkyard|Zoo)/i;
my $wit_server_offset = 0;      # E.g. 3600 if wit server clock 1 hour behind

my $debug = $ENV{'DEBUG'};				# set to 0 or 1; controls verbose logging

################################################################################
# Other global variables used by the bot.
################################################################################
my @target_channels;
my %targets;
my %greedy_disabled;
my %status;		     # Raw data for each x,y
my %target_status;	      # Cache of target status (description)
my %timestamp;
my %open_threads;
my %open_thread_names;
my %forum_posts;
my %op_required;		# Whether targets can only be set by IRC channel ops.
my %channel_prefs;
my @raw_config;
my $child;
my @stale_q;		    # Array of arrays in [timestamp, x, y] format;
my @reset_q;		    # Array of arrays in [timestamp, x, y] format;
my $next_stale_check = 0;       # Throttling timer for peforming next stale / reset update.

################################################################################
# Read in list of suburb and block names from file, and store in a hash.
################################################################################
my $mapfile = 'mapdata.dat';
my (@suburbs, @places, @wikinames, @buildingtypes);
&fill_map();

################################################################################
# Create the MediaWiki instance for read-only access.
#
# Acutal wiki updates are handled by a separate daemon which reads from file,
# (for centralized management of 'throttling' login errors).
################################################################################
my $udwikiapi = MediaWiki::API->new();
if (!$udwikiapi) {die "Failed to create new MediaWiki instance."}
$udwikiapi->{config}->{api_url} = 'http://wiki.urbandead.com/api.php';

my $irc = POE::Component::IRC::State->spawn (
	nick => $nickname,
	ircname => $ircname,
	username => $username,
	server => $server,
	flood => 1,	# Allow flooding.
) or die "Ooops $!";

POE::Session ->create (
	package_states => [
		main => [ qw(_default _start irc_001 irc_353 irc_msg irc_notice irc_invite irc_public irc_bot_addressed irc_bot_mentioned irc_bot_mentioned_action irc_bot_public irc_bot_msg) ],
	],
	heap => {irc => $irc },
);

$poe_kernel->run();
exit;

sub _start
{
	my ($kernel, $heap) = @_[KERNEL ,HEAP];

	# retrieve our component's object from the heap where we stashed it
	my $irc = $heap->{irc};

	# Initialise plugins
	$irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
	$irc->plugin_add( 'NickReclaim' => POE::Component::IRC::Plugin::NickReclaim->new() );
	$irc->plugin_add( 'NickServID', POE::Component::IRC::Plugin::NickServID->new(
		Password => $nickservpw
	));
	$irc->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(
		RejoinOnKick => 1,
		Retry_when_banned => 300,
	));
	$irc->plugin_add( 'BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new() );
	$irc->plugin_add( 'BotTraffic', POE::Component::IRC::Plugin::BotTraffic->new() );
	$irc->plugin_add( 'CTCP' => POE::Component::IRC::Plugin::CTCP->new(
		version => $ircname,
		userinfo => $ircname,
	));

	# Register for events and connect to server
	$irc->yield( register => 'all' );
	#$irc->yield( register => qw(irc_001 irc_353 irc_notice irc_msg irc_public irc_bot_addressed irc_bot_mentioned irc_bot_mentioned_action irc_bot_public irc_bot_msg) );
	$irc->yield( connect => { } );
	return;
}

# We registered for all events, this will produce some debug info.
 sub _default
{
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ( "$event: " );

	if ($event =~ /_child|irc_(00\d|2(5[1-5]|6[56])|33[23]|366|37[256]|ctcp.*|isupport|join|kick|mode|nick|part|ping|topic|quit)/) {
		# debug("EVENT: $event");  # Do not log these events except in debug mode.
	}
	else {
		for my $arg (@$args) {
			if ( ref $arg eq 'ARRAY' ) {
			   push( @output, '[' . join(' ,', @$arg ) . ']' );
			}
			else {
			   push ( @output, "'$arg'" );
			}
		}
		print join ' ', @output, "\n";
	}
	return 0;	# Don't handle signals.
}

# Fires once we're fully connected
sub irc_001
{
	my $sender = $_[SENDER];

	# Since this is an irc_* event, we can get the component's object by
	# accessing the heap of the sender. Then we register and connect to the
	# specified server.
	my $irc = $sender->get_heap();

	print "Connected to ", $irc->server_name(), "\n";

	# set mode +B = identify as bot
	$irc->yield( mode => "$nickname +B" );

	# we join our channels
	$irc->yield( join => $_ ) for @channels;

	################################	################################################
	# Notify our owner that we are starting up.
	################################################################################
	$irc->yield (notice => $ownernick => "\002BARHAH\002" );

	return;
}

# Nick list
sub irc_353
{
	my ($heap,$args) = @_[HEAP,ARG2];
	my $channel = lc $args->[1];
	my $nicklist = $args->[2];
	push @{ $heap->{NAMES}->{ $channel } }, ( split /\s+/, $nicklist );
	my $nickname = $irc->nick_name();
	$nicklist =~ s/$nickname //;
	print "In $channel with $nicklist \n";
}

################################################################################
# irc_public
#
# This subroutine is for regular posts to any of the channels we're in.
################################################################################
sub irc_public
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG3];
	my $nick = ( split /!/, $who )[0];
	my $channel = lc $where->[0];
	my $ownertest = $nick eq $ownernick;
	my $admintest = ($irc->is_channel_admin( $channel, $nick ) || $irc->is_channel_owner( $channel, $nick ) || $ownertest) ? 1 : 0;
	my $optest = ($irc->is_channel_operator( $channel, $nick ) || $admintest || $channel_prefs{$channel}{"auto_op"});
	$what = strip_color(strip_formatting($what));

	print "Received: $what in channel: $channel \n";
	
	################################################################################
	# !update block-style x_min,y_min x_max,y_max
	#
	# Update block-style for specified block(s).
	################################################################################
	if ($what =~ /^!update block-style $xy_re( $xy_re)?/i && $ownertest)
	{
		my $x_min = $1;
		my $y_min = $2;

		my $x_max = $4 ? $4 : $1;
		my $y_max = $5 ? $4 : $2;

		my $start_time = time();

		for (my $x = $x_min; $x <= $x_max; $x++)
		{
			for (my $y = $y_min; $y <= $y_max; $y++)
			{
				update_block_style($x,$y, "Force update requested by $nick in $channel");
			}
		}
		my $duration = time() - $start_time;
		
		$irc->yield (notice => $nick => "Updated block-style for $x_min,$y_min - $x_max,$y_max ($duration seconds)");
	}

	################################################################################
	# !delete x_min,y_min x_max,y_max
	#
	# Delete all specified block data from memory.
	################################################################################
	elsif ($what =~ /^!delete $xy_re $xy_re/i && $ownertest)
	{
		my $x_min = $1;
		my $y_min = $2;

		my $x_max = $3;
		my $y_max = $4;

		my $start_time = time();

		for (my $x = $x_min; $x <= $x_max; $x++)
		{
			for (my $y = $y_min; $y <= $y_max; $y++)
			{
				delete $status{$x,$y};
			}
		}
		my $duration = time() - $start_time;
		$irc->yield (notice => $nick => "Deleted map data for $x_min,$y_min - $x_max,$y_max ($duration seconds)");
		
	}

	################################################################################
	# !delete x,y
	#
	# Delete all data associated with the specified x,y.
	################################################################################
	elsif ($what =~ /^!delete *$xy_re/i && $ownertest)
	{
		my $x = $1;
		my $y = $2;

		if (exists $status{$x,$y})
		{
			delete $status{$x,$y};
			$irc->yield (notice => $nick => "Deleted map data for $x,$y");
			
		}
		else
		{
			$irc->yield (notice => $nick => "No data found for $x,$y!");
		}
	}

	################################################################################
	# For testing: !tea
	################################################################################
	elsif ($what =~ /^!tea(.*)/i)
	{
		my $greeting = "Hello, $nick.  Have a nice cup of$1 tea.. ";

		$irc->yield (privmsg => $channel => $greeting);
		log_msg ("Dispensing tea to $nick in $channel...");
	}

	################################################################################
	# For testing: !buildmap
	################################################################################
	elsif ($what =~ /^!buildmap $xy_re $xy_re/)
	{
		my $x_min = $1;
		my $y_min = $2;

		my $x_max = $3;
		my $y_max = $4;

		my $greeting = "Building map for $x_min,$y_min .. $x_max, $y_max";
		debug ($greeting);
		$irc->yield (privmsg => $channel => $greeting);

		my $wikitext = buildmap($x_min, $x_max, $y_min, $y_max);

		my $err_rsp = update_wiki("User:$wikiuser/RRF-map", "testing map build", $wikitext);
		if ($err_rsp) {$irc->yield (privmsg => $channel => $err_rsp)}
	}
}

################################################################################
# irc_msg
#
# This subroutine is for any Private Messages we receive.
################################################################################
sub irc_msg
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $nick = ( split /!/, $who )[0];
	my $ownertest = $nick eq $ownernick;
	$what = strip_color(strip_formatting($what));

	print "NOTICE: <$who> $what\n";
}

################################################################################
# irc_notice
#
# This subroutine is for any NOTICE messages we see in the channels we're in.
#
# Per RFC 1459 we must never respond to these (at least in the channel), to
# prevent message loops with other bots.
################################################################################
sub irc_notice
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $nick = ( split /!/, $who )[0];
	my $ownertest = $nick eq $ownernick;
	$what = strip_color(strip_formatting($what));

	print "NOTICE: <$who> $what\n";
}

################################################################################
# irc_invite
#
# This subroutine is for when we're invited to join a new channel.
################################################################################
sub irc_invite
{
	my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
	my $nick = ( split /!/, $who )[0];

	print "I was invited to $where by $nick\n";
	$irc->yield( join => $where );
	$irc->yield (privmsg => $where => "Hi $nick! Thanks for the invite! If you\'d like to add this channel to my autojoin, please contact my owner, Rick");
}

################################################################################
# irc_bot_addressed
################################################################################
sub irc_bot_addressed
{
	my ($kernel, $heap) = @_[KERNEL, HEAP];
	my $nick = ( split /!/, $_[ARG0] )[0];
	my $channel = lc $_[ARG1]->[0];
	my $what = $_[ARG2];

	print "Addressed: $channel: <$nick> $what\n";
}

################################################################################
# irc_bot_mentioned
################################################################################
sub irc_bot_mentioned
{
	my ($nick) = ( split /!/, $_[ARG0] )[0];
	my ($channel) = lc $_[ARG1]->[0];
	my ($what) = $_[ARG2];

	print "Mentioned: $channel: <$nick> $what\n";
}

################################################################################
# irc_bot_mentioned_action
################################################################################
sub irc_bot_mentioned_action
{
	my ($nick) = ( split /!/, $_[ARG0] )[0];
	my ($channel) = lc $_[ARG1]->[0];
	my ($what) = $_[ARG2];

	print "irc_bot_mentioned_action $channel: * $nick $what\n";
}

sub irc_bot_public
{
     my ($kernel, $heap) = @_[KERNEL, HEAP];
     my $channel = lc $_[ARG0]->[0];
     my $what = $_[ARG1];

     print strip_color(strip_formatting("irc_bot_public $channel: <$nickname> $what\n"));
     return;
}

sub irc_bot_msg
{
     my ($kernel, $heap) = @_[KERNEL, HEAP];
     my $nick = $_[ARG0]->[0];
     my $what = $_[ARG1];

     print strip_color(strip_formatting("I said '$what' to user $nick\n"));
     return;
}


sub trim
{
	my $what = $_[0];
	$what =~ s/^\!\w+ //i;
	return $what;
}

################################################################################
# Read from file:
# - all 100 suburb names
# - all 10,000 block names, e.g. 'a factory'
# - all 10,000 wiki names, e.g. 'a factory (94,95)'
################################################################################
sub fill_map
{
	print "Filling map...";
	open MAPDATA, $mapfile or die "FAILED - $!\n";
	chomp(my @lines = <MAPDATA>);
	close MAPDATA;  
	my $line;
	for(my $y = 0; $y < 10; $y++) { for(my $x = 0; $x < 10; $x++) { $suburbs[$x][$y] = $lines[$line++]; } }
	for(my $i = 0; $i < 100; $i++) { for(my $k = 0; $k < 100; $k++) { $places[$i][$k] = $lines[$line++]; } }
	for(my $i = 0; $i < 100; $i++) { for(my $k = 0; $k < 100; $k++) { $wikinames[$i][$k] = $lines[$line++]; } }
	for(my $x = 0; $x < 100; $x++) { for(my $y = 0; $y < 100; $y++) { $buildingtypes[$x][$y] = $lines[$line++]; } }
	print "DONE!\n";
}

################################################################################
# update_wiki()
#
# - store the new page contents in our cache
# - write the new page contents to a file in our working directory, where it
#   will be picked up by a separate daemon for the wiki edit.
#
# Returns: empty string if successful, otherwise description of the error.
################################################################################
sub update_wiki
{
	my $pagename =  $_[0];	  # e.g. User:TargetReport/RRF
	my $summary =   $_[1];	  # e.g. Wit submitted by Rick in #gore
	my $newpage =   $_[2];	  # New page contents

	debug ("update_wiki($pagename, $summary, $newpage)");

	################################################################################
	# First generate the correct filename, e.g.
	# /opt/targetbot/TargetReport/56,47
	# /opt/targetbot/TargetReport/56,47-style
	################################################################################
	my $wiki_filename;
	if ($pagename =~ /^User:(.*)/)
	# if ($pagename =~ /^User:TargetReport\/(.*)/)
	{
		$wiki_filename = "$1";
	}
	else {
		log_msg ("Unexpected pagename: $pagename");
		return "Unexpected pagename: $pagename"
	}

	################################################################################
	# Just dump the new page contents to the file, and close it again.
	################################################################################
	log_msg ("Writing newpage to $wiki_filename");

	open (my $file, ">$wiki_filename") or return "Could not open $wiki_filename $!";
	print $file "$summary\n";
	print $file $newpage;
	close ($file);
	return "";
}

################################################################################
# debug()
#
# - Debug mode (only): write to stdout
################################################################################
sub debug
{
	my $log_text =  $_[0];	  # e.g. "Rick said BARHAH in #gore"
	if ($debug) {
		print "$log_text\n";
	}
}

################################################################################
# log_msg()
#
# - Write to stdout.
################################################################################
sub log_msg
{
	my $log_text = $_[0];	   # e.g. "Rick submitted wit in #gore"
	print "$log_text \n";
}

################################################################################
# alert()
#
# - Write to stderr
################################################################################
sub alert
{
	my $log_text = $_[0];	   # e.g. "Wiki update failed"
	warn $log_text;
}

################################################################################
# buildmap()
#
# Returns: err_rsp
################################################################################
sub buildmap
{
	my $x_min = $_[0];
	my $x_max = $_[1];
	my $y_min = $_[2];
	my $y_max = $_[3];

	my $div_style = qq(style="background-color:#2a1818; color:white; font-size:200%; font-weight:bold;" align="center");
	my $table_style = qq(style="margin: 0px; border-spacing:2px; font-size:10px; text-align:center; background:#2a1818; color:white;");
	my $tr_style = qq(style="height:64px");

	################################################################################
	# <div style="...">
	################################################################################
	my $wikitext = qq(<div $div_style>\n);

	################################################################################
	# <table style="...">
	################################################################################
	$wikitext .= qq(<table $table_style>\n);

	################################################################################
	# <tr>
	################################################################################
	$wikitext .= qq(<tr>\n);

	################################################################################
	# <td >     - top left corner
	################################################################################
	$wikitext .= qq(<td style="width:15px">&nbsp;</td>\n);

	################################################################################
	# <td >     - header cell for each column
	################################################################################
	my $col_count = 2;	      # Count total number of columns, including
					# grid co-ord columns on each side of the map.
	foreach my $xi ($x_min .. $x_max)
	{
	    ################################################################################
	    # Include a vertical suburb boundary (vertical bar) if we're at a boundary.
	    ################################################################################
	    if (($xi % 10) == 0)
	    {
		$wikitext .= qq(<td style="width:2px; background:black;"></td>\n);
		$col_count += 1;
	    }

	    $wikitext .= qq(<td style="width:100px">$xi</td>\n);
	    $col_count += 1;
	}

	################################################################################
	# <td >     - top right corner
	################################################################################
	$wikitext .= qq(<td style="width:15px">&nbsp;</td>\n);

	################################################################################
	# </tr>
	################################################################################
	$wikitext .= qq(</tr>\n);

	################################################################################
	# Now generate each row in the main table...
	################################################################################
	foreach my $yi ($y_min .. $y_max)
	{
	    ################################################################################
	    # First, insert a suburb divider (horizontal bar) if we're at a boundary.
	    ################################################################################
	    if (($yi % 10) == 0)
	    {
		$wikitext .= qq(<tr><td colspan="$col_count" style="background:black; height:2px"></td></tr>\n);
	    }

	    ################################################################################
	    # <tr style="..">
	    ################################################################################
	    $wikitext .= qq(<tr $tr_style>\n);

	    ################################################################################
	    # First column displays the y co-ordinate for this row.
	    ################################################################################
	    $wikitext .= qq(<td>$yi</td>\n);

	    ################################################################################
	    # Now include a table cell for each x,y in this row.
	    ################################################################################
	    foreach my $xi ($x_min .. $x_max)
	    {
		################################################################################
		# Include a vertical suburb boundary (vertical bar) if needed.
		################################################################################
		if (($xi % 10) == 0)
		{
		    $wikitext .= qq(<td style="width:2px; background:black;"></td>\n);
		}

		################################################################################
		# Now insert the main x,y table cell.
		################################################################################
		$wikitext .= qq(<td style="{{../$xi,$yi-style}}">{{../$xi,$yi-block}}</td>\n);
	    }

	    ################################################################################
	    # Last column displays the y co-ordinate for this row.
	    ################################################################################
	    $wikitext .= qq(<td>$yi</td>\n);

	    ################################################################################
	    # </tr>
	    ################################################################################
	    $wikitext .= qq(</tr>\n);
	}

	################################################################################
	# Insert a final suburb divider (horizontal bar) if we ended at a boundary.
	################################################################################
	if ((($y_max + 1) % 10) == 0)
	{
	    $wikitext .= qq(<tr><td colspan="$col_count" style="background:black; height:2px"></td></tr>\n);
	}

	################################################################################
	# <tr>
	# <td>     - bottom left corner
	################################################################################
	$wikitext .= qq(<tr>\n);
	$wikitext .= qq(<td style="width:15px">&nbsp;</td>\n);

	################################################################################
	# <td >     - footer cell for each column
	################################################################################
	foreach my $xi ($x_min .. $x_max)
	{
	    ################################################################################
	    # Include a vertical suburb boundary (vertical bar) if we're at a boundary.
	    ################################################################################
	    if (($xi % 10) == 0)
	    {
		$wikitext .= qq(<td style="width:2px; background:black;"></td>\n);
	    }

	    $wikitext .= qq(<td style="width:100px">$xi</td>\n);
	}

	################################################################################
	# <td >     - bottom right corner
	################################################################################
	$wikitext .= qq(<td style="width:15px">&nbsp;</td>\n);

	################################################################################
	# </tr>
	# </table>
	# </div>
	################################################################################
	$wikitext .= qq(</tr>\n);
	$wikitext .= qq(</table>\n);
	$wikitext .= qq(</div>\n);

	return $wikitext;
}

################################################################################
# update_block_style()
#
# Returns:
################################################################################
sub update_block_style
{
	my $x =	 $_[0];	  # e.g. 56
	my $y =	 $_[1];	  # e.g. 47
	my $summary =   $_[2];	  # e.g. "Submitted by Rick in #gore"

	################################################################################
	# First extract the parameters we need from the x,y page for generating the
	# correct block and style pages.
	################################################################################
	my $buildingtype = $buildingtypes[$x][$y];
	my $special_format = &special_format($x, $y);

	my $name = $places[$x][$y];
	my $suburb = suburb($x, $y);
	my $maplink = maplink($x, $y);

	my $status = $status{$x,$y}{"status"};
	my $litstatus = $status{$x,$y}{"lit"};
	my $cadestatus = $status{$x,$y}{"cades"};
	my $striketarget = $status{$x,$y}{"striketarget"};

	my $in = $status{$x,$y}{"in"};
	my $inwit = $status{$x,$y}{"inwit"};
	my $out = $status{$x,$y}{"out"};
	my $outwit = $status{$x,$y}{"outwit"};

	my $status_timestamp = $status{$x,$y}{"status_timestamp"};
	my $cades_timestamp = $status{$x,$y}{"cades_timestamp"};
	my $strike_timestamp = $status{$x,$y}{"strike_timestamp"};
	my $in_timestamp = $status{$x,$y}{"in_timestamp"};
	my $out_timestamp = $status{$x,$y}{"out_timestamp"};

	################################################################################
	# Ignore strike targets which are more than 48h old.
	################################################################################
	my $_24h = time() - 86400;	      # System time 24h ago
	my $_48h = $_24h - 86400;	       # System time 48h ago

	if ($striketarget)
	{
		unless ($strike_timestamp and $strike_timestamp > $_48h)
		{
			$striketarget = "";
		}
	}
	
=begin comment
	################################################################################
	# Ignore survivor data that is more than a week old.
	################################################################################
	my $_1w = $_48h - (432000);	     # System time 7 days ago

	if ($in or $inwit)
	{
		unless ($in_timestamp and $in_timestamp > $_1w)
		{
			$in = "";
			$inwit = "";
		}
	}

	if ($out or $outwit)
	{
		unless ($out_timestamp and $out_timestamp > $_1w)
		{
			$out = "";
			$outwit = "";
		}
	}

	################################################################################
	# Ignore cade and lit data that is more than a week old.
	################################################################################
	if ($cadestatus)
	{
		$cadestatus = "" unless ($cades_timestamp and $cades_timestamp > $_1w);
	}

	if ($litstatus)
	{
		$litstatus = "" unless ($status_timestamp and $status_timestamp > $_1w);
	}

	################################################################################
	# Ignore status info that is more than a month (30 days) old.
	################################################################################
	my $_1m = $_1w - (1987200);	     # System time 30 days ago

	if ($status)
	{
		$status = "" unless ($status_timestamp and $status_timestamp > $_1m);
	}
=end comment
=cut

	################################################################################
	# Figure out the most recent timestamp.
	################################################################################
	my @timestamps = (0);

	push (@timestamps, $status_timestamp)   if ($status_timestamp);
	push (@timestamps, $cades_timestamp)    if ($cades_timestamp);
	push (@timestamps, $in_timestamp)       if ($in_timestamp);
	push (@timestamps, $out_timestamp)      if ($out_timestamp);
	push (@timestamps, $strike_timestamp)   if ($strike_timestamp);

	my $wit_time = max @timestamps;

	################################################################################
	# Generate the style page first, and write to the wiki.
	################################################################################
	my $td_style_page = td_block_style($buildingtype,
					   $status,
					   $litstatus,
					   $cadestatus,
					   $striketarget,
					   $wit_time,
					   $special_format,
					   $in);
	update_wiki("User:$wikiuser/$x,$y-style", $summary, $td_style_page);

	################################################################################
	# Now the block page:
	################################################################################
	my $td_block_page = td_block_data($buildingtype,
					  $status,
					  $litstatus,
					  $cadestatus,
					  $name,
					  $maplink,
					  $in,
					  $inwit,
					  $out,
					  $outwit);
	update_wiki("User:$wikiuser/$x,$y-block", $summary, $td_block_page );

	return "";
}

################################################################################
# td_block_style()
#
# Generates the td 'style' data for the given block, based on the ruin, cade
# status etc.
#
# - Returns the relevant wiki text to use, e.g:
#   background:#331; border:dotted 2px #662;
################################################################################
sub td_block_style
{
	my $buildingtype =		$_[0];	  # e.g. Junkyard Club	    Street
	my $status =	    	$_[1];	  # e.g. Ruined   Repaired	""
	my $lit =	       		$_[2];	  # e.g. Lit	      Unlit	   ""
	my $cades =	     		$_[3];	  # e.g. EHB	      Open	    ""
	my $striketarget =  	$_[4];	  # e.g. EHB	      Open	    ""
	my $wit_time =	  		$_[5];	  # e.g. EHB	      Open	    ""
	my $special_format =	$_[6];	  # e.g. EHB	      Open	    ""
	my $in =				$_[7];	  # e.g. 5		0	       ""

	my $style = "";

	# debug("td_block_style($buildingtype, $status, $lit, $cades, $striketarget, $wit_time, $special_format, $in)");

	################################################################################
	# Street locations just inherit the background colour of the parent table.
	################################################################################
	if ($buildingtype =~ /$outside_re/)
	{
		return "";
	}

	################################################################################
	# We're dealing with a building (not a street).
	#
	# First check for open buildings with survivors inside: highlighted green.
	################################################################################
	if ($cades and ($cades eq 'Open') and $in)
	{
		$style .= "background:lime; ";

		################################################################################
		# Also set a suitable border if this open building is already ruined.
		################################################################################
		if ($status and ($status eq 'Ruined'))
		{
			$style .= "border:dotted 2px #662; ";
		}
	}
	################################################################################
	# Default: not an open building with survivors inside.
	#
	# Start by checking ruined / repaired status:
	################################################################################
	elsif ($status and ($status eq 'Ruined'))
	{
		################################################################################
		# RUINS
		#
		# Lit ruins are a lurid yellow-brown (aka 'goldenrod').
		# Unlit ruins are a lovely dark green colour.
		################################################################################
		if ($lit eq 'Lit')
		{
			$style .= "background:goldenrod; "
		}
		else
		{
			$style .= "background:#331; "
		}

		################################################################################
		# Set the border based on what cades are present (if any).
		################################################################################
		if ($cades =~ /HB/)				{ $style .= "border:double 4px #662; "}
		elsif ($cades =~ /^VSB/)		{ $style .= "border:dotted 2px red; "}
		elsif ($cades =~ /^QSB/)		{ $style .= "border:dotted 2px orange; "}
		elsif ($cades =~ /^Lightly/)	{ $style .= "border:dotted 2px yellow; "}
		elsif ($cades =~ /^Loosely/)	{ $style .= "border:dotted 2px green; "}
		else 							{ $style .= "border:dotted 2px #662; "}
	}
	else
	{
		################################################################################
		# REPAIRED BUILDINGS (incl. junkards):
		#
		# - First check if it's a strike target (background colour red)
		################################################################################
#	       if ($striketarget)
#	       {
#		       $style .= "background:#c20; ";
#	       }

		################################################################################
		# Not a strike target so use standard colours:
		#
		# - Normal repaired buildings have a dull grey background.
		# - Junkyards don't have a 'status' field and have a brown background.
		################################################################################
#	       elsif (defined($status))
		unless ($buildingtype =~ /$junkyard_re/)
		{
			$style .= "background:#777; ";
		}
		else
		{
			$style .= "background:#432; ";  # Junkyards and zoo enclosures.
		}

		################################################################################
		# Set the border based on what cades are present (if any).
		################################################################################
		if ($cades) {
			if ($cades =~ /^EHB/)	   { $style .= "border:double 4px #000; "}
			elsif ($cades =~ /^VHB/)	   { $style .= "border:double 4px #111; "}
			elsif ($cades =~ /^HB/)	    { $style .= "border:double 4px #222; "}
			elsif ($cades =~ /^VSB/)	   { $style .= "border:dashed 3px black; "}
			elsif ($cades =~ /^QSB/)	   { $style .= "border:dotted 2px orange; "}
			elsif ($cades =~ /^Lightly/)       { $style .= "border:dotted 2px yellow; "}
			elsif ($cades =~ /^Loosely/)       { $style .= "border:dotted 2px lime; "}
			elsif ($cades =~ /^Open/) {
				################################################################################
				# OPEN buildings:
				#
				# Green border, except for Junkyards, which have the same border as open Ruins.
				################################################################################
				if (defined($status))	   # Excludes junkyards etc.
				{
					$style .= "border:solid 3px lime; ";
				}
				else
				{
					$style .= "border:dotted 2px #662; ";
				}			
			}
		}
	}

	################################################################################
	# If this location is a strike target, highlight the border in red / orange.
	#
	# This overrides other formatting.
	################################################################################
	if ($striketarget)
	{
		$style .= ($status and $status eq 'Ruined') ? "border:dotted 2px " : "border:solid 6px ";
		if ($striketarget =~ /^1:/)
		{
			$style .= "red; "       # primary target: red
		}
		else
		{
			$style .= "orange; "    # secondary: orange
		}
	}
	else
	{
		################################################################################
		# If this location has *never* been updated, black out with opacity 20%.
		################################################################################
		if (defined($status) and !($status))
		{
			$style .= "opacity:0.2; ";

			################################################################################
			# Highlight with a white / grey border if it's an interesting TRP
			# (tactical resource point).
			################################################################################
			if (grep { $buildingtype eq $_ } ['Hospital',
					      'Police Stations',
					      'NecroTech',
					      'Factory',
					      'Warehouse',
					      'Fire Station',
					      'Auto Repair',
					      'Power Station',
					      'Armory',
					      'Mall'])
			{
				$style .= "border:solid 2px #aaa; ";
			}
		}

		################################################################################
		# Otherwise, grey out if the info is out of date.
		################################################################################
		elsif (time() - $wit_time > $stale_interval)      # More than 24h old..
		{
			$style .= "opacity:0.5; "
		}

		################################################################################
		# Apply any special formating for this location.
		################################################################################
		$style .= $special_format if ($special_format);
	}

	debug("td_block_style() -> $style");

	return $style;
}

################################################################################
# td_block_data()
#
# Generates the td 'block' data for the given block, based on the ruin, cade
# status etc.
#
# - Returns the relevant wiki text to use when displaying block status in a table.
################################################################################
sub td_block_data
{
	my $buildingtype =      $_[0];	  # e.g. Junkyard Club	    Street
	my $status =	    $_[1];	  # e.g. Ruined   Repaired	""
	my $lit =	       $_[2];	  # e.g. Lit	      Unlit	   ""
	my $cades =	     $_[3];	  # e.g. EHB	      Open	    ""
	my $name =	      $_[4];	  # e.g. the Scott Motel
	my $maplink =	   $_[5];	  # e.g. Shearbank-Roachtown
	my $in =		$_[6];	  # e.g. 0	1       5+      ""
	my $inwit =	     $_[7];	  # e.g. http://iamscott.net/1382218354759.html
	my $out =	       $_[8];	  # e.g. ""       0       1       5+
	my $outwit =	    $_[9];	  # e.g. ""

#       $status = "" unless defined ($status);
#       $lit = "" unless defined ($lit);
#       $cades = "" unless defined ($cades);

	################################################################################
	# 1) Set the background colour for the building name, based on Lit, Ruin etc
	################################################################################
	my $name_style;
	if ($lit and $lit eq 'Lit')
	{
		###############################################################################
		# LIT buildings:
		#
		# YELLOW background with a border indicating the building type if appropriate:
		# - black border for (lit) dark buildings
		# - red border for (lit) fire stations etc.
		###############################################################################
		$name_style = "background:yellow; color:black; ";

		if (grep(/$buildingtype/, ['Club', 'Bank', 'Cinema', 'Armory']))
													{$name_style .= "border:solid 2px black;"}
		elsif ($buildingtype eq 'Hospital')	  		{$name_style .= "border:solid 2px #D66;"}
		elsif ($buildingtype eq 'Police Station')	{$name_style .= "border:solid 2px #66B;"}
		elsif ($buildingtype eq 'NecroTech')	    {$name_style .= "border:solid 2px #B02;"}
	}
	else
	{
		###############################################################################
		# UNLIT buildings:
		#
		# - BLACK background for dark buildings (even when ruined).
		# - RED background for Fire Stations, Blue for PDs etc (unless ruined)
		###############################################################################
		$name_style = "color:white; ";
		if (grep { $buildingtype eq $_ } ['Club', 'Bank', 'Cinema', 'Armory'])
		{
			$name_style .= "background:black; ";
		}
		elsif (!($status and $status eq 'Ruined'))
		{
			if ($buildingtype eq 'Hospital')			{$name_style .= "background:#D66;"}
			elsif ($buildingtype eq 'Police Station')	{$name_style .= "background:#66B;"}
			elsif ($buildingtype eq 'NecroTech')		{$name_style .= "background:#B02;"}
		}
	}

	###############################################################################
	# Add suitable CSS style="" code if there's any style to apply.
	###############################################################################
	if (defined($name_style))
	{
		$name_style = "style=\"$name_style\"";
	}

	###############################################################################
	# 2) Generate the hover text to display for this block (excluding street
	#    locations).
	###############################################################################
	my $title = "";

	unless (grep { $buildingtype eq $_ } [ 'Street', 'Park', 'Carpark', 'Cemetery', 'Wasteland', 'Monument'])
	{
		if (!defined($status))		  # Junkyards etc.
		{
			if ($cades)
			{
				$title = $cades;
			}
			elsif ($lit) {
				$title = $lit;
			}
			else
			{
				$title = "Unknown";
			}
		}
		elsif ($status eq 'Ruined')
		{
			$title = "Ruined $cades"

		}
		else
		{
			$title = ($cades) ? $cades : "Repaired (cades unknown)";
		}
	}

	if ($title)
	{
		$title = "title=\"$title\"";
	}

	###############################################################################
	# 3) Generate the hyperlink styles for any wit links to display.
	###############################################################################
	my $inlink = "";
	my $inwit_style = "";
	if (defined($in) and defined($inwit) and $inwit)
	{
		if ($in ne "0")
		{
			$inwit_style = "style=\"background:lime; border:dotted 2px #662; font-size:120%\"";
		}
		$inlink = "[$inwit $in]";
	}

	my $outlink = "";
	my $outwit_style = "";

	if ($outwit)
	{
		if ($out ne "0")
		{
			$outwit_style = "style=\"background:lime; font-size:120%\"";
			$outlink = "<br />[$outwit +$out]";
		}
	}

	###############################################################################
	# Now create the actual CSS content for the wiki page.
	###############################################################################
	my $td_span_style = "style=\"width:75%; line-height:normal; display:inline-block; vertical-align:middle; text-align:center\"";

	my $td_data = "";
	$td_data .= "<span $td_span_style>[[User:$wikiuser/$maplink|<span $name_style $title>$name</span>]]</span><span style=\"width:15%; display:inline-block; vertical-align:middle; text-align:right; font-size:125%;\"><span $inwit_style>$inlink</span><span $outwit_style>$outlink</span></span>";

	return $td_data;
}

################################################################################
# special_format()
#
# - return any special formating to use for this x,y
################################################################################
sub special_format
{
	my $x = $_[0];
	my $y = $_[1];

	my $wikiname = $wikinames[$x][$y];
	my $special_format = "";

	################################################################################
	# Check the 4 blocks immediately to the N, E, S and W.
	#
	# If the wikiname matches, it's the same building, so remove the border on that
	# side.
	################################################################################
	$special_format .= "border-left-style:none; "   if ($x > 0 and $wikinames[$x-1][$y] eq $wikiname);
	$special_format .= "border-right-style:none; "  if ($x < 99 and $wikinames[$x+1][$y] eq $wikiname);
	$special_format .= "border-top-style:none; "    if ($y > 0 and $wikinames[$x][$y-1] eq $wikiname);
	$special_format .= "border-bottom-style:none; " if ($y < 99 and $wikinames[$x][$y+1] eq $wikiname);

	return $special_format;
}

################################################################################
# suburb(x, y) - returns the suburb name for this x,y
################################################################################
sub suburb
{
	my $x = $_[0];
	my $y = $_[1];

	my $xx = int($x/10);
	my $yy = int($y/10);

	return $suburbs[$xx][$yy];
}

################################################################################
# maplink(x, y) - returns the nearest 10x10 suburb map name for this x,y
# (e.g. Roachtown-Ridleybank for 55,40)
################################################################################
sub maplink
{
	my $x = $_[0];
	my $y = $_[1];
	my $maplink;

	################################################################################
	# First calculate where in the 10x10 block we are (e.g 54,46 would be 4,6).
	################################################################################
	my $xi =  $x % 10;      # Returns a value between 0 - 9
	my $yi =  $y % 10;      # Returns a value between 0 - 9

	################################################################################
	# Now construct the suburb name based on which sector of the 10x10 we're in.
	# Start with the corners.
	################################################################################
	if ($xi <= 1 and $yi <= 1 and $x >= 10 and $y >= 10)
	{
		$maplink = &suburb(eval($x-10), eval($y-10)) . "-" . &suburb(eval($x), eval($y-10)) . "-" .
			&suburb(eval($x-10), eval($y)) . "-" . &suburb(eval($x), eval($y));
	}
	elsif (($xi >= 8) and ($yi <= 1) and $x < 90 and $y >= 10) {
		$maplink = &suburb(eval($x), eval($y-10)) . "-" . &suburb(eval($x+10), eval($y-10)) . "-" .
			&suburb(eval($x), eval($y)) . "-" . &suburb(eval($x+10), eval($y))
	}
	elsif (($xi <= 1) and ($yi >= 8) and $x >= 10 and $y <= 90) {
		$maplink = &suburb(eval($x-10), eval($y)) . "-" . &suburb(eval($x), eval($y)) . "-" .
			&suburb(eval($x-10), eval($y+10)) . "-" . &suburb(eval($x), eval($y+10));
	}
	elsif (($xi >= 8) and ($yi >= 8) and $x < 90 and $y < 90) {
		$maplink = &suburb(eval($x), eval($y)) . "-" . &suburb(eval($x+10), eval($y)) . "-" .
			&suburb(eval($x), eval($y+10)) . "-" . &suburb(eval($x+10), eval($y+10))
	}
	################################################################################
	# Now handle the edges.
	################################################################################
	elsif ($yi <= 1 and $y >= 10) {
		$maplink = &suburb(eval($x), eval($y-10)) . "-" . &suburb(eval($x), eval($y));
	}
	elsif ($yi >= 8 and $y < 90) {
		$maplink = &suburb(eval($x), eval($y)) . "-" . &suburb(eval($x), eval($y+10));
	}
	elsif ($xi <= 1 and $x >= 10) {
		$maplink = &suburb(eval($x-10), eval($y)) . "-" . &suburb(eval($x), eval($y));
	}
	elsif ($xi >= 8 and $x < 90) {
		$maplink = &suburb(eval($x), eval($y)) . "-" . &suburb(eval($x+10), eval($y));
	}
	################################################################################
	# Nothing left now except the middle (main suburb page).
	################################################################################
	else {$maplink = &suburb(eval($x), eval($y))}
	return $maplink;
}