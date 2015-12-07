package GRNOC::perfSONAR::Collector;

use Moo;
use strictures;

use GRNOC::WebService::Client;
use GRNOC::Log;

use LWP::UserAgent;
use JSON qw( encode_json decode_json );
use Storable 'dclone';
use Proc::Daemon;
use Math::Round qw( nhimult );
use Data::Dumper;
use Try::Tiny;

### constants ### 
use constant SLEEP_OFFSET => 30;

### required attributes ###

has config_file => ( is => 'ro',
                     required =>  1 );

has logging_file => ( is => 'ro',
		      required => 1 );

has pid_file => ( is => 'ro',
		  required => 1 );

### optional attributes ###

has daemonize => ( is => 'ro',
                   default => 1 );

has time_range => ( is => 'rwp');

has time_start => ( is => 'rwp');

has time_end => ( is => 'rwp');

has time_range_cli => ( is => 'rwp');

has batch_size => ( is => 'rwp',
                    default => 100 );

has run_once => ( is => 'rwp',
                  default => 0 );

### internal attributes ###

has error => ( is => 'rwp',
               trigger => sub { my ( $self, $error ) = @_;

                                $self->logger->error( $error );
               } );

has config => ( is => 'rwp' );

has logger => ( is => 'rwp' );

has running => ( is => 'rwp' );

has first_run => ( is => 'rwp' );

has hup => ( is => 'rwp' );

has interval => ( is => 'rwp' );

has user => ( is => 'rwp' );

has pass => ( is => 'rwp' );

has tsds_location => ( is => 'rwp' );

has esmond_urls => ( is => 'rwp' );

has event_types_conf => ( is => 'rwp' );

has measurement_data => ( is => 'rwp' );

has default_tsds_interval => (is => 'rwp' );

### constructor builder ###

sub BUILD {
    my ( $self ) = @_;

    $self->_set_measurement_data( [] );
    $self->_set_first_run( 1 );

    # parse config using config_file passed in
    $self->_parse_config();

    # create and store logger object
    my $grnoc_log = GRNOC::Log->new( config => $self->logging_file );
    my $logger = GRNOC::Log->get_logger();

    $self->_set_logger( $logger );

    return $self;
}


### public methods ###

sub start {

    my ( $self ) = @_;

    # do we need to daemonize?
    if ( $self->daemonize ) {

        my $daemon = Proc::Daemon->new( pid_file => $self->{'pid_file'} );

        # daemonize
        my $pid = $daemon->Init();

        # we're in the child/daemon process
        if ( !$pid ) {

            # change the name of our process
            $0 = 'perfsonar_collector';

            # setup our signal handlers
            $SIG{'TERM'} = sub { $self->stop(); };
            $SIG{'HUP'} = sub { $self->logger->info( 'Received HUP' ); $self->_set_hup( 1 ) };

            # loop forever, doing the actual collecting
            $self->_set_running( 1 );

            $self->_loop();
        }
    }

    # we're not daemonizing
    else {

        # loop forever, doing the actual collecting
        $self->_set_running( 1 );
        $self->_loop();
    }
}

sub stop {

    my ( $self ) = @_;

    $self->_set_running( 0 );
}

sub _loop {

    my ( $self ) = @_;

    my $first_run = $self->first_run;

    $self->logger->info( 'Starting perfSONAR TSDS collector... ' );

    # continually loop while we're supposed to still be running
    while ( $self->running ) {

        # figure out when we need to wake up next, and how much longer we must sleep
        my $now = time();
        my $timestamp = nhimult( $self->interval, $now );
        my $sleep_seconds = $timestamp - $now + SLEEP_OFFSET;

        # sleep loop needed because HUP interrupts sleep() prematurely
        while ( $sleep_seconds > 0 && !$first_run ) {
            # figure out how long we actually sleep
            my $time_slept = sleep( $sleep_seconds );

            # did we wakeup because someone told us to stop?
            last if ( !$self->running );

            # subtract off the actual time we slept
            $sleep_seconds -= $time_slept;
            $self->_update_time_range();        
        }

        last if ( !$self->running );

        # did we HUP and need to reparse the config?
        if ( $self->hup ) {

            $self->logger->info( "Handling HUP, reloading config." );
            $self->_parse_config();
            $self->_set_hup( 0 );
        }

        # collect all data from all hosts for this time interval prior to sleeping again
        $self->logger->info("starting run ...");
        $self->logger->info("getting data ...");

	try {

	    $self->get_esmond_data();
	}

	catch {

	    $self->logger->error( $_ );
	};
	
        $self->logger->info("run complete.");

        $first_run = 0;
        $self->_set_first_run( $first_run );
        last if $self->run_once;
    }
}

