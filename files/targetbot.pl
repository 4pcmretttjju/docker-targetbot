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

# Used by the bot
my ($nickname, $username, $ircname) = $ENV{'NICK'};
my $server = $ENV{'SERVER'}; ;
my $nickservpw = $ENV{'NS_PASS'};
my @ownerchannels = split(',', $ENV{'OWNER_CHANNELS'});
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

# my $debug = '';						# set to 'true' to enable debug
my $debug = 'true';						# set to 'true' to enable debug

################################################################################
# The following settings can be overwritten by a configuration file.
################################################################################
my $logchannel = "#targetbot-log";
my @verbose_channels;	   # Targets are published on the wiki.
my @quiet_channels;	     # Targets are private to the IRC channel.

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
	$irc->yield( join => $logchannel );

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
	
	# say ("whaaat: $what");
	# return;

	################################################################################
	# Parse the nick list to check if StrikeBot is present in this channel.
	#
	# We can perform StrikeBot function if StrikeBot is not present.
	################################################################################
	$irc->yield (names => "$channel");
	my $nicklist = join(' ', $irc->channel_list($channel));
	my $strikebot_present = ($nicklist  =~ /\bStrikeBot\b/);

	################################################################################
	# Always ignore messages in our logging channel (to prevent loops).
	################################################################################
	return if ($channel eq $logchannel);

	################################################################################
	# If someone requests target status with !t or initiates a !strike, report the
	# target's (or targets') status to the channel.
	#
	# Also ping everyone for !strike unless StrikeBot is already present.
	################################################################################
	if (($what =~ /^!t(arget)*s*$/i) || ($what =~ /^!strike$/i && $optest))
	{
		################################################################################
		# Never ping #rrf-wc, just report the status of ALL targets.
		################################################################################
		if ($channel eq "#rrf-wc")
		{
			 foreach my $sub_channel ('#gore', '#rrf-ud', '#constable')
			 {
				 my @target_results = &report_status($channel_prefs{$sub_channel}{"target"});
				 $irc->yield ( privmsg => $channel => $_) for (@target_results);
			 }
		}
		else
		{
			################################################################################
			# For all other channels, first perform the !strike ping if required.
			################################################################################
			if ($what =~ /^!strike$/i && $optest)
			{
				$irc->yield (names => "$channel");
				my $nicklist = join(' ', $irc->channel_list($channel));
				unless ($strikebot_present)
				{
					$nicklist  =~ s/.?Moonie|TargetBot //g;
					$irc->yield (privmsg => $channel => "\002STRIKE TIME!\002 " . $nicklist);

					################################################################################
					# Build a dssrzs map showing the target, e.g.
					# - http://dssrzs.org/map/location/85-90 for a single target
					# - http://dssrzs.org/map/route/85-90-87-88 for multiple targets.
					################################################################################
					my $target_string = "\002TARGET(S):\002 " ;

					my @target_list = ($channel_prefs{$channel}{"target"} =~ /$xy_re/g);

					if (scalar @target_list == 2)
					{
						$target_string .= "http://dssrzs.org/map/location/";
					}
					elsif (scalar @target_list >= 4)
					{
						$target_string .= "http://dssrzs.org/map/route/";
					}

					while (scalar @target_list > 1)
					{
						my $x = shift(@target_list);
						my $y = shift(@target_list);
						$target_string .= "$x\-$y\-";
					}

					chop($target_string);   # Remove the final dash (or space) from the end of the string.

					$irc->yield (notice => $channel => $target_string);
				}
			}
			my @target_results = &report_status($channel_prefs{$channel}{"target"});
			$irc->yield ( privmsg => $channel => $_) for (@target_results);
		}
	}
	################################################################################
	# If someone updates the target list with !settarget, !remove target etc - then
	# update our target too.
	#
	# Some commands can only be performed by a channel operator.
	################################################################################
	elsif (($what =~ /^!setorders (.+)$/i || $what =~ /^!settarget (.+)$/i) && $optest)
	{
		my $target_string = $1;

		################################################################################
		# First clear any existing targets for this channel (including updating the
		# wiki so they're no longer highlighted in red).
		################################################################################
		my $err_rsp = remove_target($channel);
		$irc->yield (privmsg => $channel => $err_rsp) if ($err_rsp);

		################################################################################
		# If the specified target is actually a wit, then parse it first, and pull the
		# the target x,y from the parse text.
		################################################################################
		if ($what =~ /$wit_re/)
		{
			my $wit = $1;
			log_msg ("Parsing wit: $wit");

			################################################################################
			# Always update the wiki page (and open buildings, if appropriate) when
			# setting a target using a wit.
			################################################################################
			my $commit = 1;
			my $force_post = ($what =~ /!post/);

			$target_string = parse_wit($wit, $nick, $channel, $commit, $force_post);
		}
		else
		{
			my @target_results = &report_status($target_string);
			$irc->yield ( privmsg => $channel => $_) for (@target_results);
		}

		################################################################################
		# Next store the specified target string in our hash.
		################################################################################
		$channel_prefs{$channel}{"target"} = "$target_string";

		log_msg ("Target set for $channel: $target_string");

		unless ($strikebot_present)
		{
			$irc->yield (notice => $nick => "Target List Filled & Set");
		}

		################################################################################
		# Also update User:TargetReport/RRF wiki page which tracks status of targets,
		# for verbose channels only.
		################################################################################
		if (grep { /$channel/ } @verbose_channels)
		{
			my $targets_text;
			my $map_text;
			my $target_count = 1;	   # 1 for primary, 2 for secondary, etc
			my $summary;
			my $curr_time = time();

			while ($target_string =~ /$xy_re/g)
			{
				my $x = $1;
				my $y = $2;

				###############################################################################
				# First highlight each targeted block in red or orange (primary / secondary).
				#
				# - Start by retrieving the current x,y page from the wiki.
				################################################################################
				$status{$x,$y}{"striketarget"}="$target_count:$channel";
				$status{$x,$y}{"strike_timestamp"}=$curr_time;

				################################################################################
				# Now update the corresponding block and style pages for this x,y.
				################################################################################
				my $summary = "Target $x,$y set in $channel [timestamp=$curr_time]";
				update_block_style($x,$y, $summary);

				################################################################################
				# If this is the primary target, also note the correct suburb (maplink)
				# page for this target, to use for updating User:TargetReport/RRF-map below.
				################################################################################
				my $target_description;
				if ($target_count == 1)
				{
					my $maplink = maplink($x,$y);

					my $pagename = "User:$wikiuser/RRF-map";
					my $wikitext = "{{subst:User:$wikiuser/$maplink}}";
					$err_rsp = update_wiki($pagename, $summary, $wikitext);

					$target_description = "Strike target (RRF):";
				}
				else
				{
					$target_description =  "Secondary target:";
				}

				################################################################################
				# Append some text describing this target for User:TargetReport/RRF-map.
				################################################################################
				$targets_text .= sprintf("{{../Target|title=%s|x=%u|y=%u}}\n",
							 $target_description,
							 $x,
							 $y);

				$target_count += 1;
			}

			################################################################################
			# Now actually update the User:TargetReport/RRF wiki page with the updated map
			# and target list.
			################################################################################
			my $pagename = "User:$wikiuser/RRF-targets";
			$err_rsp = update_wiki($pagename, $summary, $targets_text);

			$irc->yield (privmsg => $channel => $err_rsp) if ($err_rsp);
		}
	}

	################################################################################
	# !removetarget
	#
	# - clear our hash entry, if it exists
	# - blank out the striketarget= entry on the wiki, if it exists
	################################################################################
	elsif ($what =~ /^!removetarget$/i && $optest)
	{
		my $err_rsp = remove_target($channel);
		$irc->yield (privmsg => $channel => $err_rsp) if ($err_rsp);
	}
	################################################################################
	# !status - just report the status of the target.
	################################################################################
	elsif ($what =~ /!status (.+)$/i)
	{
		log_msg ("Looking up status in $channel: $1");

		my @target_results = &report_status($1);
		$irc->yield ( privmsg => $channel => $_) for (@target_results);
	}
	################################################################################
	# Parse any http://iamscott.net wit URLs we see.
	# !post - forces a forum post of the current wit to 'open buildings'.
	################################################################################
	elsif ($what =~ $wit_re)
	{
		my $wit = $1;
		log_msg ("Wit(s) mentioned by $nick in $channel: $wit");

		################################################################################
		# We'll only store (commit) the update if
		# - user is operating in GREEDY mode (unless an explicit !ignore is included)
		# - explicit !update is included (for users operating with GREEDY mode disabled).
		################################################################################
		my $commit = 0;
		my $force_post = ($what =~ /!post/i);

		if (exists $greedy_disabled{$nick})
		{
			$commit = ($what =~ /!u(pdate)?/i);
			log_msg ("Greedy DISABLED Update wiki=$commit");
		}
		else
		{
			$commit = (!($what =~ /!i(gnore)?/i));
			log_msg ("Greedy ENABLED Update wiki=$commit");
		}

		################################################################################
		# Now actually parse the wit(s).
		################################################################################
		my $parse_rsp = parse_wit($wit, $nick, $channel, $commit, $force_post);
	}

	################################################################################
	# !greedy (on|off) - update the user's preferences accordingly.
	################################################################################
	elsif ($what =~ /^!(set)?greedy *(off|on)?/i)
	{
		if (defined($2)) {$irc->yield (notice => $nick => &set_flags($what,$nick))}
		else {$irc->yield (notice => $nick => &greedy_status($nick))}
	}

	################################################################################
	# !update block-style x_min,y_min x_max,y_max
	#
	# Update block-style for specified block(s).
	################################################################################
	elsif ($what =~ /^!update block-style $xy_re( $xy_re)?/i && $ownertest)
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
	# !check x,y
	#
	# Check current settings for this channel.
	################################################################################
	elsif ($what =~ /^!check *$xy_re/i)
	{
		my $x = $1;
		my $y = $2;

		my $name = $places[$x][$y];
		my $suburb = &suburb($x, $y);
		my $wikiname = $wikinames[$x][$y];
		my $maplink = &maplink($x, $y);
		my $long_name = "$x,$y: $name, $suburb || wikiname=$wikiname || maplink=$maplink";

		if (exists $status{$x,$y})
		{
			$irc->yield (notice => $nick => "Map data for: $long_name");
			for my $value ( sort keys %{ $status{$x,$y} } )
			{
				$irc->yield (privmsg => $channel => "$value=$status{$x,$y}{$value}");
			}
		}
		else
		{
			$irc->yield (notice => $nick => "No data found for $long_name");
		}
	}

	################################################################################
	# !check stale_q
	################################################################################
	elsif ($what =~ /^!check stale_q ?(\d+)?/i)
	{
		my $q_len = scalar @stale_q;
		my $ii = ($1 and $1 < $q_len) ? $1 : 0;

		my $msg = "$q_len in stale queue. ";

		if ($q_len)
		{
			$ii = 0 unless ($ii and $ii < $q_len);

			my $stale_time = $stale_q[$ii][0];
			my $x = $stale_q[$ii][1];
			my $y = $stale_q[$ii][2];

			my $interval = time_text($stale_time - time());

			$msg .= "[$ii] $x,$y stale in $interval.";
		}

		$irc->yield (privmsg => $channel => $msg);
	}

	################################################################################
	# !check reset_q
	################################################################################
	elsif ($what =~ /^!check reset_q ?(\d+)?/i)
	{
		my $q_len = scalar @reset_q;
		my $ii = ($1 and $1 < $q_len) ? $1 : 0;

		my $msg = "$q_len in reset queue. ";

		if ($q_len)
		{
			my $reset_time = $reset_q[$ii][0];
			my $x = $reset_q[$ii][1];
			my $y = $reset_q[$ii][2];

			my $interval = time_text($reset_time - time());

			$msg .= "[$ii] Reset $x,$y in $interval.";
		}

		$irc->yield (privmsg => $channel => $msg);
	}

	################################################################################
	# !check field
	#
	# Check current settings for this channel.
	################################################################################
	elsif ($what =~ /^!check *(.*)/i)
	{
		my $fields = $1;
		if ($fields)
		{
			while ($fields =~ /(\w+)/g)
			{
				my $field = $1;
				if (exists $channel_prefs{$channel}{$field})
				{
					my $val = $channel_prefs{$channel}{$field};
					my $msg = "$field=$val " . ($val ? "(TRUE)" : "(FALSE)");
					$irc->yield (privmsg => $channel => $msg);
				}
				else
				{
					$irc->yield (privmsg => $channel => "No value set for $1 in $channel");
				}
			}
		}
		else
		{
			for my $field ( keys %{ $channel_prefs{$channel} } )
			{
				my $val = $channel_prefs{$channel}{$field};
				my $msg = "$field=$val " . ($val ? "(TRUE)" : "(FALSE)");
				$irc->yield (privmsg => $channel => $msg);
			}
		}
	}

	################################################################################
	# !set field=value
	#
	# Update settings for this channel.
	################################################################################
	elsif ($what =~ /^!set (\w+)=(.*)/i and ($optest || $ownertest))
	{
		$channel_prefs{$channel}{$1} = $2;
		

		$irc->yield (privmsg => $channel => "Set $1=$2 for $channel");
	}

	################################################################################
	# !remove field
	#
	# Update settings for this channel.
	################################################################################
	elsif ($what =~ /^!remove (\w+)/i and ($optest || $ownertest))
	{
		delete $channel_prefs{$channel}{$1};
		

		$irc->yield (privmsg => $channel => "Removed $1 from $channel");
	}

	################################################################################
	# !hello - just say something back to the channel (test command)
	################################################################################
	elsif ($what =~ /^!hello/i)
	{
		my $greeting = "Hello, channel $channel.  Verbose mode ";
		$greeting .= (grep { /$channel/ } @verbose_channels) ? "ON" : "OFF";
		$greeting .= "  Greedy mode ??";
		my $op_reqd = ($op_required{$channel}) ? "YES" : "NO";
		$greeting .= "  Op reqd $op_reqd";

		$irc->yield (privmsg => $channel => $greeting);
		log_msg ("Hailed by $nick in $channel...");
	}
	################################################################################
	# !help - print out a list of accepted commands.
	################################################################################
	elsif ($what =~ /^!help/i)
	{
		my @greeting;
		$irc->yield (privmsg => $channel => "RRF Target Map - http://tinyurl.com/RRFmap for targets - \002!help\002 for more info");
		$irc->yield (notice => $nick => "Usage:");
		$irc->yield (notice => $nick => "  To update the map, just paste dumbwit (iamscott.net) or udwitness (oddnetwork.org) links in this channel, e.g.");
		$irc->yield (notice => $nick => "  http://iamscott.net/137851030993.html");
		$irc->yield (notice => $nick => "Additional commands:");
		$irc->yield (notice => $nick => "  http://iamscott.net/137851030993.html \002!i(gnore)\002 - to prevent a map update (when greedy mode enabled)");
		$irc->yield (notice => $nick => "  http://iamscott.net/137851030993.html \002!u(pdate)\002 - to force a map update (when greedy mode disabled)");
		$irc->yield (notice => $nick => "  \002!greedy (on|off)\002 - display / update greedy mode for $nick");
		$irc->yield (notice => $nick => "  \002!status\002 55,47 - report last known status (multiple x,y permitted)");
		$irc->yield (notice => $nick => "  \002!target\002 - report last known status of current target(s)");
		$irc->yield (notice => $nick => "  \002!settarget\002 - update current target(s) and display status");
		$irc->yield (notice => $nick => "Notes:");
		$irc->yield (notice => $nick => "  \002!u\002 and \002!i\002 can be used as abreviations for !update / !ignore, and can appear anywhere in the string.");
		$irc->yield (notice => $nick => "  Ok to submit multiple wits in a single line.");

		log_msg ("Help requested by $nick in $channel..");
	}

	elsif ($what =~ /^!checkopen/)
	{
		if (exists $open_threads{$channel})
		{
			my $curr_url = $open_threads{$channel};
			$irc->yield (notice => $nick => "Current open thread URL: $curr_url");
		}
		else
		{
			$irc->yield (notice => $nick => "No URL set for $channel");
		}
	}

	################################################################################
	# For testing: !coffee
	################################################################################
	elsif ($what =~ /^!coffee(.*)/i)
	{
		my $greeting = "Hello, $nick.  Have a nice cup of$1 coffee.. ";

		$irc->yield (privmsg => $channel => $greeting);
		log_msg ("Dispensing coffee to $nick in $channel...");
	}

	################################################################################
	# For fun: !say
	################################################################################
	elsif (($what =~ /^!say (#[\w-]+) (.*)/i) && $ownertest)
	{
		$irc->yield (privmsg => $1 => $2);
		log_msg ("Instructed to say $2 in $1 by $nick");
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

	################################################################################
	# For dev purposes: !convertsettings
	################################################################################
	elsif ($what =~ /^!convertsettings$/ and $ownertest)
	{
#	       if (exists $targets{$channel})
#	       {
#		       $channel_prefs{$channel}{"target"} = $targets{$channel};
#	       }

		if ((exists $open_threads{$channel}) and ($open_threads{$channel} =~ /f=(\d+)&t=(\d+)/))
		{
			$channel_prefs{$channel}{"open_forum"} = $1;
			$channel_prefs{$channel}{"open_thread"} = $2;
			if ($open_thread_names{$channel})
			{
				$channel_prefs{$channel}{"open_name"} = $open_thread_names{$channel};
			}
		}

		if (exists $op_required{$channel})
		{
			$channel_prefs{$channel}{"op_reqd"} = $op_required{$channel};
		}

		

		$irc->yield (privmsg => $channel => "Settings converted for $channel");
	}

	################################################################################
	# Default - nothing special for us to do, so check out stale queue(s) to see if
	# we need to age out any old data.
	################################################################################
	elsif (time() > $next_stale_check)
	{
		my $curr_time = time();
		$next_stale_check = $curr_time + 15;

		################################################################################
		# First check the 'stale' queue for anything more than 24 hours old.
		################################################################################
		if (@stale_q and $curr_time > $stale_q[0][0])
		{
			################################################################################
			# Remove this x,y from the front of the queue, and update the block style.
			###############################################################################
			my $stale_time = $stale_q[0][0];
			my $x = $stale_q[0][1];
			my $y = $stale_q[0][2];

			shift (@stale_q);

			my $time_ago = time_ago($curr_time - $stale_time);
			my $summary = "$x,$y stale since $stale_time $time_ago";

			update_block_style($x,$y, $summary);

			################################################################################
			# Also add this x,y onto the reset queue (which ages out data completely after
			# 30 days = 2,592,000 seconds).
			################################################################################
			push @reset_q, [$curr_time + 2592000, $x, $y];
			
		}
		elsif (@reset_q and $curr_time > $reset_q[0][0])
		{
			################################################################################
			# Remove this x,y from the front of the queue, and update the block style.
			################################################################################
			my $reset_time = $reset_q[0][0];
			my $x = $reset_q[0][1];
			my $y = $reset_q[0][2];

			shift (@reset_q);
			

			my $delta = $curr_time - $reset_time;
			my $summary = "Resetting $x,$y - aged out since $reset_time ($delta seconds ago)";

			update_block_style($x,$y, $summary);
		}
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

sub report_status
{
	my $target_string = $_[0];
	my @target_results;
	my @target_list;

	while ($target_string =~ /$xy_re/g)
	{
		my $xy = "$1,$2";
		push (@target_list, $xy) unless (grep {/$xy/} @target_list);
	}

	for my $xy (@target_list)
	{
		my $status_report = target_status($xy);
		push (@target_results, $status_report);
	}

	return @target_results;
}

################################################################################
# Provide a summary of the current status based on the provided x,y wiki text.
################################################################################
sub target_status
{
	my $xy = $_[0];			 # Formatted as x,y.

	my ($x, $y) = split(/,/, $xy);

	my $name = $places[$x][$y];
	my $suburb = suburb($x, $y);
	my $maplink = maplink($x,$y);

	my $buildingtype = $buildingtypes[$x][$y];

	my $status = $status{$x,$y}{"status"};
	my $lit = $status{$x,$y}{"lit"};
	my $statuswit = $status{$x,$y}{"statuswit"};
	my $status_timestamp = $status{$x,$y}{"status_timestamp"};

	my $cades = $status{$x,$y}{"cades"};
	my $cadeswit = $status{$x,$y}{"cadeswit"};
	my $cades_timestamp = $status{$x,$y}{"cades_timestamp"};

	my $in = $status{$x,$y}{"in"};
	my $inwit = $status{$x,$y}{"inwit"};
	my $in_timestamp = $status{$x,$y}{"in_timestamp"};

	my $out = $status{$x,$y}{"out"};
	my $outwit = $status{$x,$y}{"outwit"};
	my $out_timestamp = $status{$x,$y}{"out_timestamp"};

	my $summary = "$name [$x, $y] in $suburb - ";
	my $witlink;

	################################################################################
	# Nothing to report for outside locations unless there are survivors present.
	################################################################################
	# $value can be any regex. be safe
	# if ( grep( /^$value$/, @array ) ) {
	#   print "found it";
	# }	
	
	if (grep(/$buildingtype/, [ 'Street', 'Park', 'Carpark', 'Cemetery', 'Wasteland', 'Monument']))
	{
		if ($out)
		{
			$summary .= "\002$out survivor(s)\002 $outwit " . time_ago($out_timestamp);
			$witlink = "True";
		}
	}
	else
	{
		################################################################################
		# Inside location (including junkyards):
		#
		# First check the 'lit' status.  If we have *any* information, this will always
		# be known.  Otherwise just report the whole status as "Unknown".
		################################################################################
		unless ($lit)
		{
			# $summary .= "\002Unknown\002 "	  # We don't even know if it's lit.
			$summary .= "Unknown "	  # We don't even know if it's lit.
		}
		else
		{
			################################################################################
			# At a minimum we know the building status (repair / ruin / lit).
			#
			# Junkyards and zoos can't be ruined, so just report Lit or Unlit.
			################################################################################
			if (grep { $buildingtype eq $_ } [ 'Junkyard', 'Zoo'])
			{
				$summary .= "$lit ";
			}
			else
			{
				################################################################################
				# For all other buildings, use the following text for ruins.
				# Don't bother mentioning the cades if they're 'open' or 'unknown'.
				#
				# Ruined! (Lit)
				# Ruined! (Lit) (Loosely-EHB)
				################################################################################
				if ($status eq "Ruined")
				{
					$summary .= "\002Ruined\002 ";
					$summary .= "Lit " if ($lit eq 'Lit');
					$summary .= "\002$cades\002 " if ($cades && !($cades eq 'Open'));
				}
				################################################################################
				# For repaired buildings, report as follows.  Don't bother mentioning 'unknown'
				# cades.  Don't bother mentioning 'Unlit' unless cades are also unknown.
				#
				# (Lit) Open!-EHB
				# Lit / Unlit
				################################################################################
				elsif ($cades)
				{
					$summary .= "Lit " if ($lit eq 'Lit');
					$summary .= ($cades eq 'Open') ? "\002Open!\002 " : "\002$cades\002 ";
				}
				else {$summary .= "\002$lit\002 "}
			}

			################################################################################
			# Now report on any survivors tagged inside as follows.
			#
			# EMPTY or
			# Inside: N survivor(s)
			#
			################################################################################
			if ($in)
			{
				$summary .= "Inside: \002$in\002 $inwit " . time_ago($in_timestamp);
				$witlink = "True";
			}
			elsif ($in eq '0')
			{
				$summary .= "\002EMPTY\002 $inwit " . time_ago($in_timestamp);
				$witlink = "True";
			}

			################################################################################
			# Now report on any survivors tagged outside, as follows.
			#
			# Outside: X survivor(s)
			#
			################################################################################
			if ($out)
			{
				$summary .= "Outside: \002$out\002 $outwit " . time_ago($out_timestamp);
				$witlink = "True";
			}

			################################################################################
			# If we don't have any survivor wits, provide the next best info we have:
			# - cade wit
			# - status wit
			#
			################################################################################
			unless ($witlink)
			{
				if ($cadeswit)
				{
					$summary .= " : $cadeswit " . time_ago($cades_timestamp);
				}
				else
				{
					$summary .= " : $statuswit " . time_ago($status_timestamp);
				}
			}
		}
	}

	return $summary;
}

################################################################################
# time_ago()
#
# - Returns text like "(4 minutes ago)"
################################################################################
sub time_ago
{
	my $timestamp =   $_[0];	  # E.g. 1389390379

	return "" unless $timestamp;

	my $time_text = time_text(time() - $timestamp);
	return "($time_text ago)";
}

################################################################################
# time_text()
#
# - Converts supplied number of seconds to text like "4 minutes"
################################################################################
sub time_text
{
	my $seconds =   $_[0];	  # E.g. 1389390379

	return "" unless $seconds;
	my $delta_ts=new Time::Seconds ($seconds);

	my $time_text = "";
	($time_text) = split(',', $delta_ts->pretty);

	return $time_text;
}

################################################################################
# update_wiki_targets()
#
# - Updates the specified target list at User:TargetReport/RRF.
# - Returns error text, or empty string if successful.
################################################################################
sub update_wiki_targets
{
	my $list_re =   $_[0];	  # Regex specifying which list to update, e.g. qw/Current Target\(s\)/
	my $max_entries =       $_[1];	  # Max x,y entries in final list.
						# 0 => replace current list in it's entirity.
	my $target_string =     $_[2];	  # Target string containing new x,y value(s).
	my $err_rsp = '';		       # Result of the function. Only set if there is an error.
	my $xy_re = qr/\|\d\d?\|\d\d?\n/;

	################################################################################
	# Read the User:TargetReport/RRF wiki page which has the latest lists.
	################################################################################
	my $pagename = "User:$wikiuser/RRF";
	my $pagetext = get_wiki_page($pagename);
	unless ($pagetext) {return "Couldn't read wiki: $pagename"}

#       my $page = $udwikiapi->get_page( { title => $pagename } );
#       if (!($page) || $page->{missing} || !($page->{'*'}))
#       {
#	       return "Couldn't read wiki: $pagename"
#       }

	my $newpage = $pagetext;

	################################################################################
	# Find the requested list, and extract the existing |x|y\n
	################################################################################
	my $newlist;
	if ($newpage =~ /$list_re\n(($xy_re)*)/i)
	{
		$newlist = $1;
	}
	else {return "$list_re not found in $pagename"}

	################################################################################
	# If we're replacing the entire list, just wipe all the existing entries now.
	################################################################################
	if ($max_entries == 0) {$newlist =~ s/$xy_re//g}

	################################################################################
	# Now extract the new x,y from the supplied string, and add each one to the
	# front of the list.  Remove any duplicates as we go.
	################################################################################
	while ($target_string =~ /$xy_re/g)
	{
		my $new_xy = "|$1|$2\n";
		$newlist =~ s/\|$1\|$2\n//g;    # Remove any existing matching x,y.
		$newlist = $new_xy . $newlist;
	}

	################################################################################
	# Now trim the list if needed.
	################################################################################
	unless ($max_entries == 0)
	{
		$newlist =~ s/(($xy_re){0,$max_entries})($xy_re)*/$1/;
	}

	################################################################################
	# Now update the page text with the new list of x,y co-ordinates.
	################################################################################
	$newpage =~ s/(?<=$list_re\n)($xy_re)*/$newlist/i;

	################################################################################
	# If the page text has actually changed, update the wiki.
	################################################################################
#       unless ($newpage eq $page->{'*'})
	unless ($newpage eq $pagetext)
	{
#	       my $timestamp = $page->{timestamp};
#	       my $summary = "Update $list_re with $newlist";

#	       $err_rsp = update_wiki_page($pagename, $timestamp, $newpage, $summary);

		my $curr_time = time();
		my $summary = "New target(s): $newlist at timestamp=$curr_time";

		$err_rsp = update_wiki($pagename, $summary, $newpage);
	}
	return $err_rsp;
}

################################################################################
# parse_wit()
#
# - Parse the supplied UD wit, and update all blocks in the 3x3 mini-map.
# - Always returns descriptive text describing the wiki update (or error).
################################################################################
sub parse_wit
{
	my $wit =	       $_[0];
	my $nick =	      $_[1];
	my $channel =	   $_[2];
	my $commit =	    $_[3];  # If false, just parse the wit and return a summary.
	my $force_post =	$_[4];  # If true, always post to open buildings forum.
	my $rsp;
	
	log_msg("ENTER: parse_wit $_[0] $_[1] $_[2] $_[3] $_[4]");

	################################################################################
	# Use HTML::TreeBuilder to parse the HTML from the supplied wit.
	################################################################################
	my $tree = HTML::TreeBuilder->new_from_url($wit) || return "Error processing $wit";
	if (!$tree) {return "Error parsing $wit"}

	log_msg("Successfully parsed HTML");
	
	################################################################################
	# The timestamp is always added to the beginning of the HTML body, e.g.
	#
	# <body>Sun Oct 27 01:36:37 -0400 2013 : Wit comment<br>...
	#
	################################################################################
	my $body_element = $tree->look_down(_tag => 'body');
	my $wit_description = $body_element->content_array_ref->[0];
	my $wit_date_text = (split(/ :|: /,$wit_description))[0];

	################################################################################
	# Use the wit timestamp if present and parseable, otherwise assume current time.
	################################################################################
	my $wit_time = str2time($wit_date_text);
	if (defined ($wit_time) )
	{
		################################################################################
		# Successfully parsed time from the wit.
		# Now adjust for any time offest on the wit server (e.g. timezone).
		################################################################################
		log_msg ("BRANCH: parsed wit_time: $wit_time");
		$wit_time += $wit_server_offset;	# Offset is the amount we have to add or subtract
							# to translate wit time to actual time.


		################################################################################
		# Check how old the wit is.
		#
		# The wit can't be from the future, so if age appears to be negative,
		# server_offset is too large.  Adjust it accordingly.
		################################################################################
		my $age = time() - $wit_time;	   # Age (in seconds) since this wit was taken.

		if ($age < 0) {
			log_msg ("Adjusting time offset by $age seconds (was $wit_server_offset)");
			alert ("Adjusting time offset by $age seconds (was $wit_server_offset)");
			$wit_server_offset += $age;       # Note offset can only ever decrease.
			$wit_time = time();
		}
	}
	else
	{
		log_msg ("Couldn't parse date from $wit ($wit_date_text)");
		alert ("Couldn't parse date from $wit ($wit_date_text)");
		$wit_time = time();
	}

	################################################################################
	# First check if we are inside or outside.  This is represented as follows.
	#
	# <td class="gp">
	#   <div class="gt">You are inside <b>St George's Hospital</b>, dark corridors
	#     leading through abandoned wards. The building has been very strongly
	#     barricaded...
	#
	# Note that we might also be "lying" inside (or outside).
	################################################################################
	my $main_panel = $tree->look_down(_tag => 'td', class => 'gp');
	my $description_element = $main_panel->look_down(_tag => 'div', class => 'gt');
	my $description = $description_element->as_HTML;
	my $description_text = $description_element->as_text;

	my $inout;
	my $cadestatus;

	if ($description_text =~ /You are( lying| standing)? (in|out)/i)
	{
		$inout = $2;

		if ($description_text =~ / been extremely heavily barricaded/) {$cadestatus = 'EHB'}
		elsif ($description_text =~ / been very heavily barricaded/) {$cadestatus = 'VHB'}
		elsif ($description_text =~ / been heavily barricaded/) {$cadestatus = 'HB'}
		elsif ($description_text =~ / been very strongly barricaded/) {$cadestatus = 'VSB'}
		elsif ($description_text =~ / been quite strongly barricaded/) {$cadestatus = 'QSB'}
		elsif ($description_text =~ / been lightly barricaded/) {$cadestatus = 'Lightly'}
		elsif ($description_text =~ / been loosely barricaded/) {$cadestatus = 'Loosely'}
		# elsif ($description_text =~ / have been secured/) {$cadestatus = 'Open'}
		else {$cadestatus = 'Open'}
	}
	else
	{
		$inout = "out";
	}

	################################################################################
	# Now parse the 9x9 mini-map to determine the x,y, ruin/repair status and
	# suvivor counts of our current location and adjacent blocks.
	#
	# The block information is stored in <td> table data entries with class type:
	# class="b c8" or simliar.  E.g.
	#
	# <td class="b c4">
	#   <form action="map.cgi" method="post">
	#     <input name="v" value="30-70" type="hidden">
	#     <input class="md" value="Tribe Park" type="submit">
	#   </form>
	# </td>
	#
	################################################################################
	my @blocks = $tree->look_down(_tag => 'td', class => qr/b c/);

	################################################################################
	# Parse key info for each block visible in the 3x3 mini-map.
	################################################################################
	my $x_y;	# 56-42 format
	my $count = 0;

	foreach my $block (@blocks)
	{
		my ($current_location, $more_survivors);

		################################################################################
		# First parse the x-y for this block from the <input value="30-70"> element.
		################################################################################
		my $xy_element = $block->look_down(_tag => 'input', value => qr/\d+-\d+/);
		if (defined($xy_element))
		{
			################################################################################
			# This is one of the adjacent blocks in the 3x3 mini-map, so the x-y is visible.
			# If this is the first (upper left) block, make a special note.
			################################################################################
			$x_y = $xy_element->attr("value");
			$count++;

			################################################################################
			# If we're not actually updating the wiki, there's nothing left to do for this
			# block.
			################################################################################
			next unless ($commit);
		}
		else
		{
			################################################################################
			# The x-y for the current location isn't listed in the HTML, so calculate it
			# as (x+1,y) of the previous block in the mini-map (immediately to the left).
			#
			# This assumes we're not at the map edge (checked earlier in the script).
			################################################################################
			$current_location = 'True';

			if ($count == 0)
			{
				$x_y = '0-0';
			}
			elsif ($count == 2)
			{
				$x_y =~ /(\d+)-(\d+)/;
				my $new_x = eval($1-1);
				my $new_y = eval($2+1);
				$x_y = "$new_x-$new_y";
			}
			else
			{
				$x_y =~ /(\d+)-(\d+)/;
				my $new_x = eval($1+1);
				$x_y = "$new_x-$2";
			}
		}
		$x_y =~ /(\d+)-(\d+)/;
		my $x = $1;
		my $y = $2;

		################################################################################
		# Now parse the ruin / lit status from the same element above.
		#
		# 'l' indicates that lights are on.  'r' indicates ruined.
		################################################################################
		my $status_element = $block->look_down(_tag => 'input', class => qr/m\w*/);
		my $status_class = $status_element->attr("class");
		my $status = ($status_class =~ /r/) ? "Ruined" : "Repaired";
		my $litstatus = ($status_class =~ /l/) ? "Lit" : "Unlit";

		################################################################################
		# SPECIAL CASE: dark buildings (td class="b cxd") always look ruined (input
		# class = "mr") from the inside, regardless of whether they are ruined or
		# repaired, i.e.
		#
		#       <td class="b cxd"><input class="mr">
		#
		# In this case we need to check the actual description, which will be one of:
		#
		#       "The building has fallen into ruin, and with the lights out, you
		#       can hardly see anything." (Ruined dark)
		#
		#       v.
		#
		#       "With the lights out, you can hardly see anything. " (repaired)
		#
		################################################################################
		if (($current_location) and
		    ($block->attr("class") eq 'b cxd') and
		    ($status_class eq 'mr') and
		    ($description_text =~ /With the lights out, you can hardly see anything\./))
		{
			$status = "Repaired";
			debug ("Dark building $x,$y is actually repaired");
		}

		################################################################################
		# If survivors are visible, they'll be in <a> elements with "f1" style classes.
		#
		# <a href="http://urbandead.com/profile.cgi?id=2039558" class="f1">
		#   Fainden Leloush
		# </a>
		################################################################################
		my $survivorcount = "?";

		my @survivors = $block->look_down(_tag => 'a', class => qr/f\d/);
		if (@survivors) {
			$survivorcount = scalar @survivors;

			################################################################################
			# A class="f" <a> element indicates 5+ survivors (the "..." in the mini-map)
			################################################################################
			$more_survivors = $block->look_down(_tag => 'span', class => 'f');

			if ($more_survivors)
			{
				################################################################################
				# If there are 5+ survivors in the current location, count them by parsing the
				# building description, otherwise just say "5+".
				################################################################################
				if ($current_location and ($description =~ /Also here are (.*)<br \/>/))
				{
					my $survivor_list = $1;
					my @new_count = ($survivor_list =~ /<a.*?href=".*?urbandead\.com\/profile\.cgi\?id=\d+.*?">/g);
					$survivorcount = scalar @new_count;
				}
				else
				{
					$survivorcount .= "+";
				}
			}
		}
		elsif ($inout eq 'in')
		{
			################################################################################
			# Inside and no survivors visible for this block:
			#
			# This doesn't tell us much unless this is our current location, or we're
			# inside a large building (Mall, Cathedral, Mansion etc).
			################################################################################
			if ($current_location) {
				$survivorcount = 0;
			}
		}
		else
		{
			################################################################################
			# Outside and no survivors visible for this block:
			#
			# Set "out=" to indicate no survivors present.  We don't bother tracking
			# "out=0" explicitly (as distinct from 'unknown') since it's so common and this
			# would result in a lot of fairly pointless extra wiki page updates.
			################################################################################
			$survivorcount = 0;
		}

		################################################################################
		# Now update our stored data for this block.
		################################################################################
		my $summary = "$wit submitted in $channel [timestamp=$wit_time]";

		my $block_rsp = &update_wiki_block($wit,
						   $wit_time,
						   $commit,
						   $summary,
						   $x,
						   $y,
						   $status,
						   $litstatus,
						   $inout,
						   $survivorcount,
						   ($current_location ? $cadestatus : undef));

		################################################################################
		# If this block is the actual location of the wit, also
		# - report back a summary to the IRC channel
		################################################################################
		if ($current_location)
		{
			$rsp = $block_rsp;
			$irc->yield( privmsg => $channel => $rsp );

			my $suburb = suburb($x, $y);
			$suburb =~ s/ /_/g;     # Replace any spaces in the wiki link with underscores.
			$irc->yield( privmsg => $channel => "Suburb map updated: http://wiki.urbandead.com/index.php/User:$wikiuser/$suburb");
		}
	}
	log_msg("EXIT: parse_wit returns: $rsp");

	return $rsp;
}

################################################################################
# update_wiki_block()
#
# - Check and update wiki page for the specified x,y if something has changed:
#    o Ruin / Repair status (also resets 'in' survivor counts and cade status)
#    o Lit status
#    o Survivor count (inside or out)
#
# - Always returns descriptive text describing the wiki update (or error).
################################################################################
sub update_wiki_block
{
	my $wit =	       $_[0];  #
	my $wit_time =	  $_[1];  # unix time e.g. 1382659950
	my $commit =	    $_[2];
	my $summary =	   $_[3];
	my $x =		 $_[4];  # 55,52
	my $y =		 $_[5];  # 55,52
	my $status =	    $_[6];  # Repaired	      Ruined
	my $litstatus =	 $_[7];  # Lit		   Unlit
	my $inout =	     $_[8]; # in		     out
	my $survivorcount =     $_[9];  # ""    0       1       5       5+
	my $cadestatus =	$_[10];  # EHB		   Open
	my $rsp;

	################################################################################
	# Lookup the name, wikiname and suburb for this x,y.
	################################################################################
	my $name = $places[$x][$y];
	my $suburb = suburb($x, $y);

	################################################################################
	# Generate a readable summary of the wit, e.g.
	#
	#   a factory [51-46] in Ridleybank - Repaired, Open! 5+ survivor(s) inside -
	#   Updating http://wiki.urbandead.com/index.php/User:TargetReport/Roftwood
	################################################################################
	my $wit_summary = "$name [$x,$y] in $suburb -";

	if ($status)	    {$wit_summary .= " \002$status\002,"}
	if ($litstatus)	 {$wit_summary .= " $litstatus"}
	if ($cadestatus)	{$wit_summary .= ", \002$cadestatus\002"}
	if ($survivorcount ne "?") {$wit_summary .= " \002$survivorcount survivor(s) $inout" . "side\002 "}

	################################################################################
	# If we're *not* updating the wiki, there's nothing more to do.
	# - Just return the human readable summary of the wit we just generated.
	################################################################################
	if (!$commit)
	{
		debug ("Not committing changes; just return: $wit_summary");
		return $wit_summary;
	}

	################################################################################
	# If this wit has already been submitted, we don't need to parse it again
	################################################################################
#	if ($newpage =~ /$wit/i)
#	{
#		unless ($force_post_wiki)
#		{
#			return "$name [$x,$y] in $suburb - $wit [Ignoring duplicate]";
#		}
#	}

	################################################################################
	# Now check whether we're at a building which can be lit and / or repaired
	# (including junkyards).
	#
	# - ALL buildings can be lit (including junkyards)
	# - MOST buildings can be repaired / ruined (except junkyards, zoo etc).
	################################################################################
	my $buildingtype = $buildingtypes[$x][$y];
	unless (grep { $buildingtype eq $_ } [ 'Street', 'Park', 'Carpark', 'Cemetery', 'Wasteland', 'Monument'])
	{
		################################################################################
		# BUILDING: (including junkyards)
		#
		# - Store the new wit (and timestamp) regardless of whether status changed,
		#   as long as it is more recent than any previously submitted.
		################################################################################
		my $curr_timestamp = $status{$x,$y}{"status_timestamp"};     # Might be undefined or 0;

		unless ($curr_timestamp && ($curr_timestamp > $wit_time))
		{
			$status{$x,$y}{"lit"} = $litstatus;
			$status{$x,$y}{"statuswit"} = $wit;
			$status{$x,$y}{"status_timestamp"} = $wit_time;

			################################################################################
			# Also store the new repair / ruin status, unless we're at a junkyard or zoo.
			################################################################################
			unless (grep { $buildingtype eq $_ } [ 'Junkyard', 'Zoo'])
			{
				my $prev_status = $status{$x,$y}{"status"};     # Might be undefined;
				$status{$x,$y}{"status"} = $status;

				################################################################################
				# If status changed from Repaired -> Ruined or visa versa, also reset the
				# survivor count and cade status to unknown.
				################################################################################
				if ($prev_status and ($prev_status ne $status))
				{
					delete $status{$x,$y}{"cades"};
					delete $status{$x,$y}{"cadeswit"};
					delete $status{$x,$y}{"cades_timestamp"};

					delete $status{$x,$y}{"in"};
					delete $status{$x,$y}{"inwit"};
					delete $status{$x,$y}{"in_timestamp"};
				}
			}
		}
	}

	################################################################################
	# Now update the cade status if known for this block.
	################################################################################
	if ($cadestatus)
	{
		################################################################################
		# Store the new wit of the cade status unless an existing wit is more recent.
		################################################################################
		my $cades_timestamp = $status{$x,$y}{"cades_timestamp"};       # Might be undef;

		unless ($cades_timestamp && ($cades_timestamp > $wit_time))
		{
			$status{$x,$y}{"cades"} = $cadestatus;
			$status{$x,$y}{"cadeswit"} = $wit;
			$status{$x,$y}{"cades_timestamp"} = $wit_time;
		}
	}

	################################################################################
	# Now update the survivor counts for this block if visible (and more recent).
	#
	# - $survivorstatus will look like 0, 1, 2, 3, 4, 5, 5+, ?
	# - $survivorstatus is normally ? unless we're outside, or inside a large bldg.
	################################################################################
	unless ($survivorcount eq "?")
	{
		my $timestamp_name = $inout . "_timestamp";     # in_timestamp or out_timestamp
		my $curr_timestamp = $status{$x,$y}{$timestamp_name};

		unless ($curr_timestamp && ($curr_timestamp > $wit_time))
		{
			$status{$x,$y}{$inout} = $survivorcount;	 # Might be 0
			$status{$x,$y}{$inout . "wit"} = $wit;
			$status{$x,$y}{$inout . "_timestamp"} = $wit_time;
		}
	}

	################################################################################
	# Note that we don't update the x,y wiki page as all status info is stored
	# locally by the bot (in memory, and written to disk in case of reboot).
	################################################################################

	################################################################################
	# Now kick off a child process to update the 'style' and 'block' pages too, e.g.
	#   User:TargetReport/55,47-style
	#   User:TargetReport/55,47-block
	#
	# Notes
	#
	# - We use a separate process for this because the block / style update function
	#   is also used elsewhere (e.g. to 'age out' expired info or update pages after
	#   a template change).
	#
	# - We can't rely on the wiki update we just made to the x,y page being
	#   committed in time for the child process to calculate the block and style
	#   pages, so pass a list of any updated parameters as an explicit input.
	#
	# Update: this is now handled by this process. TBD how to handle aging..
	#
	# Update 2 [Mar 2015]: this is actually still handled by the child process;
	#		      aging is triggered by a separate daemon.
	#
	################################################################################
	update_block_style($x, $y, $summary);

	################################################################################
	# Return a wit summary and let requester know that we are updating the wiki.
	################################################################################
	$suburb =~ s/ /_/g;     # Replace any spaces in the wiki link with underscores.
#	$wit_summary .= " Suburb map updated: http://wiki.urbandead.com/index.php/User:$wikiuser/$suburb";

	################################################################################
	# Add this block to the 'stale' queue, so it's checked again in 24h.
	################################################################################
	push @stale_q, [time() + $stale_interval, $x, $y];

	debug ("EXIT: update_wiki_block() -> $wit_summary");

	return $wit_summary;
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

sub set_flags
{
	my $what = $_[0];
	my $channel_nick = $_[1];       # Nick or channel, depending on flag.

	if ($what =~ /^!(set)?g(reedy)? *(off|on)/i)
	{
		if (lc $3 eq 'off')
		{
			$greedy_disabled{$channel_nick} = "True";
		}
		elsif (exists $greedy_disabled{$channel_nick})
		{
			delete $greedy_disabled{$channel_nick};
		}
	}
	return greedy_status($channel_nick);
}

################################################################################
# greedy_status()
#
# Returns:
################################################################################
sub greedy_status
{
	my $nick = $_[0];

	if (exists $greedy_disabled{$nick})
	{
		return "Greedy mode \002OFF\002: wits from $nick ignored in all channels unless " .
			"\002!update\002 (or \002!u\002) included. " .
			"\002!greedy on\002 to enable.";
	}
	else
	{
		return "Greedy mode \002ON\002: all wits from $nick parsed unless " .
			"\002!ignore\002 (or \002!i\002) included. " .
			"\002!greedy off\002 to disable.";
	}
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

sub get_wiki_page
{
	my $pagename =  $_[0];	  # e.g. User:TargetReport/RRF

	my $page = $udwikiapi->get_page( { title => $pagename } );

	return "" unless $page;
	return "" if $page->{missing};

	return $page->{'*'};
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
		# $irc->yield (privmsg => $logchannel => $log_text);
		# sleep(1);     # To prevent IRC flooding errors.
	}
}

################################################################################
# log_msg()
#
# - Write to stdout.
# - Debug mode: log in IRC debug channel as well.
################################################################################
sub log_msg
{
	my $log_text = $_[0];	   # e.g. "Rick submitted wit in #gore"
	print "$log_text \n";
}

################################################################################
# alert()
#
# - Write to stderr, AND
# - log in IRC debug channel.
################################################################################
sub alert
{
	my $log_text = $_[0];	   # e.g. "Wiki update failed"
	warn $log_text;
	$irc->yield (privmsg => $logchannel => $log_text);
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
# remove_target()
#
# - clear targets for specified channel
#
# Returns: nothing if successful, else description of the error.
################################################################################
sub remove_target
{
	my $channel =   $_[0];	  # e.g. "56,47"

	debug ("remove_target($channel)");

	my $target_string = $channel_prefs{$channel}{"target"};
	if ($target_string)
	{
		while ($target_string =~ /$xy_re/g)
		{
			my $x = $1;
			my $y = $2;

			################################################################################
			# Blank out any striketarget= values for current targets.
			################################################################################
			delete $status{$x,$y}{"striketarget"};
			delete $status{$x,$y}{"strike_timestamp"};

			################################################################################
			# Now update the map with the target highlighting removed.
			################################################################################
			my $summary = "Target $x,$y removed in $channel";
			update_block_style($x, $y, $summary);
		}
	}

	################################################################################
	# Finally, remove the target hash entry for this channel.
	################################################################################
	$channel_prefs{$channel}{"target"} = "";
	

	log_msg ("Target(s) removed for $channel");
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
		# If this location has *never* been updated, black out with opactity 20%.
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