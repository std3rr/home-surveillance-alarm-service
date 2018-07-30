#!/usr/bin/perl

#####################################
#
# Homealarm all-in-one-script-daemon
# run by cron on my raspberry pi
#    * * * * * /home/pi/homealarm.pl --reset 2>&1 | tee -a /var/log/proc.homealarm.log
# Dependencies:
#   rtl_433 (for tracking/monitor magnet- and movement- sensors )
#   hubbleconnect ( cloud service for controlling my motorola focus-66 ipcam )
#   pilot or prowl ( generating mobile push notice, using prowl atm )
#   asus router ( for geofencing mobile devices connected to my RT-AC66U )
#
# I always check sensors, loggs all known events.
# I log unknown devices only once, to keep track whats emerging in the surrounding and when.
# Its very fascinating to see how much 433 devices we have around, even in the bush. :)
# When none of our phones are present after a minute we fire push notice and activate the shell protection state.
# If any sensor is triggered in this state we fire push notice and arm the ipcam, logging videos to the hubble cloud.
# If it has'nt recieved any radio events for over 5 minutes it will reset it self
#
# By Andreas Lewitzki 2017
#####################################

use strict;
use JSON::XS qw(decode_json);

our $DEBUG = 0;

our $asus_router_ip = '192.168.2.1';
our $asus_router_auth = 'YWRta#########TE1bjA3';
our $asus_router_token = '';
our $hubble_device = '0100660#######CGSYMA';
our $hubble_key = 'o9m4#########7cj3RR';
our $pilot_key = 'Mo#####R8f';
our $prowl_key = '8ddf8########23f3c296';
our $map = {
                ##01  => {name=>'huvudentré'},
                ##27  => {name=>'garageport'},
                ##41  => {name=>'groventré'},
                ##87  => {name=>'garagedörr'},
                ##368 => {name=>'altandörr'},
                ##517 => {name=>'sovrum'},
                ##116 => {name=>'el-central'},
                #####261 => {name=>'rörelsesensor'}
};

our $min_msg_interval = 3;
our $last_in_ts = time;
our $poke_router_at = time + (60*60*24);

sub asus_router_poke {
                qx{ 
/usr/bin/curl "http://$asus_router_ip/Main_Login.asp" -H "Upgrade-Insecure-Requests: 1" -H "Referer: http://$asus_router_ip/" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36" --compressed 2>/dev/null
};
}

sub asus_router_poke_token {
                $asus_router_token = [qx{
/usr/bin/curl -D - 'http://$asus_router_ip/login.cgi' -H 'Origin: http://router.asus.com' -H 'Accept-Encoding: gzip, deflate' -H 'Accept-Language: sv-SE,sv;q=0.8,en-US;q=0.6,en;q=0.4' -H 'Upgrade-Insecure-Requests: 1' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36' -H 'Content-Type: application/x-www-form-urlencoded' -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8' -H 'Cache-Control: max-age=0' -H 'Referer: http://192.168.2.1/Main_Login.asp' -H 'Connection: keep-alive' --data 'group_id=&action_mode=&action_script=&action_wait=5&current_page=Main_Login.asp&next_page=index.asp&login_authorization=$asus_router_auth' --compressed 2>&1 
                } =~ /asus_token=([a-zA-Z0-9]+)/]->[0];
                asus_router_poke();
                return $asus_router_token;
}