sub _parse_config {

    my ( $self ) = @_;

    my $config = GRNOC::Config->new( config_file => $self->{'config_file'} ); 
    
    # store our parsed config
    $self->_set_config( $config );

    # parse and store timeseries location and credentials
    my $timeseries = $config->get('/config/timeseries')->[0];
    my $tsds_location = $timeseries->{'location'};
    my $user = $timeseries->{'user'};
    my $pass = $timeseries->{'pass'};
    $self->_set_tsds_location( $tsds_location );
    $self->_set_user( $user );
    $self->_set_pass( $pass );

    my $default_tsds_interval = 60;
    $default_tsds_interval = $config->get('/config/default_tsds_interval')->[0] if defined $config->get('/config/default_tsds_interval');
    $self->_set_default_tsds_interval( $default_tsds_interval );

    $self->_set_batch_size( $config->get('/config/batch_size')->[0] ) if defined $config->get('/config/batch_size');

    $self->_update_time_range();

    my $run_interval = $config->get('/config/run_interval')->[0];
    $self->_set_interval( $run_interval );

    my $esmond = $config->get('/config/esmond')->[0];
    $self->_set_esmond_urls( $esmond->{'location'} );
    $self->_set_event_types_conf( $config->get('/config/esmond/event_type') );
}

sub send_esmond_data {
    my ( $self ) = @_;
    my $measurement_data = $self->measurement_data;

    my $websvc = GRNOC::WebService::Client->new(
        cookieJar => "/tmp/perfsonar_data_pusher_cookies.txt",
        usePost => 1,
	error_callback => sub {
	    
	    my ( $websvc ) = @_;

	    die( "Error sending data to TSDS: " . $websvc->get_error );
	}
        );

    $websvc->set_credentials( uid => $self->user, passwd => $self->pass );
    $websvc->set_url( $self->{'tsds_location'} );

    if(@$measurement_data) {
        #$self->logger->info('sending data ... ' . @$measurement_data);
        #warn "measurement_data " . Dumper $measurement_data;
        my $json = encode_json($measurement_data);

        foreach my $location( @{ $self->tsds_location } ){
            $websvc->set_url($location);

            my $results = $websvc->add_data(data => $json);

            if(!$results){
                $self->logger->info("error adding data; results: " . Dumper $results);
                return 0;
            } else {
                $measurement_data = [];
                $self->_set_measurement_data( $measurement_data );
                return 1;
            }
        }
    }
}

sub get_esmond_data {
    my ( $self ) = @_;
    my $event_types_conf = $self->{'event_types_conf'};    
    foreach my $base_url (@{ $self->{'esmond_urls'} } ) {
        foreach my $event_type_obj (@{ $self->{'event_types_conf'} }) {
            my $result = $self->get_esmond_values($event_type_obj, $base_url);
        }
    }
    my $num_points = @{ $self->measurement_data };
}

