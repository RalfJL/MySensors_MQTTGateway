#!/usr/bin/perl -w

#
# MQTT Gateway - A gateway to exchange MySensors messages from an
#                ethernet gateway with an MQTT broker.
#
# Created by Ivo Pullens, Emmission, 2014-2016 -- www.emmission.nl
#
# Tested with:
# * MySensors 2.0.0
# * MySensors 1.5.x
# * Mosquitto 1.4.2 MQTT Broker (mosquitto.org)
# * Ubuntu Linux 12.04.5 & 15.10.
# * CentOS 6.x
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# Modules needed (to be installed through cpan command):
# Net::MQTT::Constants
# AnyEvent::Socket
# AnyEvent::SerialPort
# AnyEvent::MQTT
# enum.pm


local $ENV{ANYEVENT_MQTT_DEBUG} = 1;

use strict;
use Cwd;
use IO::Socket::INET;
use Net::MQTT::Constants;
use AnyEvent::Socket;
use AnyEvent::SerialPort;
use AnyEvent::MQTT;
use AnyEvent::Strict;   # check parameters passed to callbacks 
use Data::Dumper;
use List::Util qw(first);
use Storable;
use Time::Zone;
use v5.10;              # Requires support for given/when constructs
use Device::SerialPort;
use Getopt::Long;
use Fcntl ':flock';

#-- Message types
use enum qw { C_PRESENTATION=0 C_SET C_REQ C_INTERNAL C_STREAM };
use constant commandToStr => qw( C_PRESENTATION C_SET C_REQ C_INTERNAL C_STREAM );

#-- Variable types
use enum qw { V_TEMP=0 V_HUM V_LIGHT V_DIMMER V_PRESSURE V_FORECAST V_RAIN
        V_RAINRATE V_WIND V_GUST V_DIRECTION V_UV V_WEIGHT V_DISTANCE
        V_IMPEDANCE V_ARMED V_TRIPPED V_WATT V_KWH V_SCENE_ON V_SCENE_OFF
        V_HEATER V_HEATER_SW V_LIGHT_LEVEL V_VAR1 V_VAR2 V_VAR3 V_VAR4 V_VAR5
        V_UP V_DOWN V_STOP V_IR_SEND V_IR_RECEIVE V_FLOW V_VOLUME V_LOCK_STATUS
        V_DUST_LEVEL V_VOLTAGE V_CURRENT V_RGB V_RGBW V_ID V_UNIT_PREFIX V_HVAC_SETPOINT_COOL
		V_HVAC_SETPOINT_HEAT V_HVAC_FLOW_MODE V_TEXT V_CUSTOM V_POSITION V_IR_RECORD 
		V_PH V_ORP V_EC V_VAR V_VA V_POWER_FACTOR };
use constant variableTypesToStr => qw{ V_TEMP V_HUM V_LIGHT V_DIMMER V_PRESSURE V_FORECAST V_RAIN
        V_RAINRATE V_WIND V_GUST V_DIRECTION V_UV V_WEIGHT V_DISTANCE
        V_IMPEDANCE V_ARMED V_TRIPPED V_WATT V_KWH V_SCENE_ON V_SCENE_OFF
        V_HEATER V_HEATER_SW V_LIGHT_LEVEL V_VAR1 V_VAR2 V_VAR3 V_VAR4 V_VAR5
        V_UP V_DOWN V_STOP V_IR_SEND V_IR_RECEIVE V_FLOW V_VOLUME V_LOCK_STATUS
        V_DUST_LEVEL V_VOLTAGE V_CURRENT V_RGB V_RGBW V_ID V_UNIT_PREFIX V_HVAC_SETPOINT_COOL
		V_HVAC_SETPOINT_HEAT V_HVAC_FLOW_MODE V_TEXT V_CUSTOM V_POSITION V_IR_RECORD 
		V_PH V_ORP V_EC V_VAR V_VA V_POWER_FACTOR};

sub variableTypeToIdx
{
  my $var = shift;
  return first { (variableTypesToStr)[$_] eq $var } 0 .. scalar(variableTypesToStr);
}

#-- Internal messages
use enum qw { I_BATTERY_LEVEL=0 I_TIME I_VERSION I_ID_REQUEST I_ID_RESPONSE
        I_INCLUSION_MODE I_CONFIG I_FIND_PARENT I_FIND_PARENT_RESPONSE
        I_LOG_MESSAGE I_CHILDREN I_SKETCH_NAME I_SKETCH_VERSION
        I_REBOOT I_GATEWAY_READY 
		I_SIGNING_PRESENTATION
		I_NONCE_REQUEST
		I_NONCE_RESPONSE
		I_HEARTBEAT I_PRESENTATION I_DISCOVER I_DISCOVER_RESPONSE I_HEARTBEAT_RESPONSE 
		I_LOCKED I_PING I_PONG I_REGISTRATION_REQUEST I_REGISTRATION_RESPONSE I_DEBUG};
