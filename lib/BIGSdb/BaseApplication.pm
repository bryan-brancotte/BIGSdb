#Written by Keith Jolley
#(c) 2010-2018, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::BaseApplication;
use strict;
use warnings;
use 5.010;
use version; our $VERSION = version->declare('v1.19.1');
use BIGSdb::BIGSException;
use BIGSdb::ClassificationScheme;
use BIGSdb::Constants qw(:login_requirements);
use BIGSdb::Dataconnector;
use BIGSdb::Datastore;
use BIGSdb::Login;
use BIGSdb::Parser;
use BIGSdb::PluginManager;
use BIGSdb::Preferences;
use BIGSdb::ContigManager;
use BIGSdb::SeqbinToEMBL;
use BIGSdb::SubmissionHandler;
use BIGSdb::CGI::as_utf8;
use DBI;
use Carp;
use Error qw(:try);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Application_Initiate');
use List::MoreUtils qw(any);
use Config::Tiny;
use constant PAGES_NEEDING_AUTHENTICATION     => qw(authorizeClient changePassword userProjects submit login logout);
use constant PAGES_NEEDING_JOB_MANAGER        => qw(plugin job jobs index login logout options);
use constant PAGES_NEEDING_SUBMISSION_HANDLER => qw(submit batchAddFasta profileAdd profileBatchAdd batchAdd
  batchIsolateUpdate isolateAdd isolateUpdate index logout);