sub set_measurement_metadata {
    my $self = shift;
    my $row = shift;

    my $measurement = {};
    my $source_name;
    my $source_ip;
    my $dest_name;
    my $dest_ip;
    if ( $row->{'measurement-agent'} eq $row->{'source'} ) {
        $source_name = $row->{'input-source'};
        $source_ip = $row->{'source'};
        $dest_name = $row->{'input-destination'};
        $dest_ip = $row->{'destination'};
    } else {
        $dest_name = $row->{'input-source'};
        $dest_ip = $row->{'source'};
        $source_name = $row->{'input-destination'};
        $source_ip = $row->{'destination'};
    }

    $source_name = '' if ( $source_name eq $source_ip);
    $dest_name = '' if ( $dest_name eq $dest_ip);

    $measurement->{'meta'}->{'destination'} = $dest_ip; 
    $measurement->{'meta'}->{'destination_name'} = $dest_name;

    $measurement->{'meta'}->{'source'} = $source_ip; 
    $measurement->{'meta'}->{'source_name'} = $source_name;

    my $description = '';
    if ($source_name ne '') {
        $description .= $source_name;
    } else {
        $description .= $source_ip;
    }
    $description .= " to ";
    if ($dest_name ne '') {
        $description .= $dest_name;
    } else {
        $description .= $dest_ip;
    }
    $measurement->{'meta'}->{'description'} = $description;

    return $measurement;
}

sub get_esmond_values {
    my $self = shift;
    my $event_type_obj = shift;
    my $base_url = shift;
    my $host_base_url = $base_url;
    # strip everything after the host/IP
    $host_base_url =~ s|(https?)://([^/]+)/.+|$1://$2|;

    my %urls = ();

    my $event_type = $event_type_obj->{'name'};
    my $measurement_type = $event_type_obj->{'tsds_measurement_type'};

    my @sub_event_types = ();
    foreach my $data (@{ $event_type_obj->{'data'} }) {
        push @sub_event_types, $data->{'summary_name'};
    }
    my $time_range = $self->time_range;
    my $time_start = $self->time_start;
    my $time_end = $self->time_end;
    
    my @params = ();
    push @params, 'event-type=' . $event_type;
    push @params, 'time-start=' . $time_start if ($time_start);
    push @params, 'time-end=' . $time_end if ($time_end);
    my $url = $base_url . "?";
    if ( @params > 0 ) {
        $url .= join('&', @params);
    }

    # retrieve data from esmond webservice
    my $www = LWP::UserAgent->new();
    my $response = $www->get( $url );

    if ( !$response->is_success ) {

	die( "Error retrieving data from esmond: " . $response->status_line );
    }

    my $res = decode_json( $response->decoded_content );

    foreach my $row (@$res) {
        foreach my $row_et (@{ $row->{'event-types'} }) {
            my $row_et_name = $row_et->{'event-type'};
            my $default_interval = $self->default_tsds_interval;
            next if not grep { /$row_et_name/ } @sub_event_types;
            foreach my $config_value ( @{ $event_type_obj->{'data'} } ) {
                my $type = $config_value->{'type'};
                my $summary_name = $config_value->{'summary_name'};
                my $window = $config_value->{'window'} || $default_interval;
                if ($summary_name ne $row_et_name) {
                    next;
                }
                my $measurement = {};
                $measurement = $self->set_measurement_metadata($row);
                $measurement->{'type'} = $measurement_type;
                my $interval = $default_interval;
                $interval = $row->{'time-interval'} if $row->{'time-interval'};
                $interval = $config_value->{'window'} if defined $config_value->{'window'};
                my $time_interval = '';
                $time_interval = $row->{'time-interval'} if defined $row->{'time-interval'};
                $self->logger->warn("WARNING: sending TSDS an interval of 0 ") if int($interval) == 0;
                $measurement->{'interval'} = int($interval);

                my $values_url = $self->get_values_url($host_base_url, $config_value, $row_et);
                if (not defined $values_url) {
                    $self->logger->info( "VALUES URL NOT DEFINED" );
                } else {
                    my $values = $self->get_values_from_url($values_url, $config_value, $measurement);

                }

            }

        }

    }
    # Send any remaining values
    $res = $self->send_esmond_data(); 
}