use constant internalMessageTypesToStr => qw{ I_BATTERY_LEVEL I_TIME I_VERSION I_ID_REQUEST I_ID_RESPONSE
        I_INCLUSION_MODE I_CONFIG I_FIND_PARENT I_FIND_PARENT_RESPONSE
        I_LOG_MESSAGE I_CHILDREN I_SKETCH_NAME I_SKETCH_VERSION
        I_REBOOT I_GATEWAY_READY
		I_SIGNING_PRESENTATION
		I_NONCE_REQUEST
		I_NONCE_RESPONSE
		I_HEARTBEAT I_PRESENTATION I_DISCOVER I_DISCOVER_RESPONSE I_HEARTBEAT_RESPONSE 
		I_LOCKED I_PING I_PONG I_REGISTRATION_REQUEST I_REGISTRATION_RESPONSE I_DEBUG};
		
sub imessageTypeToIdx {
	my $var = shift;
	return first { (internalMessageTypesToStr)[$_] eq $var }
	0 .. scalar(internalMessageTypesToStr);
}

#-- Sensor types
use enum qw { S_DOOR=0 S_MOTION S_SMOKE S_LIGHT S_DIMMER S_COVER S_TEMP S_HUM S_BARO S_WIND
        S_RAIN S_UV S_WEIGHT S_POWER S_HEATER S_DISTANCE S_LIGHT_LEVEL S_ARDUINO_NODE
        S_ARDUINO_REPEATER_NODE S_LOCK S_IR S_WATER S_AIR_QUALITY S_CUSTOM S_DUST
        S_SCENE_CONTROLLER S_RGB_LIGHT S_RGBW_LIGHT S_COLOR_SENSOR S_HVAC S_MULTIMETER
        S_SPRINKLER S_WATER_LEAK S_SOUND S_VIBRATION S_MOISTURE S_INFO S_GAS S_GPS S_WATER_QUALITY };
use constant sensorTypesToStr => qw{ S_DOOR S_MOTION S_SMOKE S_LIGHT S_DIMMER S_COVER S_TEMP S_HUM S_BARO S_WIND
        S_RAIN S_UV S_WEIGHT S_POWER S_HEATER S_DISTANCE S_LIGHT_LEVEL S_ARDUINO_NODE
        S_ARDUINO_REPEATER_NODE S_LOCK S_IR S_WATER S_AIR_QUALITY S_CUSTOM S_DUST
        S_SCENE_CONTROLLER S_RGB_LIGHT S_RGBW_LIGHT S_COLOR_SENSOR S_HVAC S_MULTIMETER
        S_SPRINKLER S_WATER_LEAK S_SOUND S_VIBRATION S_MOISTURE S_INFO S_GAS S_GPS S_WATER_QUALITY};
        
#-- Datastream types
use enum qw { ST_FIRMWARE_CONFIG_REQUEST=0 ST_FIRMWARE_CONFIG_RESPONSE ST_FIRMWARE_REQUEST ST_FIRMWARE_RESPONSE
        ST_SOUND ST_IMAGE };
use constant datastreamTypesToStr => qw{ ST_FIRMWARE_CONFIG_REQUEST ST_FIRMWARE_CONFIG_RESPONSE ST_FIRMWARE_REQUEST ST_FIRMWARE_RESPONSE
        ST_SOUND ST_IMAGE };

#-- Payload types
use enum qw { P_STRING=0 P_BYTE P_INT16 P_UINT16 P_LONG32 P_ULONG32 P_CUSTOM P_FLOAT32 };
use constant payloadTypesToStr => qw{ P_STRING P_BYTE P_INT16 P_UINT16 P_LONG32 P_ULONG32 P_CUSTOM P_FLOAT32 };

#-- Message types from controller to node that should be delayed until node is active
# most nodes sleep long and often, so they receive only shortly after they woke up
# messages of these types from the controller are delayed until a new message
# from the sensor is received by the gateway; make sure that the sensor waits a while
# after the first message or you will lose both messages from node and from controller
# you can use the topic2node channel if you do not need an immediate communication with
# a sensor node, like the controller needs, most of the time
# all communication through topic2node will be delayed
my @delayedMessageTypes = qw { I_REBOOT };
my %delayedMessages;    # hash to save messages for nodes; nodeId is key


