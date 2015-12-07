Summary: GRNOC perfSONAR Collector Tool
Name: grnoc-perfsonar-collector
Version: 1.0.0
Release: 1%{?dist}
License: GRNOC
Group: TSDS
URL: http://globalnoc.iu.edu
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
BuildArch: noarch
Requires: perl >= 5.8.8
Requires: perl-libwww-perl
Requires: perl-GRNOC-Log
Requires: perl-GRNOC-Config
Requires: perl-GRNOC-WebService-Client
Requires: perl-Moo
Requires: perl-strictures
Requires: perl-JSON
Requires: perl-Proc-Daemon
Requires: perl-Math-Round
Requires: perl-Try-Tiny

%description
GRNOC perfSONAR Collector to TSDS

%prep
%setup -q -n grnoc-perfsonar-collector-%{version}

%build
%{__perl} Makefile.PL PREFIX="%{buildroot}%{_prefix}" INSTALLDIRS="vendor"
make

%install
rm -rf $RPM_BUILD_ROOT
make pure_install

%{__install} -d -p %{buildroot}/etc/grnoc/perfsonar-collector/
%{__install} -d -p %{buildroot}/usr/bin/
%{__install} -d -p %{buildroot}/etc/init.d/

%{__install} conf/config.xml.example %{buildroot}/etc/grnoc/perfsonar-collector/config.xml
%{__install} conf/logging.conf.example %{buildroot}/etc/grnoc/perfsonar-collector/logging.conf

%{__install} bin/perfsonar_collector.pl %{buildroot}/usr/bin/perfsonar_collector.pl
%{__install} init.d/perfsonar_collector %{buildroot}/etc/init.d/perfsonar_collector

# clean up buildroot
find %{buildroot} -name .packlist -exec %{__rm} {} \;

%{_fixperms} $RPM_BUILD_ROOT/*

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(644,root,root,-)
%config(noreplace) /etc/grnoc/perfsonar-collector/config.xml
%config(noreplace) /etc/grnoc/perfsonar-collector/logging.conf

%{perl_vendorlib}/GRNOC/perfSONAR/Collector.pm

%attr(754, root, root) /usr/bin/perfsonar_collector.pl
%attr(754, root, root) /etc/init.d/perfsonar_collector
