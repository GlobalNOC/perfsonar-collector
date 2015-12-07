#!/usr/bin/perl

use strict;
use warnings;

use GRNOC::perfSONAR::Collector;
use Getopt::Long;
use Data::Dumper;

### constants ### 
use constant DEFAULT_CONFIG_FILE => "/etc/grnoc/perfsonar-collector/config.xml";

# command line options
my $config_file = DEFAULT_CONFIG_FILE;
my $nofork;
my $help;
my $time_range;
my $runonce;

GetOptions( "config|c=s" => \$config_file,
            "nofork" => \$nofork,
            "help|h|?" => \$help,
            "timerange=s" => \$time_range,
            "runonce" => \$runonce ) or usage();

# did they ask for help?
usage() if ( $help );

my $daemonize = !$nofork;

my $collector = GRNOC::perfSONAR::Collector->new( config_file => $config_file,
						  daemonize => $daemonize,
						  time_range_cli => $time_range,
						  run_once => $runonce,
    );

$collector->start();

sub usage {
    print "$0 [--config <config file>] [--nofork] [--timerange <seconds>] [--runonce] [--help]\n";
    print "\t--nofork - Do not daemonize\n";
    print "\t--runonce - Only run once - collect data, post to esmond, then stop\n";
    print "\t--timerange <seconds> - retrieve data going back the specified value in seconds or 'all' to collect all historical data for all time (overrides the config file setting)\n";
    exit( 1 );
}