my $topicRoot = '/mySensors';       # Omit trailing slash
my $topicC2N  = '/mySensorsC2N';    # queue for controller to send to nodes

# queue for all messages delayed until sensor sends the first package
my $topic2node = '/mySensors2node';

# please make sure the sensor uses wait() after the first message, or the message from
# the sensor and the gateway will both be lost (collision)

my $mqttHost = 'localhost';         # Hostname of MQTT broker
my $mqttPort = 1883;                # Port of MQTT broker
my $mqttClientId = "MySensors-".$$; # Unique client ID to broker
my $mqttUser = undef;
my $mqttPasswd = undef;

# -- Settings when using Ethernet gateway
my $mysnsHost   = undef;            # IP of MySensors Ethernet gateway
my $mysnsPort   = 5003;             # Port of MySensors Ethernet gateway

# -- Settings when using Serial gateway
my $serialPort   = undef;
my $serialBaud   = 115200;
my $serialBits   = 8;
my $serialParity = "none";
my $serialStop   = 1;

# -- Settings if gateway should perform nodeID allocation
# use this only if you do not have a controller available
my $firstID           = 0;       # 0 means disabled
my $lastID            = 254;
my $nodeIDStorageFile = undef;
my $nodeID = {};
  
my $subscriptionStorageFile = undef;

my $log = "STDOUT";                    # Default logging to stdout

my $exit_cause = undef;
my $helpme     = undef;
if ( GetOptions ( 'serial:s'   => \$serialPort,
                  'baud:i'     => \$serialBaud,
                  'bits:i'     => \$serialBits,
                  'parity:s'   => \$serialParity,
                  'stop:i'     => \$serialStop,
                  'root:s'     => \$topicRoot,
				  'topicC2N:s' => \$topicC2N,
				  'topic2node:s' => \$topic2node,
                  'mqtthost:s' => \$mqttHost,
                  'mqttport:i' => \$mqttPort,
                  'mqttuser:s' => \$mqttUser,
                  'mqttpasswd:s' => \$mqttPasswd,
                  'gwhost:s'   => \$mysnsHost,
                  'gwport:i'   => \$mysnsPort,
                  'storage:s'  => \$subscriptionStorageFile,
                  'log:s'      => \$log,
                  'help|h'     => \$helpme, 
				  'firstID:i'    => \$firstID,
				  'lastID:i'     => \$lastID,
				  'storageID:s'  => \$nodeIDStorageFile,) )
{
    if (!defined($helpme))
    {
      if (!defined($serialPort) && !defined($mysnsHost))
      {
        $exit_cause = "Select either ethernet connection (--gwhost) or serial connection (--serial) to gateway";
      }
      elsif (defined($serialPort) && defined($mysnsHost))
      {
        $exit_cause = "Select either ethernet connection (--gwhost) or serial connection (--serial) to gateway, but not both";
      }
    }
}
else
{
    $exit_cause = "Illegal commandline options";
}

# see if the nodeID's are correct
if ( ( $firstID < 0 || $firstID > 254 ) || ( $lastID < 0 || $lastID > 254 ) ) {
	$exit_cause = "Option firstID or lastID out of range; 0 < IDnumber < 255";
}
if ( $firstID >= $lastID ) {
	$exit_cause = "Option firstID is larger or equal to lastID";
}

print STDERR "\n--- Error: $exit_cause ---\n" if (defined($exit_cause));
PrintHelpAndExit() if (defined($helpme) || defined($exit_cause)); 