sub new {
	my ( $class, $config_dir, $lib_dir, $dbase_config_dir, $r, $curate ) = @_;
	my $self = {};
	$self->{'system'}           = {};
	$self->{'config'}           = {};
	$self->{'instance'}         = undef;
	$self->{'xmlHandler'}       = undef;
	$self->{'page'}             = undef;
	$self->{'invalidXML'}       = 0;
	$self->{'invalidDbType'}    = 0;
	$self->{'dataConnector'}    = BIGSdb::Dataconnector->new;
	$self->{'datastore'}        = undef;
	$self->{'db'}               = undef;
	$self->{'mod_perl_request'} = $r;
	$self->{'fatal'}            = undef;
	$self->{'curate'}           = $curate;
	$self->{'config_dir'}       = $config_dir;
	$self->{'lib_dir'}          = $lib_dir;
	$self->{'dbase_config_dir'} = $dbase_config_dir;
	bless( $self, $class );
	$self->read_config_file($config_dir);
	$self->{'config'}->{'version'} = $VERSION;
	$self->{'max_upload_size_mb'} = $self->{'config'}->{'max_upload_size'};

	#Under SSL if upload size > CGI::POST_MAX then call will fail but not return useful message.
	#The following will stop a ridiculously large upload.
	$CGI::POST_MAX        = $self->{'config'}->{'max_upload_size'} * 4;
	$CGI::DISABLE_UPLOADS = 0;
	$self->{'cgi'}        = CGI->new;
	$self->_initiate( $config_dir, $dbase_config_dir );
	$self->{'dataConnector'}->initiate( $self->{'system'}, $self->{'config'} );
	$self->{'pages_needing_authentication'} = { map { $_ => 1 } PAGES_NEEDING_AUTHENTICATION };
	$self->{'pages_needing_authentication'}->{'user'} = 1 if $self->{'config'}->{'site_user_dbs'};
	my $q = $self->{'cgi'};
	$self->initiate_authdb
	  if $self->{'config'}->{'site_user_dbs'} || ( $self->{'system'}->{'authentication'} // q() ) eq 'builtin';

	if ( $self->{'instance'} && !$self->{'error'} ) {
		$self->db_connect;
		if ( $self->{'db'} ) {
			$self->setup_datastore;
			$self->_setup_prefstore;
			if ( !$self->{'system'}->{'authentication'} ) {
				$logger->logdie( q(No authentication attribute set - set to either 'apache' or 'builtin' )
					  . q(in the system tag of the XML database description.) );
			}
			$self->{'datastore'}->initiate_userdbs;
			my %job_manager_pages = map { $_ => 1 } PAGES_NEEDING_JOB_MANAGER;
			$self->initiate_jobmanager( $config_dir, $dbase_config_dir )
			  if !$self->{'curate'}
			  && $job_manager_pages{ $q->param('page') }
			  && $self->{'config'}->{'jobs_db'};
			my %submission_handler_pages = map { $_ => 1 } PAGES_NEEDING_SUBMISSION_HANDLER;
			$self->setup_submission_handler if $submission_handler_pages{ $q->param('page') };
			$self->setup_remote_contig_manager;
		}
	} elsif ( !$self->{'instance'} && $self->{'config'}->{'site_user_dbs'} ) {

		#Set db to one of these, connect and then inititate Datastore etc.
		#We can change the Datastore db later if needed.
		$self->{'system'}->{'db'}          = $self->{'config'}->{'site_user_dbs'}->[0]->{'dbase'};
		$self->{'system'}->{'description'} = $self->{'config'}->{'site_user_dbs'}->[0]->{'name'};
		$self->{'system'}->{'webroot'}     = '/';
		$self->db_connect;
		if ( $self->{'db'} ) {
			$self->setup_datastore;
		}
	}
	$self->app_specific_initiation;
	$self->print_page;
	$self->_db_disconnect;

	#Prevent apache appending its own error pages.
	if ( $self->{'handled_error'} && $ENV{'MOD_PERL'} ) {
		$self->{'mod_perl_request'}->rflush;
		$self->{'mod_perl_request'}->status(200);
	}
	return $self;
}

sub _initiate {
	my ( $self, $config_dir, $dbase_config_dir ) = @_;
	my $q = $self->{'cgi'};
	Log::Log4perl::MDC->put( 'ip', $q->remote_host );
	$self->read_host_mapping_file($config_dir);
	my $content_length = $ENV{'CONTENT_LENGTH'} // 0;
	if ( $content_length > $self->{'max_upload_size_mb'} ) {
		$self->{'error'} = 'tooBig';
		my $size = BIGSdb::Utils::get_nice_size($content_length);
		$logger->fatal("Attempted upload too big - $size.");
		return;
	}
	my $db = $q->param('db');
	$q->param( page => 'index' ) if !defined $q->param('page');

	#Prevent cross-site scripting vulnerability
	( my $cleaned_page = $q->param('page') ) =~ s/[^A-z].*$//x;
	$q->param( page => $cleaned_page );
	$self->{'page'} = $q->param('page');
	return if $self->_is_user_page;
	$self->{'instance'} = $db =~ /^([\w\d\-_]+)$/x ? $1 : '';
	my $full_path = "$dbase_config_dir/$self->{'instance'}/config.xml";
	if ( !-e $full_path ) {
		$logger->fatal("Database config file for '$self->{'instance'}' does not exist.");
		$self->{'error'} = 'missingXML';
		return;
	}
	$self->{'xmlHandler'} = BIGSdb::Parser->new;
	my $parser = XML::Parser::PerlSAX->new( Handler => $self->{'xmlHandler'} );
	eval { $parser->parse( Source => { SystemId => $full_path } ) };
	if ($@) {
		$logger->fatal("Invalid XML description: $@") if $self->{'instance'} ne '';
		$self->{'error'} = 'invalidXML';
		return;
	}
	$self->{'system'} = $self->{'xmlHandler'}->get_system_hash;
	$self->_check_kiosk_page;
	$self->set_system_overrides;
	if ( !defined $self->{'system'}->{'dbtype'}
		|| ( $self->{'system'}->{'dbtype'} ne 'sequences' && $self->{'system'}->{'dbtype'} ne 'isolates' ) )
	{
		$self->{'error'} = 'invalidDbType';
	}
	$self->{'script_name'} = $q->script_name || 'bigsdb.pl';
	if ( $self->{'curate'} && $self->{'system'}->{'curate_path_includes'} ) {
		if ( $self->{'script_name'} !~ /$self->{'system'}->{'curate_path_includes'}/x ) {
			$self->{'error'} = 'invalidScriptPath';
			$logger->error("Invalid curate script path - $self->{'script_name'}");
		}
	} elsif ( !$self->{'curate'} && $self->{'system'}->{'script_path_includes'} ) {
		if ( $self->{'script_name'} !~ /$self->{'system'}->{'script_path_includes'}/x ) {
			$self->{'error'} = 'invalidScriptPath';
			$logger->error("Invalid script path - $self->{'script_name'}");
		}
	}
	if ( !$self->{'system'}->{'authentication'} ) {
		$self->{'error'} = 'noAuthenticationSet';
	} elsif ( $self->{'system'}->{'authentication'} ne 'apache' && $self->{'system'}->{'authentication'} ne 'builtin' )
	{
		$self->{'error'} = 'invalidAuthenticationSet';
	}
	$self->{'system'}->{'script_name'} = $self->{'script_name'};
	$self->{'system'}->{'query_script'}  //= $self->{'config'}->{'query_script'}  // 'bigsdb.pl';
	$self->{'system'}->{'curate_script'} //= $self->{'config'}->{'curate_script'} // 'bigscurate.pl';
	$ENV{'PATH'} = '/bin:/usr/bin';    ## no critic (RequireLocalizedPunctuationVars) #so we don't foul taint check
	delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};    # Make %ENV safer
	$self->{'page'} = $q->param('page');
	$self->{'system'}->{'read_access'} //= 'public';    #everyone can view by default
	$self->set_dbconnection_params;
	$self->{'system'}->{'privacy'} //= 'yes';
	$self->{'system'}->{'privacy'} = $self->{'system'}->{'privacy'} eq 'no' ? 0 : 1;
	$self->{'system'}->{'locus_superscript_prefix'} //= 'no';
	$self->{'system'}->{'dbase_config_dir'} = $dbase_config_dir;

	if ( ( $self->{'system'}->{'dbtype'} // '' ) eq 'isolates' ) {
		$self->{'system'}->{'view'}       //= 'isolates';
		$self->{'system'}->{'labelfield'} //= 'isolate';
		if ( !$self->{'xmlHandler'}->is_field( $self->{'system'}->{'labelfield'} ) ) {
			$logger->error(
				    qq(The defined labelfield '$self->{'system'}->{'labelfield'}' does not exist in the database. )
				  . q(Please set the labelfield attribute in the system tag of the database XML file.) );
		}
	}

	#refdb attribute has been renamed ref_db for consistency with other databases (refdb still works)
	$self->{'config'}->{'ref_db'} //= $self->{'config'}->{'refdb'};

	#Allow individual database configs to override system auth and pref databases and tmp directories
	foreach (qw (prefs_db auth_db tmp_dir secure_tmp_dir ref_db)) {
		$self->{'config'}->{$_} = $self->{'system'}->{$_} if defined $self->{'system'}->{$_};
	}

	#dbase_job_quota attribute has been renamed job_quota for consistency (dbase_job_quota still works)
	$self->{'system'}->{'job_quota'} //= $self->{'system'}->{'dbase_job_quota'};
	return;
}

sub _check_kiosk_page {
	my ($self) = @_;
	return if !$self->{'system'}->{'kiosk'};
	my $q = $self->{'cgi'};
	if ( $self->{'system'}->{'kiosk_allowed_pages'} ) {
		my %allowed_pages = map { $_ => 1 } split /,/x, $self->{'system'}->{'kiosk_allowed_pages'};
		return if $allowed_pages{ $q->param('page') };
	}
	$q->param( page => $self->{'system'}->{'kiosk'} ) if $self->{'system'}->{'kiosk'};
	return;
}

sub _is_user_page {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( !$q->param('db') || $q->param('page') eq 'user' ) {
		$self->{'system'}->{'read_access'} = 'public';
		$self->{'system'}->{'dbtype'}      = 'user';
		$self->{'system'}->{'script_name'} =
		  $q->script_name || ( $self->{'curate'} ? 'bigscurate.pl' : 'bigsdb.pl' );
		my %non_user_page = map { $_ => 1 } qw(logout changePassword registration usernameRemind);
		$self->{'page'} = 'user' if !$non_user_page{ $self->{'page'} };
		$q->param( page => 'user' ) if !$non_user_page{ $q->param('page') };
		return 1;
	}
	return;
}

sub set_dbconnection_params {
	my ( $self, $options ) = @_;
	$self->{'system'}->{'host'}     //= $options->{'host'}     // $self->{'config'}->{'dbhost'}     // 'localhost';
	$self->{'system'}->{'port'}     //= $options->{'port'}     // $self->{'config'}->{'dbport'}     // 5432;
	$self->{'system'}->{'user'}     //= $options->{'user'}     // $self->{'config'}->{'dbuser'}     // 'apache';
	$self->{'system'}->{'password'} //= $options->{'password'} // $self->{'config'}->{'dbpassword'} // 'remote';

	# These values are used in OfflineJobManager
	$self->{'host'}     //= $self->{'system'}->{'host'};
	$self->{'port'}     //= $self->{'system'}->{'port'};
	$self->{'user'}     //= $self->{'system'}->{'user'};
	$self->{'password'} //= $self->{'system'}->{'password'};
	return $self;
}

sub set_system_overrides {
	my ($self) = @_;
	return if !$self->{'instance'};
	my $override_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/system.overrides";
	if ( -e $override_file ) {
		my $config = Config::Tiny->new();
		$config = Config::Tiny->read($override_file);
		foreach my $param ( keys %{ $config->{_} } ) {
			my $value = $config->{_}->{$param};
			$value =~ s/^"|"$//gx;    #Remove quotes around value
			$self->{'system'}->{$param} = $value;
		}
	}
	$self->_set_field_overrides;
	return;
}

sub _set_field_overrides {
	my ($self) = @_;
	return if !$self->{'instance'};
	my $override_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/field.overrides";
	my %allowed_att = map { $_ => 1 } qw(required maindisplay);
	if ( -e $override_file ) {
		my $config = Config::Tiny->new();
		$config = Config::Tiny->read($override_file);
		foreach my $param ( keys %{ $config->{_} } ) {
			my ( $field, $attribute ) = split /:/x, $param;
			if ( !$self->{'xmlHandler'}->is_field($field) ) {
				$logger->error("Error in field.overrides file. Invalid field $field");
				next;
			}
			if ( !$allowed_att{$attribute} ) {
				$logger->error("Error in field.overrides file. Invalud attribute $attribute");
				next;
			}
			my $value = $config->{_}->{$param};
			$value =~ s/^"|"$//gx;    #Remove quotes around value
			$self->{'xmlHandler'}->{'attributes'}->{$field}->{$attribute} = $value;
		}
	}
	return;
}

sub initiate_authdb {
	my ($self) = @_;
	my %att = (
		dbase_name => $self->{'config'}->{'auth_db'},
		host       => $self->{'system'}->{'host'},
		port       => $self->{'system'}->{'port'},
		user       => $self->{'system'}->{'user'},
		password   => $self->{'system'}->{'password'},
	);
	try {
		$self->{'auth_db'} = $self->{'dataConnector'}->get_connection( \%att );
		$logger->info("Connected to authentication database '$self->{'config'}->{'auth_db'}'");
	}
	catch BIGSdb::DatabaseConnectionException with {
		$logger->error("Cannot connect to authentication database '$self->{'config'}->{'auth_db'}'");
		$self->{'error'} = 'noAuth';
	};
	return;
}

sub initiate_jobmanager {
	my ( $self, $config_dir, $dbase_config_dir, ) = @_;
	$self->{'jobManager'} = BIGSdb::OfflineJobManager->new(
		{
			config_dir       => $config_dir,
			dbase_config_dir => $dbase_config_dir,
			host             => $self->{'system'}->{'host'},
			port             => $self->{'system'}->{'port'},
			user             => $self->{'system'}->{'user'},
			password         => $self->{'system'}->{'password'},
			system           => $self->{'system'}
		}
	);
	return;
}

sub read_config_file {
	my ( $self, $config_dir ) = @_;
	my $config = Config::Tiny->read("$config_dir/bigsdb.conf");
	if ( !defined $config ) {
		$logger->fatal('bigsdb.conf file is not accessible.');
		$config = Config::Tiny->new();
	}
	foreach my $param ( keys %{ $config->{_} } ) {
		$self->{'config'}->{$param} = $config->{_}->{$param};
	}

	#Check integer values
	foreach my $param (
		qw(max_load blast_threads bcrypt_cost mafft_threads results_deleted_days cache_days submissions_deleted_days))
	{
		if ( defined $self->{'config'}->{$param} && !BIGSdb::Utils::is_int( $self->{'config'}->{$param} ) ) {
			$logger->error("Parameter $param in bigsdb.conf should be an integer - default value used.");
			undef $self->{'config'}->{$param};
		}
	}

	#Check float values
	foreach my $param (qw(max_upload_size max_muscle_mb)) {
		if ( defined $self->{'config'}->{$param} && !BIGSdb::Utils::is_float( $self->{'config'}->{$param} ) ) {
			$logger->error("Parameter $param in bigsdb.conf should be a number - default value used.");
			undef $self->{'config'}->{$param};
		}
	}
	foreach my $param (qw(intranet disable_updates)) {
		$self->{'config'}->{$param} //= 0;
		$self->{'config'}->{$param} = 0 if $self->{'config'}->{$param} eq 'no';
	}
	$self->{'config'}->{'cache_days'} //= 7;
	if ( $self->{'config'}->{'chartdirector'} ) {
		eval 'use perlchartdir';    ## no critic (ProhibitStringyEval)
		if ($@) {
			$logger->error(q(Chartdirector not installed! - Either install or set 'chartdirector=0' in bigsdb.conf));
			$self->{'config'}->{'chartdirector'} = 0;
		} else {
			eval 'use BIGSdb::Charts';    ## no critic (ProhibitStringyEval)
			if ($@) {
				$logger->error('Charts.pm not installed!');
			}
		}
	}
	$self->{'config'}->{'aligner'} = 1 if $self->{'config'}->{'muscle_path'} || $self->{'config'}->{'mafft_path'};
	$self->{'config'}->{'doclink'}         //= 'http://bigsdb.readthedocs.io/en/latest';
	$self->{'config'}->{'max_upload_size'} //= 32;
	$self->{'config'}->{'max_upload_size'} *= 1024 * 1024;
	if ( $self->{'config'}->{'site_user_dbs'} ) {
		my @user_dbs;
		my @user_db_values = split /\s*,\s*/x, $self->{'config'}->{'site_user_dbs'};
		foreach my $user_db (@user_db_values) {
			my ( $name, $db_name ) = split /\|/x, $user_db;
			push @user_dbs, { name => $name, dbase => $db_name };
		}
		$self->{'config'}->{'site_user_dbs'} = \@user_dbs;
	}
	$self->_read_db_config_file($config_dir);
	return;
}

sub _read_db_config_file {
	my ( $self, $config_dir ) = @_;
	my $db_file = "$config_dir/db.conf";
	if ( !-e $db_file ) {
		$logger->info("Couldn't find db.conf in $config_dir");
		return;
	}
	my $config = Config::Tiny->new();
	$config = Config::Tiny->read("$db_file");
	foreach my $param (qw (dbhost dbport dbuser dbpassword)) {
		$self->{'config'}->{$param} = $config->{_}->{$param};
	}
	if ( defined $self->{'config'}->{'dbport'} && !BIGSdb::Utils::is_int( $self->{'config'}->{'dbport'} ) ) {
		$logger->error('Parameter dbport in db.conf should be an integer - default value used.');
		undef $self->{'config'}->{'dbport'};
	}
	$self->set_dbconnection_params();
	return;
}

sub read_host_mapping_file {
	my ( $self, $config_dir ) = @_;
	my $mapping_file = "$config_dir/host_mapping.conf";
	if ( -e $mapping_file ) {
		open( my $fh, '<', $mapping_file )
		  || $logger->error("Can't open $mapping_file for reading");
		while ( my $line = <$fh> ) {
			next if $line =~ /^\s+$/x || $line =~ /^\#/x;
			my ( $host, $mapped ) = split /\s+/x, $line;
			next if !$host || !$mapped;
			$self->{'config'}->{'host_map'}->{$host} = $mapped;
		}
		close $fh;
	}
	return;
}

sub _setup_prefstore {
	my ($self) = @_;
	my %att = (
		dbase_name => $self->{'config'}->{'prefs_db'},
		host       => $self->{'system'}->{'host'},
		port       => $self->{'system'}->{'port'},
		user       => $self->{'system'}->{'user'},
		password   => $self->{'system'}->{'password'},
	);
	my $pref_db;
	try {
		$pref_db = $self->{'dataConnector'}->get_connection( \%att );
	}
	catch BIGSdb::DatabaseConnectionException with {
		$logger->fatal("Cannot connect to preferences database '$self->{'config'}->{'prefs_db'}'");
	};
	$self->{'prefstore'} = BIGSdb::Preferences->new( db => $pref_db );
	return;
}

sub setup_datastore {
	my ($self) = @_;
	$self->{'datastore'} = BIGSdb::Datastore->new(
		db            => $self->{'db'},
		dataConnector => $self->{'dataConnector'},
		system        => $self->{'system'},
		config        => $self->{'config'},
		xmlHandler    => $self->{'xmlHandler'},
		curate        => $self->{'curate'}
	);
	return;
}

sub setup_submission_handler {
	my ($self) = @_;
	$self->{'submissionHandler'} = BIGSdb::SubmissionHandler->new(
		dbase_config_dir => $self->{'dbase_config_dir'},
		config_dir       => $self->{'config_dir'},
		lib_dir          => $self->{'lib_dir'},
		db               => $self->{'db'},
		system           => $self->{'system'},
		config           => $self->{'config'},
		datastore        => $self->{'datastore'},
		xmlHandler       => $self->{'xmlHandler'},
		instance         => $self->{'instance'}
	);
	return;
}

sub setup_remote_contig_manager {
	my ($self) = @_;
	$self->{'contigManager'} = BIGSdb::ContigManager->new(
		dbase_config_dir => $self->{'dbase_config_dir'},
		config_dir       => $self->{'config_dir'},
		lib_dir          => $self->{'lib_dir'},
		db               => $self->{'db'},
		system           => $self->{'system'},
		config           => $self->{'config'},
		datastore        => $self->{'datastore'},
		xmlHandler       => $self->{'xmlHandler'},
		instance         => $self->{'instance'}
	);
	return;
}

sub db_connect {
	my ($self) = @_;
	my $att = {
		dbase_name => $self->{'system'}->{'db'},
		host       => $self->{'system'}->{'host'},
		port       => $self->{'system'}->{'port'},
		user       => $self->{'system'}->{'user'},
		password   => $self->{'system'}->{'password'}
	};
	try {
		$self->{'db'} = $self->{'dataConnector'}->get_connection($att);
	}
	catch BIGSdb::DatabaseConnectionException with {
		$logger->error("Cannot connect to database '$self->{'system'}->{'db'}'");
		$self->{'error'} = 'noConnect';
	};
	return;
}

sub _db_disconnect {
	my ($self) = @_;
	$self->{'prefstore'}->finish_statement_handles if $self->{'prefstore'};
	undef $self->{'prefstore'};
	undef $self->{'datastore'};
	return;
}

#Override in subclasses
sub print_page              { }
sub app_specific_initiation { }

sub authenticate {
	my ( $self, $page_attributes ) = @_;
	my $auth_cookies_ref;
	my $reset_password;
	my $authenticated = 1;
	my $q             = $self->{'cgi'};
	$self->{'system'}->{'authentication'} //= 'builtin';
	if ( $self->{'system'}->{'authentication'} eq 'apache' ) {
		if ( $q->remote_user ) {
			$page_attributes->{'username'} = $q->remote_user;
		} else {
			$page_attributes->{'error'} = 'userNotAuthenticated';
			my $page = BIGSdb::ErrorPage->new(%$page_attributes);
			$page->print_page_content;
			$authenticated = 0;
			$self->{'handled_error'} = 1;
		}
	} else {    #use built-in authentication
		$page_attributes->{'auth_db'} = $self->{'auth_db'};
		$page_attributes->{'vars'}    = $q->Vars;
		if ( !$self->{'instance'} && $self->{'config'}->{'site_user_dbs'} ) {
			$page_attributes->{'show_domains'} = 1;
			$page_attributes->{'system'}->{'db'} = $q->param('db') if $q->param('db');
		}
		my $page = BIGSdb::Login->new(%$page_attributes);
		my $logging_out;
		if ( $self->{'page'} eq 'logout' ) {
			$auth_cookies_ref = $page->logout;
			$page->set_cookie_attributes($auth_cookies_ref);
			$self->{'page'} = 'index';
			$logging_out = 1;
		}
		my $login_requirement = $self->{'datastore'}->get_login_requirement;
		if (   $login_requirement != NOT_ALLOWED
			|| $self->{'pages_needing_authentication'}->{ $self->{'page'} } )
		{
			try {
				throw BIGSdb::AuthenticationException('logging out') if $logging_out;
				$page_attributes->{'username'} = $page->login_from_cookie;
				$self->{'page'} = 'changePassword' if $self->{'system'}->{'password_update_required'};
			}
			catch BIGSdb::AuthenticationException with {
				$logger->debug('No cookie set - asking for log in');
				if (   $login_requirement == REQUIRED
					|| $self->{'pages_needing_authentication'}->{ $self->{'page'} } )
				{
					if ( $q->param('no_header') ) {
						$page_attributes->{'error'} = 'ajaxLoggedOut';
						$page = BIGSdb::ErrorPage->new(%$page_attributes);
						$page->print_page_content;
						$authenticated = 0;
					} else {
						my $args = {};
						$args->{'dbase_name'} = $q->param('db') if $q->param('page') eq 'user';
						try {
							( $page_attributes->{'username'}, $auth_cookies_ref, $reset_password ) =
							  $page->secure_login($args);
						}
						catch BIGSdb::AuthenticationException with {

							#failed again
							$authenticated = 0;
						};
					}
				}
			};
		}
		if ( $login_requirement == OPTIONAL && $self->{'page'} eq 'login' ) {
			$self->{'page'} = 'index';
		}
	}
	if ($reset_password) {
		$self->{'system'}->{'password_update_required'} = 1;
		$q->{'page'}                                    = 'changePassword';
		$self->{'page'}                                 = 'changePassword';
	}
	if ( $authenticated && $page_attributes->{'username'} ) {
		my $config_access = $self->is_user_allowed_access( $page_attributes->{'username'} );
		$page_attributes->{'permissions'} = $self->{'datastore'}->get_permissions( $page_attributes->{'username'} );
		if ( $page_attributes->{'permissions'}->{'disable_access'} ) {
			$page_attributes->{'error'} = 'accessDisabled';
			my $page = BIGSdb::ErrorPage->new(%$page_attributes);
			$page->print_page_content;
			$authenticated = 0;
			$self->{'handled_error'} = 1;
		} elsif ( !$config_access ) {
			$page_attributes->{'error'} = 'configAccessDenied';
			my $page = BIGSdb::ErrorPage->new(%$page_attributes);
			$page->print_page_content;
			$authenticated = 0;
			$self->{'handled_error'} = 1;
		}
	}
	return ( $authenticated, $auth_cookies_ref );
}

sub is_user_allowed_access {
	my ( $self, $username ) = @_;
	my %valid_user_type = map { $_ => 1 } qw(user submitter curator admin);
	if ( ( $self->{'system'}->{'curators_only'} // q() ) eq 'yes' ) {
		my $status = $self->{'datastore'}->run_query( 'SELECT status FROM users WHERE user_name=?', $username );
		return if !$status || $status eq 'user' || !$valid_user_type{$status};
		return if $status eq 'submitter' && !$self->{'curate'};
	}
	return 1 if !$self->{'system'}->{'default_access'};
	if ( $self->{'system'}->{'default_access'} eq 'deny' ) {
		my $users_allow_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/users.allow";
		return 1 if -e $users_allow_file && $self->_is_name_in_file( $username, $users_allow_file );
		my $group_allow_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/usergroups.allow";
		return 1 if -e $group_allow_file && $self->_is_user_in_group_file( $username, $group_allow_file );
		return;
	} elsif ( $self->{'system'}->{'default_access'} eq 'allow' ) {
		my $deny_file = "$self->{'dbase_config_dir'}/$self->{'instance'}/users.deny";
		return if -e $deny_file && $self->_is_name_in_file( $username, $deny_file );
		return 1;
	}
	return;
}

sub _is_name_in_file {
	my ( $self, $name, $filename ) = @_;
	throw BIGSdb::FileException("File $filename does not exist") if !-e $filename;
	open( my $fh, '<', $filename ) || $logger->error("Can't open $filename for reading");
	while ( my $line = <$fh> ) {
		next if $line =~ /^\#/x;
		$line =~ s/^\s+//x;
		$line =~ s/\s+$//x;
		if ( $line eq $name ) {
			close $fh;
			return 1;
		}
	}
	close $fh;
	return;
}

sub _is_user_in_group_file {
	my ( $self, $name, $filename ) = @_;
	throw BIGSdb::FileException("File $filename does not exist") if !-e $filename;
	my $group_names = [];
	open( my $fh, '<', $filename ) || $logger->error("Can't open $filename for reading");
	while ( my $line = <$fh> ) {
		next if $line =~ /^\#/x;
		$line =~ s/^\s+//x;
		$line =~ s/\s+$//x;
		push @$group_names, $line;
	}
	close $fh;
	my $list_table = $self->{'datastore'}->create_temp_list_table_from_array( 'text', $group_names );
	my $user_info = $self->{'datastore'}->get_user_info_from_username($name);
	return if !$user_info;
	return $self->{'datastore'}->run_query(
		'SELECT EXISTS(SELECT * FROM user_groups g JOIN user_group_members m ON g.id=m.user_group WHERE '
		  . "g.description IN (SELECT value FROM $list_table) AND m.user_id=?)",
		$user_info->{'id'}
	);
}

sub initiate_plugins {
	my ($self) = @_;
	$self->{'pluginManager'} = BIGSdb::PluginManager->new(
		system           => $self->{'system'},
		dbase_config_dir => $self->{'dbase_config_dir'},
		config_dir       => $self->{'config_dir'},
		lib_dir          => $self->{'lib_dir'},
		cgi              => $self->{'cgi'},
		instance         => $self->{'instance'},
		prefstore        => $self->{'prefstore'},
		config           => $self->{'config'},
		datastore        => $self->{'datastore'},
		db               => $self->{'db'},
		xmlHandler       => $self->{'xmlHandler'},
		dataConnector    => $self->{'dataConnector'},
		mod_perl_request => $self->{'mod_perl_request'},
		jobManager       => $self->{'jobManager'},
		contigManager    => $self->{'contigManager'},
		pluginDir        => $self->{'lib_dir'}
	);
	return;
}

sub get_load_average {
	if ( -e '/proc/loadavg' ) {    #Faster to read from /proc/loadavg if available.
		my $loadavg;
		open( my $fh, '<', '/proc/loadavg' ) or croak 'Cannot open /proc/loadavg';
		while (<$fh>) {
			($loadavg) = split /\s/x, $_;
		}
		close $fh;
		return $loadavg;
	}
	my $uptime = `uptime`;         #/proc/loadavg not available on BSD.
	if ( $uptime =~ /load\ average:\s+([\d\.]+)/x ) {
		return $1;
	}
	throw BIGSdb::DataException('Cannot determine load average');
}
1;
