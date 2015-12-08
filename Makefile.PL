#!/usr/bin/perl

#---------------------------------------------------------------------
#----- Copyright(C) 2012 The Trustees of Indiana University
#---------------------------------------------------------------------
#----- $HeadURL: svn+ssh://svn.grnoc.iu.edu/grnoc/perfsonar_data_pusher/trunk/Makefile.PL $
#----- $Id: Makefile.PL 40288 2015-11-13 22:12:58Z mj82 $
#-----
#----- This script makes the Makefile for this module.  Run it using
#----- perl Makefile.PL on the command before running make.
#---------------------------------------------------------------------

use strict;
use warnings;

use ExtUtils::MakeMaker;
use FindBin;

sub MY::postamble { <<"END"; }

rpm: dist
	rpmbuild -ta grnoc-perfsonar-collector-\$(VERSION).tar.gz

END

sub MY::test
{
    q(
TEST_VERBOSE=1

test :pure_all
	$(FULLPERL) t/TEST $(TEST_VERBOSE)
test_jenkins : pure_all
	$(FULLPERL) t/TEST $(TEST_VERBOSE) --formatter=TAP::Formatter::Console
    );
}

WriteMakefile(
	NAME                => 'grnoc-perfsonar-collector',
	AUTHOR              => 'GRNOC Software Engineering',
	VERSION_FROM             => 'lib/GRNOC/perfSONAR/Collector.pm',
	PL_FILES            => {},
	PREREQ_PM => {},
	dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
	clean               => { FILES => 'grnoc-perfsonar-collector*.gz' },
    );