sub asus_device_discovery {
                return qx{
/usr/bin/curl "http://$asus_router_ip/update_clients.asp?_=@{[time]}" -H "Cookie: traffic_warning_0=2017.8:1; asus_token=$asus_router_token" -H "Accept-Encoding: gzip, deflate" -H "Accept-Language: sv-SE,sv;q=0.8,en-US;q=0.6,en;q=0.4" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36" -H "Accept: text/javascript, application/javascript, application/ecmascript, application/x-ecmascript, */*; q=0.01" -H "Referer: http://$asus_router_ip/index.asp" -H "X-Requested-With: XMLHttpRequest" -H "Connection: keep-alive" --compressed 2>/dev/null
};
}


if("@ARGV"=~/wifi/)
{
                asus_router_poke_token();
                print asus_device_discovery();  
                exit;
}

# this dependes on shell layers
exit if @{[qx(pgrep -f "homealarm.pl")]} > 3;

log_this("Initializing service");
unless(-e "/tmp/homealarm.ts")
{
                push_notice("homealarm system","bootup");
                system("touch /tmp/homealarm.ts");
}



my $cam_off = qq{
/usr/bin/curl 'https://api.hubble.in/v1/devices/$hubble_device/send_command.json?api_key=$hubble_key' -X OPTIONS -H 'Access-Control-Request-Method: POST' -H 'Origin: https://app.hubbleconnected.com' -H 'Accept-Encoding: gzip, deflate, br' -H 'Accept-Language: sv-SE,sv;q=0.8,en-US;q=0.6,en;q=0.4' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36' -H 'Accept: */*' -H 'Referer: https://app.hubbleconnected.com/' -H 'Connection: keep-alive' -H 'Access-Control-Request-Headers: content-type' --compressed && \
/usr/bin/curl 'https://api.hubble.in/v1/devices/$hubble_device/send_command.json?api_key=$hubble_key' -H 'Origin: https://app.hubbleconnected.com' -H 'Accept-Encoding: gzip, deflate, br' -H 'Accept-Language: sv-SE,sv;q=0.8,en-US;q=0.6,en;q=0.4' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36' -H 'Content-Type: application/json' -H 'Accept: application/json, text/javascript, */*; q=0.01' -H 'Referer: https://app.hubbleconnected.com/' -H 'Connection: keep-alive' --data-binary '{"action":"command","command":"action=command&command=set_motion_area&grid=1x1&zone="}' --compressed
};

my $cam_on = q{
/usr/bin/curl 'https://api.hubble.in/v1/devices/$hubble_device/send_command.json?api_key=$hubble_key' -X OPTIONS -H 'Access-Control-Request-Method: POST' -H 'Origin: https://app.hubbleconnected.com' -H 'Accept-Encoding: gzip, deflate, br' -H 'Accept-Language: sv-SE,sv;q=0.8,en-US;q=0.6,en;q=0.4' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36' -H 'Accept: */*' -H 'Referer: https://app.hubbleconnected.com/' -H 'Connection: keep-alive' -H 'Access-Control-Request-Headers: content-type' --compressed && \
curl 'https://api.hubble.in/v1/devices/$hubble_device/send_command.json?api_key=$hubble_key' -H 'Origin: https://app.hubbleconnected.com' -H 'Accept-Encoding: gzip, deflate, br' -H 'Accept-Language: sv-SE,sv;q=0.8,en-US;q=0.6,en;q=0.4' -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Safari/537.36' -H 'Content-Type: application/json' -H 'Accept: application/json, text/javascript, */*; q=0.01' -H 'Referer: https://app.hubbleconnected.com/' -H 'Connection: keep-alive' --data-binary '{"action":"command","command":"action=command&command=set_motion_area&grid=1x1&zone=00"}' --compressed
};

sub set_cam_motion_sensor {
                shift ? qx{$cam_on} : qx{$cam_off};
}


sub is_at_home {
                if(time >= $poke_router_at)
                {
                                log_this("poking router!");
                                asus_router_poke_token();
                                $poke_router_at = time + (60*60*24);
                }
                return asus_device_discovery()=~/"(?:C8:1E:E7:51:XX:XX|60:F8:1D:2D:XX:XX|4C:74:BF:C8:XX:XX)"/;
                #return qx{$disco}=~/"Therese\%2DiPhone"/;
                #return qx{$disco}=~/"andreas\%20iphone"/;
}

sub pilot_push_notice {
                my $subject = shift;
                my $message = shift;
                qx(/usr/bin/curl -L http://api.pilot.patrickferreira.com/$pilot_key/$subject/$message);
}

sub prowl_push_notice {
                my $app = 'hemlarm';
                my $subject = shift;
                my $message = shift;

                qx( /usr/bin/curl https://prowl.weks.net/publicapi/add -F apikey=$prowl_key -F priority=1 -F application="$app" -F event="$subject" -F description="$message" )
}

sub push_notice { &prowl_push_notice }

sub log_this {
                my $message = shift;
                chomp($message);
                my $ts = qx{date +'%Y-%m-%d %H:%M:%S'};
                chomp($ts);
                open LOG,">>/var/log/homealarm.log" or warn "unable to log!: $!";
                print LOG "$ts: $message\n";
                close LOG;
}

sub reset_receiver {
                qx{sudo sh -c "echo 0 > /sys/bus/usb/devices/1-1.3/authorized" && sudo sh -c "echo 1 > /sys/bus/usb/devices/1-1.3/authorized"};
}

sub log_uniq_sensor {

                my $id = shift;
                my $json = shift;

                unless( -e "/var/log/devices433/$id" )
                {
                                open DEVICE,">/var/log/devices433/$id";
                                print DEVICE $json;
                                close DEVICE;
                }
}

# This is the periodic events firing every other second
alarm(2);
$SIG{ALRM} = sub{
                print "Got Alarm!\n" if $DEBUG;
                if( time - $last_in_ts > 60*5 )
                {
                                log_this("Everything is so quiet and cold, exiting!");
                                push_notice("Hemlarm" => "Väldigt tyst! Startar om...");
                                exit;
                }
                unless( $map->{checking_devices} )
                {
                                $map->{checking_devices} = 1;
                                my $at_home = is_at_home || 0;
                                print "alarm: is_at_home = $at_home\n" if $DEBUG;
                                $map->{count_down_to_activation} = 30 if $at_home;
                                if($map->{count_down_to_activation} && !$at_home)
                                {
                                                print "count_down_to_activation = $map->{count_down_to_activation}\n" if $DEBUG;
                                                if(--$map->{count_down_to_activation} == 0)
                                                {
                                                                log_this("\@home=$at_home:Skalskydd:Aktiverat");
                                                                push_notice("Skalskydd" => "Aktiverat");
                                                                $map->{is_at_home} = $at_home;
                                                }
                                                                
                                }
                                elsif(exists $map->{is_at_home} && $map->{is_at_home} != $at_home)
                                {
                                                if($at_home)
                                                {
                                                                log_this("\@home=$at_home:Skalskydd:Inaktiverat");
                                                                push_notice("Skalskydd" => "Inaktiverat");
                                                                set_cam_motion_sensor(0);
                                                                $map->{is_at_home} = $at_home;
                                                }
                                }
                                $map->{is_at_home} = $at_home unless exists $map->{is_at_home};
                                
                }
                delete $map->{checking_devices};
                alarm(2);              
};

if("@ARGV"=~/reset/)
{
                reset_receiver();
}
                
# main loop processing 433 sensor data
open RTL433,"/usr/local/bin/rtl_433 -F json|" or die "unable to load rtl_433: $!";

while(my $json = <RTL433>)
{
                if($json=~/^{.+}$/)
                {
                                my $d = decode_json($json);
                                my $id = $d->{id};
                                my ( $known_sensor, $last_ts ) = @{$map->{$id}}{'name','last_ts'};

                                $last_in_ts = time;
                                if( !$last_ts || (time - $last_ts) > $min_msg_interval )
                                {
                                                log_uniq_sensor( $id => $json );

                                                if( $known_sensor )
                                                {
                                                                my $at_home = $map->{is_at_home};

                                                                log_this("\@home=$at_home:$known_sensor:$json");

                                                                if( $known_sensor eq 'el-central' )
                                                                {
                                                                                push_notice($known_sensor,'öppnad');
                                                                }
                                                                elsif( not $at_home )
                                                                {
                                                                                push_notice($known_sensor,'öppnad');
                                                                                set_cam_motion_sensor(1);
                                                                }
                                                }

                                                $map->{$id}{last_ts} = time;
                                }
                }
}