# take care about the wildcard topics; we need to subscribe to all messages
# so we have to add the mqtt wildcard
if ( !( $topicC2N =~ m/\/\#$/ ) ) {
	$topicC2N =~ s/[\/]{0,1}$/\/#/;
}
if ( !( $topic2node =~ m/\/\#$/ ) ) {
	$topic2node =~ s/[\/]{0,1}$/\/#/;
}

my $retain = 1;
my $qos = MQTT_QOS_AT_LEAST_ONCE;
my $keep_alive_timer = 120;
my $serialDevice;
my $mqtt = undef;
my $gw_handle = undef;
my @subscriptions;

# -- Switch to choose between Ethernet gateway or serial gateway
my $useSerial = defined($serialPort);

sub gettime
{
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
  return sprintf("%04d%02d%02d-%02d:%02d:%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec);
}
    
sub dolog
{
  print gettime() . " " . join(" ", @_)."\n";
}

sub debug
{
#  print gettime() . " [" . join(" ", @_)."]\n";
}

sub initialiseSerialPort
{
  dolog("Initialising serial port  $serialPort");
  $serialDevice = tie (*fh, 'Device::SerialPort', $serialPort) || die "Can't tie: $!";
  $serialDevice->baudrate($serialBaud);
  $serialDevice->databits($serialBits);
  $serialDevice->parity($serialParity);
  $serialDevice->stopbits($serialStop);
  $serialDevice->write_settings;
  # Flush serial buffers in case they contain old data/garbage
  $serialDevice->purge_all();
}

sub parseMsg
{
  my $raw = shift;
  my @fields = split(/;/,$raw);
  my $msgRef = { radioId => $fields[0],
                 childId => $fields[1],
                 cmd     => $fields[2],
                 ack     => $fields[3],
                 subType => $fields[4],
                 payload => $fields[5],
                 raw     => $raw };
  return $msgRef;
}

sub parseTopicMessage
{
  my ($topic, $message) = @_;
  if ($topic !~ s/^@{[$topicRoot]}\/?//)
  {
    # Topic root doesn't match
    return undef;
  }
  my @fields = split(/\//,$topic);
  my $msgRef = { radioId => int($fields[0]),
                 childId => int($fields[1]),
                 cmd     => C_SET,
                 ack     => 0,   # No way to tell ack from topic
                 subType => variableTypeToIdx( $fields[2] ),
                 payload => $message };
#  print Dumper($msgRef);
  return $msgRef;
}

sub createMsg
{
  my $msgRef = shift;
  my @fields = ( $msgRef->{'radioId'},
                 $msgRef->{'childId'},
                 $msgRef->{'cmd'},
                 $msgRef->{'ack'},
                 $msgRef->{'subType'},
                 defined($msgRef->{'payload'}) ? $msgRef->{'payload'} : "" );
  return join(';', @fields);
}

sub subTypeToStr
{
  my $cmd = shift;
  my $subType = shift;
  # Convert subtype to string, depending on message type
  given ($cmd)
  {
    when (C_PRESENTATION) { $subType = (sensorTypesToStr)[$subType]; }
    when (C_SET)		{ $subType = (variableTypesToStr)[$subType]; }
    when (C_REQ)		{ $subType = (variableTypesToStr)[$subType]; }
    when (C_INTERNAL)	{ $subType = (internalMessageTypesToStr)[$subType]; }
    default { $subType = "<UNKNOWN_$subType>" }
  }  
  return $subType;
}

sub dumpMsg
{
  my $rxtx = shift;
  my $msgRef = shift;
  my $action = shift;
  my $cmd = (commandToStr)[$msgRef->{'cmd'}];
  my $st = subTypeToStr( $msgRef->{'cmd'}, $msgRef->{'subType'} );
  my $ack = $msgRef->{'ack'} ? "ack" : "noack";
  my $payload = defined($msgRef->{'payload'}) ? "'".$msgRef->{'payload'}."'" : "";
#  dolog(sprintf("%s: [%s] fr=%d ci=%d c=%s st=%s %s %s -> %s", $rxtx, $msgRef->{'raw'}, $msgRef->{'radioId'}, $msgRef->{'childId'}, $cmd, $st, $ack, $payload, $action));
  dolog(sprintf("%s: [%-32s] fr=%03d ci=%03d c=%-14s st=%-16s %-5s %-20s -> %s", $rxtx, $msgRef->{'raw'}, $msgRef->{'radioId'}, $msgRef->{'childId'}, $cmd, $st, $ack, $payload, $action));
}

sub createTopic
{
  my $msgRef = shift;
  my $st = subTypeToStr( $msgRef->{'cmd'}, $msgRef->{'subType'} );
  # Note: Addendum to spec: a topic ending in a slash is considered equivalent to the same topic without the slash -> So we leave out the trailing slash
  return sprintf("%s/%d/%d/%s", $topicRoot, $msgRef->{'radioId'}, $msgRef->{'childId'}, $st);
}

# save message for later transmission
sub queueDelayedMessage {
	my $msg = shift;
	my ($nodeID) = split( ";", $msg );
	unshift( @{ $delayedMessages{$nodeID} }, $msg );
	return;
}

# do we have to delay the message to a node
sub delayMessage {
	my $msgRef = shift;
	my $sub = subTypeToStr( $msgRef->{'cmd'}, $msgRef->{'subType'} );
	if ( $sub ~~ @delayedMessageTypes ) {
		return 1;
	}
	return 0;
}

# handle messages that will be send to nodes
# message will always be delayed until a new message from the node is recevied
sub onMqtt2node {
	my ( $topic, $message ) = @_;
	my $ntopic = $topic2node;
	chop $ntopic;
	if ( $topic !~ s/^@{[$ntopic]}\/?// ) {
		return undef;
	}
	my ( $nodeId, $childId, $msgtype, $sub ) = split( "/", $topic );

	# sanity checks
	if ( !defined $sub ) {    # queue sends only nodeID, childId and sub
		$sub = $msgtype;
		if ( $sub =~ m/I_.*/ ) {
			$msgtype = C_INTERNAL;
		}
		else {
			$msgtype = C_SET;
		}
	}
	$message = "" if !defined $message;
	debug(
"Recevied message from node queue: $nodeId;$childId;$msgtype;$sub Payload: \"$message\""
	);

	# map message type
	if ( $sub =~ m/[IV]_.*/ ) {    # map sub to int
		if ( $sub =~ m/[I]_.*/ ) {
			$sub = imessageTypeToIdx($sub);
		}
		else {
			$sub = variableTypeToIdx($sub);
		}
	}
	my $msgRef = {
		radioId => int($nodeId),
		childId => int($childId),
		cmd     => int($msgtype),
		ack     => 0,               # No way to tell ack from topic
		subType => $sub,
		payload => $message
	};
	return $msgRef;
}

# handle controller messages that will be send to nodes
sub onMqttControler {
	my ( $topic, $message ) = @_;
	my $ctopic = $topicC2N;
	chop $ctopic;
	if ( $topic !~ s/^@{[$ctopic]}\/?// ) {
		return undef;
	}
	my ( $nodeId, $childId, $msgtype, $sub ) = split( "/", $topic );

	# sanity checks
	if ( !defined $sub ) {   # controler only sends only nodeID, childId and sub
		$sub = $msgtype;
		if ( $sub =~ m/I_.*/ ) {
			$msgtype = C_INTERNAL;
		}
		else {
			$msgtype = C_SET;
		}
	}
	$message = "" if !defined $message;
	debug(
"Recevied message from controller: $nodeId;$childId;$msgtype;$sub Payload: \"$message\""
	);

	# map message type
	if ( $sub =~ m/[IV]_.*/ ) {    # map sub to int
		if ( $sub =~ m/[I]_.*/ ) {
			$sub = imessageTypeToIdx($sub);
		}
		else {
			$sub = variableTypeToIdx($sub);
		}
	}
	my $msgRef = {
		radioId => int($nodeId),
		childId => int($childId),
		cmd     => int($msgtype),
		ack     => 0,               # No way to tell ack from topic
		subType => $sub,
		payload => $message
	};
	return $msgRef;
}

# Callback when MQTT broker publishes a message
sub onMqttPublish
{
  my($topic, $message) = @_;
	my $ctopic = $topicC2N;
	my $ntopic = $topic2node;
	chop $ctopic;                   # strip mqtt wildcard
	chop $ntopic;
	my $delay = 0;
	my $msgRef;
	if ( $topic =~ m/^$ctopic/ ) {
		$msgRef = onMqttControler( $topic, $message );
	}
	elsif ( $topic =~ m/^$ntopic/ ) {
		$delay = 1;
		$msgRef = onMqtt2node( $topic, $message );
	}
	else {
		$msgRef = parseTopicMessage( $topic, $message );
	}
	my $mySnsMsg = createMsg($msgRef);
	$msgRef->{'raw'} = $mySnsMsg;
	if ( $delay || delayMessage($msgRef) )
	{    # delay message because node can not receive at the moment
		dumpMsg( "Delayed", $msgRef,
			"Delayed until message from node is received" );
		queueDelayedMessage($mySnsMsg);
	}
	else {
		dumpMsg( "TX", $msgRef, "Publish to gateway '$topic':'$message'" );
		$gw_handle->push_write("$mySnsMsg\n") if ( defined $gw_handle );
	}
}

sub subscribe
{
  my $topic = shift;
  if (!($topic ~~ @subscriptions))
  {
    debug("Subscribe '$topic'");
    $mqtt->subscribe(
        topic    => $topic,
        callback => \&onMqttPublish,
        qos      => $qos );
  #      $cv->recv; # subscribed,

    # Add topic to list of subscribed topics, if not already present.
    push(@subscriptions, $topic);
  }  else  {
    debug("Subscribe '$topic' ignored -- already subscribed");
  }
}

sub unsubscribe
{
  my $topic = shift;
  if ($topic ~~ @subscriptions)
  {
    dolog("Unsubscribe '$topic'");
    $mqtt->unsubscribe(
        topic    => $topic
      );

    # Remove topic from list of subscribed topics, if present.
    @subscriptions = grep { !/^$topic$/ } @subscriptions;
  }  else  {
    dolog("Unsubscribe '$topic' ignored -- not subscribed");
  }
}


sub publish
{
  my ($topic, $message) = @_;
  $message = "" if !defined($message);
#  debug("Publish to broker '$topic':'$message'");
  $mqtt->publish(
      topic   => $topic,
      message => $message,
      retain  => 1,
      qos     => $qos,
    );

  # Publish timestamp of last update
  $mqtt->publish(
    topic   => "$topic/lastupdate",
    message => gettime(),
    retain  => 1,
    qos     => $qos,
  );
}

sub onNodePresenation
{
  # Node announces itself on the network
  my $msgRef = shift;
  my $radioId = $msgRef->{'radioId'};

  # Remove existing subscriptions for this node
  foreach my $topic( grep { /^@{[$topicRoot]}\/$radioId\// } @subscriptions )
  {
    unsubscribe($topic);
  }
}

sub onRequestTime
{
  # Node requests current time from gateway
  my $msgRef = shift;
  # Get seconds since epoch, but correct for local time zone
  my $ts = time + tz_local_offset();
  $msgRef->{'payload'} = $ts;
  my $mySnsMsg = createMsg($msgRef);
  dolog("Request time: $ts => $mySnsMsg");
  $gw_handle->push_write("$mySnsMsg\n") if (defined $gw_handle);
}

sub onRequestNodeID {

	# Node requests a nodeID; do this ONLY if you NOT have a crontroller
	my $msgRef = shift;

	return if ( $firstID <= 0 );    # oops; we should not have been called
	for ( my $i = $firstID ; $i <= $lastID ; $i++ ) {
		if ( !defined $nodeID->{$i} ) {
			$nodeID->{$i} = localtime;

			# save the id
			store( $nodeID, $nodeIDStorageFile );
			$msgRef->{'payload'} = $i;
			$msgRef->{'subType'} = I_ID_RESPONSE;
			my $mySnsMsg = createMsg($msgRef);
			dolog("Request nodeID: $i => $mySnsMsg");
			$gw_handle->push_write("$mySnsMsg\n") if ( defined $gw_handle );
			return;
		}
	}
	dolog("Request nodeID: but no nodeID available");
}

# check and note radioId during receive
sub checkNodeID {
	my $nID = shift;
	return if ( $nID == 0 || defined $nodeID->{$nID} );
	debug("new radioId $nID discovered");
	if ( $nID >= $firstID && $nID <= $lastID ) {
		dolog(
			"WARNING: radioID $nID was not given by me! Remember new radioID");
	}
	$nodeID->{$nID} = localtime;
	store( $nodeID, $nodeIDStorageFile );
}


sub handleRead
{
  my $data = shift;
  chomp($data);
  debug($data);

  my $msgRef = parseMsg($data);
  given ($msgRef->{'cmd'})
  {
    when ([C_PRESENTATION, C_SET, C_INTERNAL])
    {
      onNodePresenation($msgRef) if (($msgRef->{'childId'} == 255) && ($msgRef->{'cmd'} == C_PRESENTATION));
      onRequestTime($msgRef)     if (($msgRef->{'cmd'} == C_INTERNAL) && ($msgRef->{'subType'} == I_TIME));
	  onRequestNodeID($msgRef)   if ( ( $nodeID > 0 ) && ( $msgRef->{'cmd'} == C_INTERNAL ) && ( $msgRef->{'subType'} == I_ID_REQUEST ) );
      my $topic   = createTopic($msgRef);
      my $message = $msgRef->{'payload'};
	  $message = "" if !defined $message;
      dumpMsg("RX", $msgRef, "Publish to broker '$topic':'$message'");
      publish( $topic, $message );
    }
    when (C_REQ)
    {
      my $topic   = createTopic($msgRef);
      dumpMsg("RX", $msgRef, "Subscribe to '$topic'");
      subscribe( $topic );
    }
    default
    {
      # Ignore
      dumpMsg("RX", $msgRef, "Ignored");
    }
  }
  	# check for delayed messages and send
	# but send only one message to not collide with messages from node
	if ( my $msg = pop( @{ $delayedMessages{ $msgRef->{radioId} } } ) ) {
		my $mRef = parseMsg($msg);
		dumpMsg( "TX", $mRef, "Publish to node '$msgRef->{radioId}'" );
		$gw_handle->push_write("$msg\n") if ( defined $gw_handle );
	}
}
  
sub onCtrlC
{
  dolog("\nShutdown requested...");
  dolog("unsubscribe to Controller topic \"$topicC2N\"");
  unsubscribe($topicC2N);
  dolog("unsubscribe to sensors node topic \"$topic2node\"");
  unsubscribe($topic2node);
  store(\@subscriptions, $subscriptionStorageFile);
  exit;
}

sub onSigHUP {
        # for logrotate; reopen logfile
        if ( $log ne "STDOUT" ){
                close(OUT);
                open( OUT, ">>$log" ) || die "Unable to write to logfile '$log': $!\n";
                *STDOUT = *OUT;
        }
}


if ($log ne "STDOUT")
{
        # redirect STDOUT to logfile
        open(OUT, ">>$log") || die "Unable to write to logfile '$log': $!\n";
        *STDOUT = *OUT;
}
# Flush STDOUT
$| = 1;

# Define storage file, when not available
if (!defined($subscriptionStorageFile))
{
    $subscriptionStorageFile = $useSerial ? $serialPort : $mysnsHost."_".$mysnsPort;
    $subscriptionStorageFile =~s/[\\\/\:\? ]/_/g;
    $subscriptionStorageFile = "/var/run/mqttMySensors/Gateway_".$subscriptionStorageFile;
}

# If file does not exist, create it here
if (! -e $subscriptionStorageFile)
{
  store(\@subscriptions, $subscriptionStorageFile) || die "Failed to create subscription file '$subscriptionStorageFile': $!";
}
# Get an exclusive lock on the subscription file, to prevent multiple instances from running simultaneously.
die "Fatal error: Unable to open subscription file '$subscriptionStorageFile'. Another instance of this script might be running." unless (open SS, $subscriptionStorageFile);
die "Fatal error: Subscription file '$subscriptionStorageFile' is locked by another process." unless(flock SS, LOCK_EX|LOCK_NB);

# Define nodeID storage file, when not available
if ( !defined($nodeIDStorageFile) ) {
	$nodeIDStorageFile =
	  $useSerial ? $serialPort : $mysnsHost . "_" . $mysnsPort;
	$nodeIDStorageFile =~ s/[\\\/\:\? ]/_/g;
	$nodeIDStorageFile = "/var/run/mqttMySensors/nodeID_" . $nodeIDStorageFile;
}

# If file does not exist, create it here
if ( !-e $nodeIDStorageFile ) {
	store( $nodeID, $nodeIDStorageFile ) || die "Failed to create nodeID file '$nodeIDStorageFile': $!";
}

# Get an exclusive lock on the nodeID file, to prevent multiple instances from running simultaneously.
die "Fatal error: Unable to open nodeID file '$nodeIDStorageFile'. Another instance of this script might be running." unless ( open NS, $nodeIDStorageFile );
die "Fatal error: nodeID file '$nodeIDStorageFile' is locked by another process." unless ( flock NS, LOCK_EX | LOCK_NB );


dolog("MQTT Client Gateway for MySensors");
dolog("Broker:        $mqttHost:$mqttPort");
dolog("ClientID:      $mqttClientId");
dolog("MySensors GW:  ".($useSerial ? "$serialPort, $serialBaud, $serialBits$serialParity$serialStop" : "$mysnsHost:$mysnsPort"));
dolog("Subscriptions: $subscriptionStorageFile");
dolog("");

# Install Ctrl-C handler
$SIG{INT} = \&onCtrlC;
$SIG{HUP} = \&onSigHUP;

initialiseSerialPort()  if ($useSerial);

while (1)
{
  # Run code in eval loop, so die's are caught with error message stored in $@
  # See: https://sites.google.com/site/oleberperlrecipes/recipes/06-error-handling/00---simple-exception
  local $@ = undef;
  eval
  {
    $mqtt = AnyEvent::MQTT->new(
        host => $mqttHost,
        port => $mqttPort,
        keep_alive_timer => $keep_alive_timer,
        user_name => $mqttUser,
        password => $mqttPasswd,
        on_error => sub {
          my ($fatal, $message) = @_;
          if ($fatal) {
            die $message, "\n";
          } else {
            warn $message, "\n";
          }
        },
#          clean_session => 0,   # Retain client subscriptions etc
        client_id => $mqttClientId,
        );

    my $cv;
    
    if ($useSerial)
    {
      $gw_handle = AnyEvent::Handle->new(
        # fh => $serialDevice->{'HANDLE'},
		fh       => new_from_fd IO::Handle( $serialDevice->{FD}, "w" ),
        on_error => sub {
          my ($handle, $fatal, $message) = @_;
          $handle->destroy;
          undef $handle;
          $cv->send("$fatal: $message");
        },
        on_read => sub {
          my $handle = shift;
          $handle->push_read(line => sub {
            my ($handle, $line) = @_;
            handleRead($line);
          });
        }
      );
    }
    else
    {
      tcp_connect($mysnsHost, $mysnsPort, sub {
          my $sock = shift or die "FAIL";
          $gw_handle = AnyEvent::Handle->new(
               fh => $sock,
               on_error => sub {
                  my ($handle, $fatal, $message) = @_;
                  if ($fatal) {
                    die $message, "\n";
                  } else {
                    warn $message, "\n";
                  }
               },
               on_eof => sub {
                  $gw_handle->destroy();
                  die "Disconnected from MySensors gateway!";
               },
               on_connect => sub {
                 my ($handle, $host, $port) = @_;
                 dolog("Connected to MySensors gateway at $host:$port");
               },
               on_read => sub {
                 my $handle = shift;
                 handleRead($handle->rbuf);
                 # Clear the buffer
                 $handle->rbuf = "";
               }
             );
        }
      );
    }
	
	# subscribe to Controller topic
	dolog("subscribe to Controller topic \"$topicC2N\"");
	subscribe($topicC2N);

	# subscribe to node topic
	dolog("subscribe to node topic \"$topic2node\"");
	subscribe($topic2node);
    
    # On shutdown active subscriptions will be saved to file.
    # Read this file here and restore subscriptions.
dolog("trying to restore subscriptions");
    if (-e $subscriptionStorageFile)
    {
      my $subscrRef = retrieve($subscriptionStorageFile);
      dolog("Restoring previous subscriptions:") if @$subscrRef;
      foreach my $topic(@$subscrRef)
      {
        subscribe($topic);
      }
    }
    
	# try to restore nodeID database
	if ( $firstID > 0 ) {
		dolog("trying to restore nodeID's");
		if ( -e $nodeIDStorageFile ) {
			$nodeID = retrieve($nodeIDStorageFile);
			my $c = keys %{$nodeID};
			dolog("restored $c nodeID's");
		}
	}
		
    $cv = AnyEvent->condvar;
    $cv->recv; 
  }
  or do
  { 
    dolog("Exception: ".$@);
    store(\@subscriptions, $subscriptionStorageFile);

    dolog("Restarting...");
    # Clear list of subscriptions or subscriptions will not be restored correctly.
    @subscriptions = ();
  }
}

sub PrintHelpAndExit
{
print STDERR <<SYNTAX;
    
mqttGateway2 - Created by Ivo Pullens, Emmission, (c)2014-2016
An MQTT gateway for use with the MySensors serial or ethernet gateway.

Usage:      mqttGateway2 [--serial dev [--baud baudrate] [--bits bits] [--parity [none|odd|even]] [--stop numbits]] 
                         [--gwhost hostip [--gwport port]]
                         [--root mqttroot] [--topicC2N mqttcontrq] [--topic2node mqttnodeq]
                         [--mqtthost mqtthost] [--mqttport mqttport] [--mqttuser mqttuser] [--mqttpasswd mqttpassword]
                         [--storage file] [--log file]
            mqttGateway2 --help

Options:    For serial connection to gateway:
            --serial    Serial device connected to MySensors gateway, e.g. /dev/ttyUSB1
            --baud      Serial baudrate, defaults to 115200
            --bits      Serial nr of bits, defaults to 8
            --parity    Serial parity, default to none.
            --stop      Serial stopbits, defaults to 1

            For ethernet connection to gateway:
            --gwhost    IP address of ethernet gateway
            --gwport    Port of ethernet gateway, defaults to 5003

            Generic options:
            --root      MQTT root topic (no trailing slash), defaults to /mySensors
			--topicC2N  MQTT topic where controller messages are received and sent to nodes (/mySensorsC2N)
            --topic2node MQTT topic used to send any message to a sensor node, defaults to /mySensors2node
            --mqtthost  IP address of MQTT broker, defaults to localhost
            --mqttport  Port of MQTT broker, defaults to 1883
            --mqttuser  the username used to authenticate to mqtt server
            --mqttpasswd the password used to authenticate to mqtt server
            --storage   File used for storing active subscriptions, defaults to /var/run/mqttMySensors/Gateway_xxx
            --log       File to log to, defaults to stdout
			If you do not have a controller and the gateway should assigne nodeID's
            --firstID	first nodeID to give to sensors, defaults to 0 -> do not give away nodeID's
            --lastID	last nodeID to give to sensors; 0 < IDnumber < 255
            --storageID File used to store nodeID's, defaults to /var/run/mqttMySensors/nodeID_xxx

SYNTAX
    exit 1;
}