sub get_values_from_url {
    my $self = shift;
    my $url = shift;
    my $config_values = shift;
    my $metadata = shift;
    #$self->logger->info('values_url: ' . $url);
    my $results = decode_json(get($url));
    my $values = [];
    my $measurement_data = $self->measurement_data;

    foreach my $result (@$results) {
        my $measurement = dclone $metadata;
        my $ts = $result->{'ts'};
        my $val;        
        foreach my $config_value ( @{ $config_values->{'value'}} ) {
            my $esmond_name = $config_value->{'esmond_name'};
            my $tsds_name = $config_value->{'tsds_name'};
            if ($config_values->{'type'} eq 'base' || $config_values->{'type'} eq 'aggregation') {
                $val = $result->{'val'};
            } else {
                $val = $result->{'val'}->{$esmond_name};
            }
            if ( defined($ts) && defined($val) ) {
                $measurement->{'values'}->{$tsds_name} = $val;
                $ts = int($ts);
                $val = $self->format_value($val, $config_value->{'type'});
                $measurement->{'time'} = $ts;
                if (!exists($measurement->{'values'}) || keys (%{ $measurement->{'values'} }) == 0 ) {
                    $self->logger->info(" ---- NO VALUES FOUND ----"); 
                }
            }
        } # end config value loop
        push @$measurement_data, $measurement; 

        if (@$measurement_data >= $self->batch_size) {
            my $res = $self->send_esmond_data();
        }

    }
    return $values;
}

sub format_value {
    my $self = shift;
    my $value = shift;
    my $type = shift;

    return $value if not defined $type;
    return $value if not defined $value;

    if ($type eq 'int') {
        my $orig = $value;
        $value = int($value);
    } elsif ($type eq 'float') {
        $value += 0;
    }
    return $value;
}

    

sub get_values_url {
    my $self = shift;
    my $base_url = shift;
    my $config_value = shift;
    my $esmond_type = shift;
    my $values_url = $base_url;

    if ($config_value->{'type'} eq 'base') {
        $values_url .= $esmond_type->{'base-uri'};
    } elsif ($config_value->{'type'} eq 'aggregation' || $config_value->{'type'} eq 'statistics') {
        # trim base
        $values_url =~ s|/base||; 
        my $found = 0;
        foreach my $summary (@{ $esmond_type->{'summaries'} } ) {
            next if !defined ($summary->{'summary-type'}) || !defined($summary->{'summary-window'});
            next if $esmond_type->{'event-type'} ne $config_value->{'summary_name'};
            if ($summary->{'summary-type'} eq $config_value->{'type'} && $summary->{'summary-window'} == $config_value->{'window'}) {
                $values_url .= $summary->{'uri'};
                $found++;
                last;
            } 
        }
        if ($found == 0) {
            return;
        }
    } 
    my @val_params = ();
    my $time_range = $self->time_range;
    my $time_start = $self->time_start;
    my $time_end = $self->time_end;
    
    push @val_params, 'time-start=' . $time_start if ($time_start);
    push @val_params, 'time-end=' . $time_end if ($time_end);
    if ( @val_params > 0 ) {
        $values_url .= "?";
        $values_url .= join('&', @val_params);
    }

    #$self->logger->info("values_url: $values_url");
    return $values_url;    
}

sub _update_time_range {
    my $self = shift;

    my $config = $self->config; 

    # time_range may be passed in from cli, in which case this will be defined. 
    my $time_range = $self->time_range;
    my $time_range_cli = $self->time_range_cli;
    my $now = time();
    my $time_start;
    my $time_end;
    if ( defined $time_range_cli && $self->first_run == 1 ) {
        $time_end = $now;
        if ($time_range_cli eq 'all' ) {
            undef $time_range;
            undef $time_start;        
            undef $time_end; 
        } else { 
            $time_range = $time_range_cli;
            $time_start = $now - $time_range;
        }
    } else {
        $time_range = $config->get('/config/time_range')->[0] if defined $config->get('/config/time_range')->[0];
        $time_end = $now;
        $time_start = $now - $time_range;
    }
    $self->_set_time_start( $time_start );
    $self->_set_time_end( $time_end );
    $self->_set_time_range( $time_range );

}

1;
