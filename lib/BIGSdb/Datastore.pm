#Written by Keith Jolley
#Copyright (c) 2010-2014, University of Oxford
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
package BIGSdb::Datastore;
use strict;
use warnings;
use 5.010;
use List::MoreUtils qw(any uniq);
use Error qw(:try);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Datastore');
use BIGSdb::ClientDB;
use BIGSdb::Locus;
use BIGSdb::Scheme;
use BIGSdb::TableAttributes;
use Memoize;
memoize('get_locus_info');

sub new {
	my ( $class, @atr ) = @_;
	my $self = {@atr};
	$self->{'sql'}    = {};
	$self->{'scheme'} = {};
	$self->{'locus'}  = {};
	$self->{'prefs'}  = {};
	bless( $self, $class );
	$logger->info("Datastore set up.");
	return $self;
}

sub update_prefs {
	my ( $self, $prefs ) = @_;
	$self->{'prefs'} = $prefs;
	return;
}

sub DESTROY {
	my ($self) = @_;
	foreach ( keys %{ $self->{'sql'} } ) {
		$self->{'sql'}->{$_}->finish if $self->{'sql'}->{$_};
		$logger->info("Statement handle '$_' destroyed.");
	}
	foreach ( keys %{ $self->{'scheme'} } ) {
		undef $self->{'scheme'}->{$_};
		$logger->info("Scheme $_ destroyed.");
	}
	foreach ( keys %{ $self->{'locus'} } ) {
		undef $self->{'locus'}->{$_};
		$logger->info("locus $_ destroyed.");
	}
	$logger->info("Datastore destroyed.");
	return;
}

sub get_data_connector {
	my ($self) = @_;
	throw BIGSdb::DatabaseConnectionException("Data connector not set up.") if !$self->{'dataConnector'};
	return $self->{'dataConnector'};
}

sub get_user_info {
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'user_info'} ) {
		$self->{'sql'}->{'user_info'} = $self->{'db'}->prepare("SELECT first_name,surname,affiliation,email FROM users WHERE id=?");
		$logger->info("Statement handle 'user_info' prepared.");
	}
	eval { $self->{'sql'}->{'user_info'}->execute($id) };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'user_info'}->fetchrow_hashref;
}

sub get_user_info_from_username {
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'user_info_from_username'} ) {
		$self->{'sql'}->{'user_info_from_username'} =
		  $self->{'db'}->prepare("SELECT first_name,surname,affiliation,email FROM users WHERE user_name=?");
		$logger->info("Statement handle 'user_info_from_username' prepared.");
	}
	eval { $self->{'sql'}->{'user_info_from_username'}->execute($id) };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'user_info_from_username'}->fetchrow_hashref;
}

sub get_permissions {

	#don't bother caching query handle as this should only be called once
	my ( $self, $username ) = @_;
	my $sql =
	  $self->{'db'}
	  ->prepare("SELECT user_permissions.* FROM user_permissions LEFT JOIN users ON user_permissions.user_id = users.id WHERE user_name=?");
	eval { $sql->execute($username) };
	$logger->error($@) if $@;
	return $sql->fetchrow_hashref;
}

sub get_isolate_field_values {
	my ( $self, $isolate_id ) = @_;
	if ( !$self->{'sql'}->{'isolate_field_values'} ) {
		$self->{'sql'}->{'isolate_field_values'} = $self->{'db'}->prepare("SELECT * FROM $self->{'system'}->{'view'} WHERE id=?");
	}
	eval { $self->{'sql'}->{'isolate_field_values'}->execute($isolate_id) };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'isolate_field_values'}->fetchrow_hashref;
}

sub get_composite_value {
	my ( $self, $isolate_id, $composite_field, $isolate_fields_hashref ) = @_;
	my $value = '';
	if ( !$self->{'sql'}->{'composite_field_values'} ) {
		$self->{'sql'}->{'composite_field_values'} =
		  $self->{'db'}
		  ->prepare("SELECT field,empty_value,regex FROM composite_field_values WHERE composite_field_id=? ORDER BY field_order");
		$logger->info("Statement handle 'composite_field_values' prepared.");
	}
	eval { $self->{'sql'}->{'composite_field_values'}->execute($composite_field) };
	$logger->error($@) if $@;
	while ( my ( $field, $empty_value, $regex ) = $self->{'sql'}->{'composite_field_values'}->fetchrow_array ) {
		$empty_value //= '';
		if (
			defined $regex
			&& (
				$regex =~ /[^\w\d\-\.\\\/\(\)\+\* \$]/    #reject regex containing any character not in list
				|| $regex =~ /\$\D/                       #allow only $1, $2 etc. variables
			)
		  )
		{
			$logger->warn( "Regex for field '$field' in composite field '$composite_field' contains non-valid characters.  "
				  . "This is potentially dangerous as it may allow somebody to include a command that could be executed by the "
				  . "web server daemon.  The regex was '$regex'.  This regex has been disabled." );
			undef $regex;
		}
		if ( $field =~ /^f_(.+)/ ) {
			my $isolate_field = $1;
			my $text_value    = $isolate_fields_hashref->{ lc($isolate_field) };
			if ($regex) {
				my $expression = "\$text_value =~ $regex";
				eval "$expression";    ## no critic (ProhibitStringyEval)
			}
			$value .= $text_value || $empty_value;
		} elsif ( $field =~ /^l_(.+)/ ) {
			my $locus = $1;
			my $designations = $self->get_allele_designations( $isolate_id, $locus );
			my @allele_values;
			foreach my $designation (@$designations) {
				my $allele_id = $designation->{'allele_id'};
				$allele_id = '&Delta;' if $allele_id =~ /^del/i;
				if ($regex) {
					my $expression = "\$allele_id =~ $regex";
					eval "$expression";    ## no critic (ProhibitStringyEval)
				}
				$allele_id = qq(<span class="provisional">$allele_id</span>) if $designation->{'status'} eq 'provisional';
				push @allele_values, $allele_id;
			}
			local $" = ',';
			$value .= "@allele_values" || $empty_value;
		} elsif ( $field =~ /^s_(\d+)_(.+)/ ) {
			my $scheme_id    = $1;
			my $scheme_field = $2;
			my $scheme_fields->{$scheme_id} = $self->get_scheme_field_values_by_isolate_id( $isolate_id, $scheme_id );
			my @field_values;
			$scheme_field = lc($scheme_field);    # hashref keys returned as lower case from db.
			if ( defined $scheme_fields->{$scheme_id}->{$scheme_field} ) {
				foreach my $value ( keys %{ $scheme_fields->{$scheme_id}->{$scheme_field} } ) {
					my $provisional = $scheme_fields->{$scheme_id}->{$scheme_field}->{$value} eq 'provisional' ? 1 : 0;
					if ($regex) {
						my $expression = "\$value =~ $regex";
						eval "$expression";       ## no critic (ProhibitStringyEval)
					}
					$value = qq(<span class="provisional">$value</span>)
					  if $provisional;
					push @field_values, $value;
				}
			}
			local $" = ',';
			my $field_value = "@field_values";
			$value .=
			  ( $scheme_fields->{$scheme_id}->{$scheme_field} // '' ) ne ''
			  ? $field_value
			  : $empty_value;
		} elsif ( $field =~ /^t_(.+)/ ) {
			my $text = $1;
			$value .= $text;
		}
	}
	return $value;
}

sub get_ambiguous_loci {
	my ( $self, $scheme_id, $profile_id ) = @_;
	my $profile = $self->get_profile_by_primary_key( $scheme_id, $profile_id, { hashref => 1 } );
	my %ambiguous;
	foreach my $locus ( keys %$profile ) {
		$ambiguous{$locus} = 1 if $profile->{$locus} eq 'N';
	}
	return \%ambiguous;
}

sub get_profile_by_primary_key {
	my ( $self, $scheme_id, $profile_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $loci_values;
	try {
		$loci_values = $self->get_scheme($scheme_id)->get_profile_by_primary_keys( [$profile_id] );
	}
	catch BIGSdb::DatabaseConfigurationException with {
		$logger->error("Error retrieving information from remote database - check configuration.");
	};
	return if !defined $loci_values;
	if ( $options->{'hashref'} ) {
		my $loci = $self->get_scheme_loci($scheme_id);
		my %values;
		my $i = 0;
		foreach my $locus (@$loci) {
			$values{$locus} = $loci_values->[$i];
			$i++;
		}
		return \%values;
	} else {
		return $loci_values;
	}
	return;
}

sub get_scheme_field_values_by_designations {
	my ( $self, $scheme_id, $designations ) = @_;    #$designations is a hashref containing arrayref of allele_designations for each locus
	my $values     = {};
	my $loci       = $self->get_scheme_loci($scheme_id);
	my $fields     = $self->get_scheme_fields($scheme_id);
	my $field_data = [];
	if ( ( $self->{'system'}->{'use_temp_scheme_table'} // '' ) eq 'yes' ) {
		#TODO This almost identical to code in Scheme.pm - look at refactoring

		#Import all profiles from seqdef database into indexed scheme table.  Under some circumstances
		#this can be considerably quicker than querying the seqdef scheme view (a few ms compared to
		#>10s if the seqdef database contains multiple schemes with an uneven distribution of a large
		#number of profiles so that the Postgres query planner picks a sequential rather than index scan).
		#
		#This scheme table can also be generated periodically using the update_scheme_cache.pl
		#script to create a persistent cache.  This is particularly useful for large schemes (>10000
		#profiles) but data will only be as fresh as the cache so ensure that the update script
		#is run periodically.
		if ( !$self->{'cache'}->{'scheme_cache'}->{$scheme_id} ) {
			try {
				$self->create_temp_scheme_table($scheme_id);
				$self->{'cache'}->{'scheme_cache'}->{$scheme_id} = 1;
			}
			catch BIGSdb::DatabaseConnectionException with {
				$logger->error("Can't create temporary table");
			};
		}
		my ( @allele_count, @allele_ids );
		foreach my $locus (@$loci) {
			if (!defined $designations->{$locus}){
				#Define a null designation if one doesn't exist for the purposes of looking up profile.
				#We can't just abort the query because some schemes allow missing loci, but we don't want to match based
				#on an incomplete set of designations.
				push @allele_ids, '-999';
				push @allele_count,1;
			} else {
				push @allele_count, scalar @{ $designations->{$locus} }; #We need a different query depending on number of designations at loci.
				push @allele_ids, $_->{'allele_id'} foreach @{ $designations->{$locus} };
			}		
		}
		local $" = ',';
		my $query_key = "@allele_count";
		if ( !$self->{'sql'}->{"field_values_$scheme_id\_$query_key"} ) {
			my $scheme_info = $self->get_scheme_info($scheme_id);
			my @locus_terms;
			my $i = 0;
			foreach my $locus (@$loci) {
				$locus =~ s/'/_PRIME_/g;
				my @temp_terms;
				push @temp_terms, ("$locus=?") x $allele_count[$i];
				push @temp_terms, "$locus='N'" if $scheme_info->{'allow_missing_loci'};
				local $" = ' OR ';
				push @locus_terms, "(@temp_terms)";
				$i++;
			}
			local $" = ' AND ';
			my $locus_term_string = "@locus_terms";
			local $" = ',';
			$self->{'sql'}->{"field_values_$scheme_id\_$query_key"} =
			  $self->{'db'}->prepare("SELECT @$loci,@$fields FROM temp_scheme_$scheme_id WHERE $locus_term_string");
		}
		eval { $self->{'sql'}->{"field_values_$scheme_id\_$query_key"}->execute(@allele_ids) };
		$logger->error($@) if $@;
		$field_data = $self->{'sql'}->{"field_values_$scheme_id\_$query_key"}->fetchall_arrayref({});
	} else {
		my $scheme = $self->get_scheme($scheme_id);
		local $" = ',';
		{
			try {
				$field_data = $scheme->get_field_values_by_designations($designations);
			}
			catch BIGSdb::DatabaseConfigurationException with {
				$logger->warn("Scheme database $scheme_id is not configured correctly");
			};
		}
	}
	foreach my $data (@$field_data) {
		my $status = 'confirmed';
	  LOCUS: foreach my $locus (@$loci) {
			next if !defined $data->{lc $locus} || $data->{ lc $locus } eq 'N';
			my $locus_status;
		  DESIGNATION: foreach my $designation ( @{ $designations->{$locus} } ) {
				next DESIGNATION if $designation->{'allele_id'} ne $data->{ lc $locus };
				if ( $designation->{'status'} eq 'confirmed' ) {
					$locus_status = 'confirmed';
					next LOCUS;
				}
			}
			$status = 'provisional';    #Locus is provisional
			last LOCUS;
		}
		foreach my $field (@$fields) {
			$data->{ lc $field } //= '';

			#Allow status to change from privisional -> confirmed but not vice versa
			$values->{ lc $field }->{ $data->{ lc $field } } = $status
			  if ( $values->{ lc $field }->{ $data->{ lc $field } } // '' ) ne 'confirmed';
		}
	}
	return $values;
}

sub get_scheme_field_values_by_profile {
	my ( $self, $scheme_id, $profile_ref ) = @_;
	$logger->logcarp("Datastore::get_scheme_field_values_by_profile is deprecated");    #TODO Remove
	my $values;
	if ( !$self->{'cache'}->{'scheme_fields'}->{$scheme_id} ) {
		$self->{'cache'}->{'scheme_fields'}->{$scheme_id} = $self->get_scheme_fields($scheme_id);
	}
	return if ref $self->{'cache'}->{'scheme_fields'}->{$scheme_id} ne 'ARRAY' || !@{ $self->{'cache'}->{'scheme_fields'}->{$scheme_id} };
	if ( !$self->{'cache'}->{'scheme_loci'}->{$scheme_id} ) {
		$self->{'cache'}->{'scheme_loci'}->{$scheme_id} = $self->get_scheme_loci($scheme_id);
	}
	return if ref $self->{'cache'}->{'scheme_loci'}->{$scheme_id} ne 'ARRAY' || !@{ $self->{'cache'}->{'scheme_loci'}->{$scheme_id} };
	if ( !$self->{'cache'}->{'scheme_info'}->{$scheme_id} ) {
		$self->{'cache'}->{'scheme_info'}->{$scheme_id} = $self->get_scheme_info($scheme_id);
	}
	return
	  if ref $profile_ref ne 'ARRAY'
	  || ( any { !defined $_ } @$profile_ref && !$self->{'cache'}->{'scheme_info'}->{$scheme_id}->{'allow_missing_loci'} );
	if ( $self->{'cache'}->{'scheme_info'}->{$scheme_id}->{'allow_missing_loci'} ) {
		foreach (@$profile_ref) {
			$_ = 'N' if !defined $_;
		}
	}
	if ( ( $self->{'system'}->{'use_temp_scheme_table'} // '' ) eq 'yes' ) {

		#Import all profiles from seqdef database into indexed scheme table.  Under some circumstances
		#this can be considerably quicker than querying the seqdef scheme view (a few ms compared to
		#>10s if the seqdef database contains multiple schemes with an uneven distribution of a large
		#number of profiles so that the Postgres query planner picks a sequential rather than index scan).
		#
		#This scheme table can also be generated periodically using the update_scheme_cache.pl
		#script to create a persistent cache.  This is particularly useful for large schemes (>10000
		#profiles) but data will only be as fresh as the cache so ensure that the update script
		#is run periodically.
		if ( !$self->{'cache'}->{'scheme_cache'}->{$scheme_id} ) {
			try {
				$self->create_temp_scheme_table($scheme_id);
				$self->{'cache'}->{'scheme_cache'}->{$scheme_id} = 1;
			}
			catch BIGSdb::DatabaseConnectionException with {
				$logger->error("Can't create temporary table");
			};
		}
		if ( !$self->{'sql'}->{"field_values_$scheme_id"} ) {
			my @placeholders;
			push @placeholders, '?' foreach @{ $self->{'cache'}->{'scheme_loci'}->{$scheme_id} };
			my $fields = $self->{'cache'}->{'scheme_fields'}->{$scheme_id};
			my $loci   = $self->{'cache'}->{'scheme_loci'}->{$scheme_id};
			my @locus_terms;
			foreach my $locus (@$loci) {
				$locus =~ s/'/_PRIME_/g;
				my $temp = "$locus=?";
				$temp .= " OR $locus='N'" if $self->{'cache'}->{'scheme_info'}->{$scheme_id}->{'allow_missing_loci'};
				push @locus_terms, "($temp)";
			}
			local $" = ' AND ';
			my $locus_term_string = "@locus_terms";
			local $" = ',';
			$self->{'sql'}->{"field_values_$scheme_id"} =
			  $self->{'db'}->prepare("SELECT @$fields FROM temp_scheme_$scheme_id WHERE $locus_term_string");
		}
		eval {
			$self->{'sql'}->{"field_values_$scheme_id"}->execute(@$profile_ref);
			$values = $self->{'sql'}->{"field_values_$scheme_id"}->fetchrow_hashref;
		};
		$logger->error($@) if $@;
	} else {
		if ( !$self->{'scheme'}->{$scheme_id} ) {
			$self->{'scheme'}->{$scheme_id} = $self->get_scheme($scheme_id);
		}
		local $" = ',';
		{
			no warnings 'uninitialized';    #Values in @$profile_ref may be null - this is ok.
			if ( !defined $self->{'cache'}->{$scheme_id}->{'field_values_by_profile'}->{"@$profile_ref"} ) {
				try {
					$values = $self->{'scheme'}->{$scheme_id}->get_field_values_by_profile( $profile_ref, { return_hashref => 1 } );
					$self->{'cache'}->{$scheme_id}->{'field_values_by_profile'}->{"@$profile_ref"} = $values;
				}
				catch BIGSdb::DatabaseConfigurationException with {
					$logger->warn("Scheme database $scheme_id is not configured correctly");
				};
			} else {
				$values = $self->{'cache'}->{$scheme_id}->{'field_values_by_profile'}->{"@$profile_ref"};
			}
		}
	}
	return $values;
}

sub get_scheme_field_values_by_isolate_id {
	my ( $self, $isolate_id, $scheme_id ) = @_;
	my $designations = $self->get_scheme_allele_designations( $isolate_id, $scheme_id );
	return $self->get_scheme_field_values_by_designations( $scheme_id, $designations );
}

sub get_samples {

	#return all sample fields except isolate_id
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'get_samples'} ) {
		my $fields = $self->{'xmlHandler'}->get_sample_field_list;
		if ( !@$fields ) {
			return \@;;
		}
		local $" = ',';
		$self->{'sql'}->{'get_samples'} = $self->{'db'}->prepare("SELECT @$fields FROM samples WHERE isolate_id=? ORDER BY sample_id");
		$logger->info("Statement handle 'get_samples' prepared.");
	}
	eval { $self->{'sql'}->{'get_samples'}->execute($id) };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'get_samples'}->fetchall_arrayref( {} );
}

sub profile_exists {

	#used for profile/sequence definitions databases
	my ( $self, $scheme_id, $profile_id ) = @_;
	return if !BIGSdb::Utils::is_int($scheme_id);
	if ( !$self->{'sql'}->{'profile_exists'} ) {
		$self->{'sql'}->{'profile_exists'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM profiles WHERE scheme_id=? AND profile_id=?");
		$logger->info("Statement handle 'profile_exists' prepared.");
	}
	eval { $self->{'sql'}->{'profile_exists'}->execute( $scheme_id, $profile_id ) };
	$logger->error($@) if $@;
	my ($exists) = $self->{'sql'}->{'profile_exists'}->fetchrow_array;
	return $exists;
}
##############ISOLATE CLIENT DATABASE ACCESS FROM SEQUENCE DATABASE####################
sub get_client_db_info {
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'client_db_info'} ) {
		$self->{'sql'}->{'client_db_info'} = $self->{'db'}->prepare("SELECT * FROM client_dbases WHERE id=?");
		$logger->info("Statement handle 'client_db_info' prepared.");
	}
	eval { $self->{'sql'}->{'client_db_info'}->execute($id) };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'client_db_info'}->fetchrow_hashref;
}

sub get_client_db {
	my ( $self, $id ) = @_;
	if ( !$self->{'client_db'}->{$id} ) {
		my $attributes = $self->get_client_db_info($id);
		if ( $attributes->{'dbase_name'} ) {
			my %att = (
				dbase_name => $attributes->{'dbase_name'},
				host       => $attributes->{'dbase_host'},
				port       => $attributes->{'dbase_port'},
				user       => $attributes->{'dbase_user'},
				password   => $attributes->{'dbase_password'},
			);
			try {
				$attributes->{'db'} = $self->{'dataConnector'}->get_connection( \%att );
			}
			catch BIGSdb::DatabaseConnectionException with {
				$logger->warn("Can not connect to database '$attributes->{'dbase_name'}'");
			};
		}
		$self->{'client_db'}->{$id} = BIGSdb::ClientDB->new(%$attributes);
	}
	return $self->{'client_db'}->{$id};
}
##############SCHEMES##################################################################
sub scheme_exists {
	my ( $self, $id ) = @_;
	return 0 if !BIGSdb::Utils::is_int($id);
	if ( !$self->{'sql'}->{'scheme_exists'} ) {
		$self->{'sql'}->{'scheme_exists'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM schemes WHERE id=?");
		$logger->info("Statement handle 'scheme_exists' prepared.");
	}
	eval { $self->{'sql'}->{'scheme_exists'}->execute($id) };
	my ($exists) = $self->{'sql'}->{'scheme_exists'}->fetchrow_array;
	return $exists;
}

sub get_scheme_info {
	my ( $self, $scheme_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	if ( !$self->{'sql'}->{'scheme_info'} ) {
		$self->{'sql'}->{'scheme_info'} = $self->{'db'}->prepare("SELECT * FROM schemes WHERE id=?");
	}
	eval { $self->{'sql'}->{'scheme_info'}->execute($scheme_id) };
	$logger->error($@) if $@;
	my $scheme_info = $self->{'sql'}->{'scheme_info'}->fetchrow_hashref;
	if ( $options->{'set_id'} ) {
		if ( !$self->{'sql'}->{'set_scheme_info'} ) {
			$self->{'sql'}->{'set_scheme_info'} = $self->{'db'}->prepare("SELECT set_name FROM set_schemes WHERE set_id=? AND scheme_id=?");
		}
		eval { $self->{'sql'}->{'set_scheme_info'}->execute( $options->{'set_id'}, $scheme_id ) };
		$logger->error($@) if $@;
		my ($desc) = $self->{'sql'}->{'set_scheme_info'}->fetchrow_array;
		$scheme_info->{'description'} = $desc if defined $desc;
	}
	if ( $options->{'get_pk'} ) {
		if ( !$self->{'sql'}->{'scheme_info_get_pk'} ) {
			$self->{'sql'}->{'scheme_info_get_pk'} =
			  $self->{'db'}->prepare("SELECT field FROM scheme_fields WHERE scheme_id=? AND primary_key");
		}
		eval { $self->{'sql'}->{'scheme_info_get_pk'}->execute($scheme_id) };
		$logger->error($@) if $@;
		my ($pk) = $self->{'sql'}->{'scheme_info_get_pk'}->fetchrow_array;
		$scheme_info->{'primary_key'} = $pk if $pk;
	}
	return $scheme_info;
}

sub get_all_scheme_info {

	#NOTE: Data are returned in a cached reference that may be needed more than once.  If calling code needs to modify returned
	#values then you MUST make a local copy.
	my ($self) = @_;
	if ( !$self->{'all_scheme_info'} ) {
		my $sql = $self->{'db'}->prepare("SELECT * FROM schemes");
		eval { $sql->execute };
		$logger->error($@) if $@;
		$self->{'all_scheme_info'} = $sql->fetchall_hashref('id');
	}
	return $self->{'all_scheme_info'};
}

sub get_all_scheme_loci {
	my ($self) = @_;
	my $sql = $self->{'db'}->prepare("SELECT scheme_id,locus FROM scheme_members ORDER BY field_order,locus");
	eval { $sql->execute };
	$logger->error($@) if $@;
	my $loci;
	my $data = $sql->fetchall_arrayref;
	foreach ( @{$data} ) {
		push @{ $loci->{ $_->[0] } }, $_->[1];
	}
	return $loci;
}

sub get_scheme_loci {

	#options passed as hashref:
	#analyse_pref: only the loci for which the user has a analysis preference selected will be returned
	#profile_name: to substitute profile field value in query
	#	({profile_name => 1, analysis_pref => 1})
	my ( $self, $id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my @field_names = 'locus';
	push @field_names, 'profile_name' if $self->{'system'}->{'dbtype'} eq 'isolates';
	if ( !$self->{'sql'}->{'scheme_loci'} ) {
		local $" = ',';
		$self->{'sql'}->{'scheme_loci'} =
		  $self->{'db'}->prepare("SELECT @field_names FROM scheme_members WHERE scheme_id=? ORDER BY field_order,locus");
		$logger->info("Statement handle 'scheme_loci' prepared.");
	}
	eval { $self->{'sql'}->{'scheme_loci'}->execute($id) };
	$logger->error($@) if $@;
	my @loci;
	while ( my ( $locus, $profile_name ) = $self->{'sql'}->{'scheme_loci'}->fetchrow_array ) {
		if ( $options->{'analysis_pref'} ) {
			if (   $self->{'prefs'}->{'analysis_loci'}->{$locus}
				&& $self->{'prefs'}->{'analysis_schemes'}->{$id} )
			{
				if ( $options->{'profile_name'} ) {
					push @loci, $profile_name || $locus;
				} else {
					push @loci, $locus;
				}
			}
		} else {
			if ( $options->{'profile_name'} ) {
				push @loci, $profile_name || $locus;
			} else {
				push @loci, $locus;
			}
		}
	}
	return \@loci;
}

sub get_locus_aliases {
	my ( $self, $locus ) = @_;
	if ( !$self->{'sql'}->{'locus_aliases'} ) {
		$self->{'sql'}->{'locus_aliases'} =
		  $self->{'db'}->prepare("SELECT alias FROM locus_aliases WHERE use_alias AND locus=? ORDER BY alias");
	}
	eval { $self->{'sql'}->{'locus_aliases'}->execute($locus) };
	$logger->error($@) if $@;
	my @aliases;
	while ( my ($alias) = $self->{'sql'}->{'locus_aliases'}->fetchrow_array ) {
		push @aliases, $alias;
	}
	return \@aliases;
}

sub get_loci_in_no_scheme {

	#if 'analyse_pref' option is passed, only the loci for which the user has an analysis preference selected
	#will be returned
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $qry;
	if ( $options->{'set_id'} ) {
		$qry = "SELECT locus FROM set_loci WHERE set_id=$options->{'set_id'} AND locus NOT IN (SELECT locus FROM scheme_members "
		  . "WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE set_id=$options->{'set_id'})) ORDER BY locus";
	} else {
		$qry = "SELECT id FROM loci LEFT JOIN scheme_members ON loci.id = scheme_members.locus where scheme_id is null ORDER BY id";
	}
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute };
	$logger->error($@) if $@;
	my @loci;
	while ( my ($locus) = $sql->fetchrow_array ) {
		if ( $options->{'analyse_pref'} ) {
			if ( $self->{'prefs'}->{'analysis_loci'}->{$locus} ) {
				push @loci, $locus;
			}
		} else {
			push @loci, $locus;
		}
	}
	return \@loci;
}

sub are_sequences_displayed_in_scheme {
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'seq_display'} ) {
		$self->{'sql'}->{'seq_display'} =
		  $self->{'db'}->prepare("SELECT id FROM loci LEFT JOIN scheme_members ON scheme_members.locus = loci.id WHERE scheme_id=?");
		$logger->info("Statement handle 'seq_display' prepared.");
	}
	eval { $self->{'sql'}->{'seq_display'}->execute($id) };
	$logger->error($@) if $@;
	my $value;
	while ( my ($locus) = $self->{'sql'}->{'seq_display'}->fetchrow_array ) {
		$value++
		  if $self->{'prefs'}->{'isolate_display_loci'}->{$locus} eq 'sequence';
	}
	return $value ? 1 : 0;
}

sub get_scheme_fields {
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'scheme_fields'} ) {
		$self->{'sql'}->{'scheme_fields'} =
		  $self->{'db'}->prepare("SELECT field FROM scheme_fields WHERE scheme_id=? ORDER BY field_order");
		$logger->info("Statement handle 'scheme_fields' prepared.");
	}
	eval { $self->{'sql'}->{'scheme_fields'}->execute($id) };
	$logger->error($@) if $@;
	my @fields;
	while ( my ($field) = $self->{'sql'}->{'scheme_fields'}->fetchrow_array ) {
		push @fields, $field;
	}
	return \@fields;
}

sub get_all_scheme_fields {

	#NOTE: Data are returned in a cached reference that may be needed more than once.  If calling code needs to modify returned
	#values then you MUST make a local copy.
	my ($self) = @_;
	if ( !$self->{'all_scheme_fields'} ) {
		my $sql = $self->{'db'}->prepare("SELECT scheme_id,field FROM scheme_fields ORDER BY field_order");
		eval { $sql->execute; };
		$logger->error($@) if $@;
		my $data = $sql->fetchall_arrayref;
		foreach ( @{$data} ) {
			push @{ $self->{'all_scheme_fields'}->{ $_->[0] } }, $_->[1];
		}
	}
	return $self->{'all_scheme_fields'};
}

sub get_scheme_field_info {
	my ( $self, $id, $field ) = @_;
	if ( !$self->{'sql'}->{'scheme_field_info'} ) {
		$self->{'sql'}->{'scheme_field_info'} = $self->{'db'}->prepare("SELECT * FROM scheme_fields WHERE scheme_id=? AND field=?");
		$logger->info("Statement handle 'scheme_field_info' prepared.");
	}
	eval { $self->{'sql'}->{'scheme_field_info'}->execute( $id, $field ) };
	$logger->error($@) if $@;
	my $data = $self->{'sql'}->{'scheme_field_info'}->fetchrow_hashref;
	return $data;
}

sub get_all_scheme_field_info {

	#NOTE: Data are returned in a cached reference that may be needed more than once.  If calling code needs to modify returned
	#values then you MUST make a local copy.
	my ($self) = @_;
	if ( !$self->{'all_scheme_field_info'} ) {
		my @fields = $self->{'system'}->{'dbtype'} eq 'isolates' ? qw(main_display isolate_display query_field dropdown url) : 'dropdown';
		local $" = ',';
		my $sql = $self->{'db'}->prepare("SELECT scheme_id,field,@fields FROM scheme_fields");
		eval { $sql->execute };
		$logger->error($@) if $@;
		my $data_ref = $sql->fetchall_arrayref;
		foreach ( @{$data_ref} ) {
			for my $i ( 0 .. ( scalar @fields - 1 ) ) {
				$self->{'all_scheme_field_info'}->{ $_->[0] }->{ $_->[1] }->{ $fields[$i] } = $_->[ $i + 2 ];
			}
		}
	}
	return $self->{'all_scheme_field_info'};
}

sub get_scheme_list {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $qry;
	if ( $options->{'set_id'} ) {
		if ( $options->{'with_pk'} ) {
			$qry =
			    "SELECT DISTINCT schemes.id,set_schemes.set_name,schemes.description,schemes.display_order FROM set_schemes "
			  . "LEFT JOIN schemes ON set_schemes.scheme_id=schemes.id RIGHT JOIN scheme_members ON schemes.id="
			  . "scheme_members.scheme_id JOIN scheme_fields ON schemes.id=scheme_fields.scheme_id WHERE primary_key AND "
			  . "set_schemes.set_id=$options->{'set_id'} ORDER BY schemes.display_order,schemes.description";
		} else {
			$qry =
			    "SELECT DISTINCT schemes.id,set_schemes.set_name,schemes.description,schemes.display_order FROM set_schemes "
			  . "LEFT JOIN schemes ON set_schemes.scheme_id=schemes.id AND set_schemes.set_id=$options->{'set_id'} WHERE schemes.id "
			  . "IS NOT NULL ORDER BY schemes.display_order,schemes.description";
		}
	} else {
		if ( $options->{'with_pk'} ) {
			$qry =
			    "SELECT DISTINCT schemes.id,schemes.description,schemes.display_order FROM schemes RIGHT JOIN scheme_members ON "
			  . "schemes.id=scheme_members.scheme_id JOIN scheme_fields ON schemes.id=scheme_fields.scheme_id WHERE primary_key ORDER BY "
			  . "schemes.display_order,schemes.description";
		} else {
			$qry = "SELECT id,description,display_order FROM schemes WHERE id IN (SELECT scheme_id FROM scheme_members) ORDER BY "
			  . "display_order,description";
		}
	}
	my $list = $self->run_list_query_hashref($qry);
	foreach (@$list) {
		$_->{'description'} = $_->{'set_name'} if $_->{'set_name'};
	}
	return $list;
}

sub get_group_list {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $query_clause = $options->{'seq_query'} ? ' WHERE seq_query' : '';
	my $qry          = "SELECT id,name,display_order FROM scheme_groups$query_clause ORDER BY display_order,name";
	my $list         = $self->run_list_query_hashref($qry);
	return $list;
}

sub get_groups_in_group {
	my ( $self, $group_id, $level ) = @_;
	$level //= 0;
	$self->{'groups_in_group_list'} //= [];
	my $child_groups = $self->run_list_query( "SELECT group_id FROM scheme_group_group_members WHERE parent_group_id=?", $group_id );
	foreach my $child_group (@$child_groups) {
		push @{ $self->{'groups_in_group_list'} }, $child_group;
		my $new_level = $level;
		last if $new_level == 10;    #prevent runaway if child is set as the parent of a parental group
		my $grandchild_groups = $self->get_groups_in_group( $child_group, ++$new_level );
		push @{ $self->{'groups_in_group_list'} }, @$grandchild_groups;
	}
	my @group_list = @{ $self->{'groups_in_group_list'} };
	undef $self->{'groups_in_group_list'};
	return \@group_list;
}

sub get_schemes_in_group {
	my ( $self, $group_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $set_clause    = $options->{'set_id'}       ? ' AND scheme_id IN (SELECT scheme_id FROM set_schemes WHERE set_id=?)' : '';
	my $member_clause = $options->{'with_members'} ? ' AND scheme_id IN (SELECT scheme_id FROM scheme_members)'             : '';
	my @args          = ($group_id);
	push @args, $options->{'set_id'} if $options->{'set_id'};
	my $schemes =
	  $self->run_list_query( "SELECT scheme_id FROM scheme_group_scheme_members WHERE group_id=?$set_clause$member_clause", @args );
	my $child_groups = $self->get_groups_in_group($group_id);

	foreach my $child_group (@$child_groups) {
		my @child_args = ($child_group);
		push @child_args, $options->{'set_id'} if $options->{'set_id'};
		my $group_schemes =
		  $self->run_list_query( "SELECT scheme_id FROM scheme_group_scheme_members WHERE group_id=?$set_clause$member_clause",
			@child_args );
		push @$schemes, @$group_schemes;
	}
	return $schemes;
}

sub is_scheme_in_set {
	my ( $self, $scheme_id, $set_id ) = @_;
	if ( !$self->{'sql'}->{'scheme_in_set'} ) {
		$self->{'sql'}->{'scheme_in_set'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM set_schemes WHERE scheme_id=? AND set_id=?");
	}
	eval { $self->{'sql'}->{'scheme_in_set'}->execute( $scheme_id, $set_id ) };
	$logger->error($@) if $@;
	my ($is_it) = $self->{'sql'}->{'scheme_in_set'}->fetchrow_array;
	return $is_it;
}

sub get_set_locus_real_id {
	my ( $self, $locus, $set_id ) = @_;
	if ( !$self->{'sql'}->{'set_locus_real_id'} ) {
		$self->{'sql'}->{'set_locus_real_id'} = $self->{'db'}->prepare("SELECT locus FROM set_loci WHERE set_name=? AND set_id=?");
	}
	eval { $self->{'sql'}->{'set_locus_real_id'}->execute( $locus, $set_id ) };
	$logger->error($@) if $@;
	my ($real_id) = $self->{'sql'}->{'set_locus_real_id'}->fetchrow_array;
	return $real_id // $locus;
}

sub is_locus_in_set {
	my ( $self, $locus, $set_id ) = @_;
	if ( !$self->{'sql'}->{'locus_in_set'} ) {
		$self->{'sql'}->{'locus_in_set'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM set_loci WHERE locus=? AND set_id=?");
	}
	eval { $self->{'sql'}->{'locus_in_set'}->execute( $locus, $set_id ) };
	$logger->error($@) if $@;
	my ($is_it) = $self->{'sql'}->{'locus_in_set'}->fetchrow_array;
	return 1 if $is_it;

	#Also check if locus is in schemes within set
	my $schemes = $self->get_scheme_list( { set_id => $set_id } );
	foreach my $scheme (@$schemes) {
		my $locus_list = $self->get_scheme_loci( $scheme->{'id'} );
		return 1 if any { $locus eq $_ } @$locus_list;
	}
	return;
}

sub get_scheme {
	my ( $self, $id ) = @_;
	if ( !$self->{'scheme'}->{$id} ) {
		my $attributes = $self->get_scheme_info($id);
		if ( $attributes->{'dbase_name'} ) {
			my %att = (
				dbase_name         => $attributes->{'dbase_name'},
				host               => $attributes->{'dbase_host'},
				port               => $attributes->{'dbase_port'},
				user               => $attributes->{'dbase_user'},
				password           => $attributes->{'dbase_password'},
				allow_missing_loci => $attributes->{'allow_missing_loci'}
			);
			try {
				$attributes->{'db'} = $self->{'dataConnector'}->get_connection( \%att );
			}
			catch BIGSdb::DatabaseConnectionException with {
				$logger->warn("Can not connect to database '$attributes->{'dbase_name'}'");
			};
		}
		$attributes->{'fields'} = $self->get_scheme_fields($id);
		$attributes->{'loci'} = $self->get_scheme_loci( $id, ( { profile_name => 1, analysis_pref => 0 } ) );
		$attributes->{'primary_keys'} =
		  $self->run_list_query( "SELECT field FROM scheme_fields WHERE scheme_id=? AND primary_key ORDER BY field_order", $id );
		$self->{'scheme'}->{$id} = BIGSdb::Scheme->new(%$attributes);
	}
	return $self->{'scheme'}->{$id};
}

sub is_scheme_field {
	my ( $self, $scheme_id, $field ) = @_;
	my $fields = $self->get_scheme_fields($scheme_id);
	return any { $_ eq $field } @$fields;
}

sub create_temp_isolate_scheme_table {
	my ( $self, $scheme_id ) = @_;  
	my $view  = $self->{'system'}->{'view'};
	my $table = "temp_$view\_scheme_$scheme_id";

	#Test if view already exists
	my $exists = $self->run_simple_query( "SELECT EXISTS(SELECT * FROM information_schema.tables WHERE table_name=?)", $table );
	return $table if $exists->[0];
	my $scheme_info  = $self->get_scheme_info($scheme_id);
	my $loci         = $self->get_scheme_loci($scheme_id);
	my $joined_query = "SELECT $view.id";
	my ( %cleaned, @cleaned, %named );
	foreach my $locus (@$loci) {
		( $cleaned{$locus} = $locus ) =~ s/'/\\'/g;
		push @cleaned, $cleaned{$locus};
		( $named{$locus}   = $locus ) =~ s/'/_PRIME_/g;
		$joined_query .= ",ARRAY_AGG(DISTINCT(CASE WHEN allele_designations.locus=E'$cleaned{$locus}' THEN allele_designations.allele_id "
		  . "ELSE NULL END)) AS $named{$locus}";
	}

	#Listing scheme loci rather than testing for scheme membership within query is quicker!
	local $" = "',E'";
	$joined_query .= " FROM $view INNER JOIN allele_designations ON $view.id = allele_designations.isolate_id AND locus IN (E'@cleaned' "
	  . ") GROUP BY $view.id";
	eval { $self->{'db'}->do( "CREATE TEMP VIEW $table AS $joined_query" ) }; #View seems quicker than temp table.
	
	$logger->error($@) if $@;
	return $table;
}

sub create_temp_scheme_table {
	my ( $self, $id ) = @_;
	my $scheme_info = $self->get_scheme_info($id);
	my $scheme_db   = $self->get_scheme($id)->get_db;
	if ( !$scheme_db ) {
		$logger->error("No scheme database for scheme $id");
		throw BIGSdb::DatabaseConnectionException("Database does not exist");
	}

	#Test if table already exists
	my ($exists) = $self->run_simple_query( "SELECT EXISTS(SELECT * FROM information_schema.tables WHERE table_name=?)", "temp_scheme_$id" );
	if ( $exists->[0] ) {
		$logger->debug("Table already exists");
		return;
	}
	my $fields     = $self->get_scheme_fields($id);
	my $loci       = $self->get_scheme_loci($id);
	my $temp_table = "temp_scheme_$id";
	my $create     = "CREATE TEMP TABLE $temp_table (";
	my @table_fields;
	foreach (@$fields) {
		my $type = $self->get_scheme_field_info( $id, $_ )->{'type'};
		push @table_fields, "$_ $type";
	}
	my $qry = "SELECT profile_name FROM scheme_members WHERE locus=? AND scheme_id=?";
	my $sql = $self->{'db'}->prepare($qry);
	my @query_loci;
	foreach my $locus (@$loci) {
		my $type = $scheme_info->{'allow_missing_loci'} ? 'text' : $self->get_locus_info($locus)->{'allele_id_format'};
		eval { $sql->execute( $locus, $id ) };
		$logger->error($@) if $@;
		my ($profile_name) = $sql->fetchrow_array;
		$locus =~ s/'/_PRIME_/g;
		$profile_name =~ s/'/_PRIME_/g if defined $profile_name;
		push @table_fields, "$locus $type";
		push @query_loci, $profile_name || $locus;
	}
	local $" = ',';
	$create .= "@table_fields";
	$create .= ")";
	$self->{'db'}->do($create);
	my $table = $self->get_scheme_info($id)->{'dbase_table'};
	$qry = "SELECT @$fields,@query_loci FROM $table";
	my $scheme_sql = $scheme_db->prepare($qry);
	eval { $scheme_sql->execute };

	if ($@) {
		$logger->error($@);
		return;
	}
	local $" = ",";
	eval { $self->{'db'}->do("COPY $temp_table(@$fields,@$loci) FROM STDIN"); };
	if ($@) {
		$logger->error("Can't start copying data into temp table");
	}
	local $" = "\t";
	my $data = $scheme_sql->fetchall_arrayref;
	foreach (@$data) {
		foreach (@$_) {
			$_ = '\N' if !defined $_ || $_ eq '';
		}
		eval { $self->{'db'}->pg_putcopydata("@$_\n"); };
		if ($@) {
			$logger->warn("Can't put data into temp table @$_");
		}
	}
	eval { $self->{'db'}->pg_putcopyend; };
	if ($@) {
		$logger->error("Can't put data into temp table: $@");
		$self->{'db'}->rollback;
		throw BIGSdb::DatabaseConnectionException("Can't put data into temp table");
	}
	$self->_create_profile_indices( $temp_table, $id );
	foreach (@$fields) {
		my $field_info = $self->get_scheme_field_info( $id, $_ );
		if ( $field_info->{'type'} eq 'integer' ) {
			$self->{'db'}->do("CREATE INDEX i_$temp_table\_$_ ON $temp_table ($_)");
		} else {
			$self->{'db'}->do("CREATE INDEX i_$temp_table\_$_ ON $temp_table (UPPER($_))");
		}
		$self->{'db'}->do("UPDATE $temp_table SET $_ = null WHERE $_='-999'")
		  ;    #Needed as old style profiles database stored null values as '-999'.
	}
	return $temp_table;
}

sub _create_profile_indices {
	my ( $self, $table, $scheme_id ) = @_;
	my $loci = $self->get_scheme_loci($scheme_id);

	#Create separate indices consisting of up to 10 loci each
	my $i     = 0;
	my $index = 1;
	my @temp_loci;
	local $" = ',';
	foreach my $locus (@$loci) {
		$locus =~ s/'/_PRIME_/g;
		push @temp_loci, $locus;
		$i++;
		if ( $i % 10 == 0 || $i == @$loci ) {
			eval { $self->{'db'}->do("CREATE INDEX i_$table\_$index ON $table (@temp_loci)"); };
			$logger->warn("Can't create index $@") if $@;
			$index++;
			undef @temp_loci;
		}
	}
	return;
}

sub get_scheme_group_info {
	my ( $self, $locus ) = @_;
	if ( !$self->{'sql'}->{'scheme_group_info'} ) {
		$self->{'sql'}->{'scheme_group_info'} = $self->{'db'}->prepare("SELECT * FROM scheme_groups WHERE id=?");
		$logger->info("Statement handle 'scheme_group_info' prepared.");
	}
	eval { $self->{'sql'}->{'scheme_group_info'}->execute($locus); };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'scheme_group_info'}->fetchrow_hashref();
}
##############LOCI#####################################################################
sub get_loci {

	#options passed as hashref:
	#query_pref: only the loci for which the user has a query field preference selected will be returned
	#analysis_pref: only the loci for which the user has an analysis preference selected will be returned
	#seq_defined: only the loci for which a database or a reference sequence has been defined will be returned
	#do_not_order: don't order
	#{ query_pref => 1, analysis_pref => 1, seq_defined => 1, do_not_order => 1 }
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $defined_clause = $options->{'seq_defined'} ? 'WHERE dbase_name IS NOT NULL OR reference_sequence IS NOT NULL' : '';

	#Need to sort if pref settings are to be checked as we need scheme information
	$options->{'do_not_order'} = 0 if any { $options->{$_} } qw (query_pref analysis_pref);
	my $set_clause = '';
	if ( $options->{'set_id'} ) {
		$set_clause = $defined_clause ? 'AND' : 'WHERE';
		$set_clause .= " (id IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE "
		  . "set_id=$options->{'set_id'})) OR id IN (SELECT locus FROM set_loci WHERE set_id=$options->{'set_id'}))";
	}
	my $qry;
	if ( $options->{'do_not_order'} ) {
		$qry = "SELECT id FROM loci $defined_clause $set_clause";
	} else {
		$qry = "SELECT id,scheme_id from loci left join scheme_members on loci.id = scheme_members.locus $defined_clause $set_clause "
		  . "order by scheme_members.scheme_id,id";
	}
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute };
	$logger->error($@) if $@;
	my @query_loci;
	my $array_ref = $sql->fetchall_arrayref;
	foreach (@$array_ref) {
		next
		  if $options->{'query_pref'}
		  && ( !$self->{'prefs'}->{'query_field_loci'}->{ $_->[0] }
			|| ( defined $_->[1] && !$self->{'prefs'}->{'query_field_schemes'}->{ $_->[1] } ) );
		next
		  if $options->{'analysis_pref'}
		  && ( !$self->{'prefs'}->{'analysis_loci'}->{ $_->[0] }
			|| ( defined $_->[1] && !$self->{'prefs'}->{'analysis_schemes'}->{ $_->[1] } ) );
		push @query_loci, $_->[0];
	}
	@query_loci = uniq(@query_loci);
	return \@query_loci;
}

sub get_locus_list {

	#return sorted list of loci, with labels.  Includes common names.
	#options passed as hashref:
	#analysis_pref: only the loci for which the user has an analysis preference selected will be returned
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $qry;
	if ( $options->{'set_id'} ) {
		$qry =
		    "SELECT loci.id,common_name,set_id,set_name,set_common_name FROM loci LEFT JOIN set_loci ON loci.id = set_loci.locus "
		  . "WHERE id IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE "
		  . "set_id=$options->{'set_id'})) OR id IN (SELECT locus FROM set_loci WHERE set_id=$options->{'set_id'})";
	} else {
		$qry = "SELECT id,common_name FROM loci";
	}
	if ( $options->{'locus_curator'} && BIGSdb::Utils::is_int( $options->{'locus_curator'} ) ) {
		$qry .= ( $qry =~ /loci$/ ) ? ' WHERE ' : ' AND ';
		$qry .= "loci.id IN (SELECT locus from locus_curators WHERE curator_id = $options->{'locus_curator'})";
	}
	if ( $options->{'no_extended_attributes'} ) {
		$qry .= ( $qry =~ /loci$/ ) ? ' WHERE ' : ' AND ';
		$qry .= "loci.id NOT IN (SELECT locus from locus_extended_attributes)";
	}
	my $loci = $self->run_list_query_hashref($qry);
	my $cleaned;
	my $display_loci;
	foreach my $locus (@$loci) {
		next if $options->{'analysis_pref'} && !$self->{'prefs'}->{'analysis_loci'}->{ $locus->{'id'} };
		next if $options->{'set_id'} && $locus->{'set_id'} && $locus->{'set_id'} != $options->{'set_id'};
		push @$display_loci, $locus->{'id'};
		if ( $locus->{'set_name'} ) {
			$cleaned->{ $locus->{'id'} } = $locus->{'set_name'};
			if ( $locus->{'set_common_name'} ) {
				$cleaned->{ $locus->{'id'} } .= " ($locus->{'set_common_name'})";
				if ( !$options->{'no_list_by_common_name'} ) {
					push @$display_loci, "cn_$locus->{'id'}";
					$cleaned->{"cn_$locus->{'id'}"} = "$locus->{'set_common_name'} ($locus->{'set_name'})";
					$cleaned->{"cn_$locus->{'id'}"} =~ tr/_/ /;
				}
			}
		} else {
			$cleaned->{ $locus->{'id'} } = $locus->{'id'};
			if ( $locus->{'common_name'} ) {
				$cleaned->{ $locus->{'id'} } .= " ($locus->{'common_name'})";
				if ( !$options->{'no_list_by_common_name'} ) {
					push @$display_loci, "cn_$locus->{'id'}";
					$cleaned->{"cn_$locus->{'id'}"} = "$locus->{'common_name'} ($locus->{'id'})";
					$cleaned->{"cn_$locus->{'id'}"} =~ tr/_/ /;
				}
			}
		}
	}
	@$display_loci = uniq @$display_loci;

	#dictionary sort
	@$display_loci = map { $_->[0] }
	  sort { $a->[1] cmp $b->[1] }
	  map {
		my $d = lc( $cleaned->{$_} );
		$d =~ s/[\W_]+//g;
		[ $_, $d ]
	  } @$display_loci;
	return ( $display_loci, $cleaned );
}

sub get_locus_info {
	my ( $self, $locus, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	if ( !$self->{'sql'}->{'locus_info'} ) {
		$self->{'sql'}->{'locus_info'} = $self->{'db'}->prepare("SELECT * FROM loci WHERE id=?");
		$logger->info("Statement handle 'locus_info' prepared.");
	}
	eval { $self->{'sql'}->{'locus_info'}->execute($locus) };
	$logger->error($@) if $@;
	my $locus_info = $self->{'sql'}->{'locus_info'}->fetchrow_hashref;
	if ( $options->{'set_id'} ) {
		if ( !$self->{'sql'}->{'set_locus_info'} ) {
			$self->{'sql'}->{'set_locus_info'} = $self->{'db'}->prepare("SELECT * FROM set_loci WHERE set_id=? AND locus=?");
		}
		eval { $self->{'sql'}->{'set_locus_info'}->execute( $options->{'set_id'}, $locus ) };
		$logger->error($@) if $@;
		my $set_locus = $self->{'sql'}->{'set_locus_info'}->fetchrow_hashref;
		$locus_info->{'set_name'}        = $set_locus->{'set_name'};
		$locus_info->{'set_common_name'} = $set_locus->{'set_common_name'};
	}
	return $locus_info;
}

sub get_locus {
	my ( $self, $id ) = @_;
	if ( !$self->{'locus'}->{$id} ) {
		my $attributes = $self->get_locus_info($id);
		if ( $attributes->{'dbase_name'} ) {
			my %att = (
				'dbase_name' => $attributes->{'dbase_name'},
				'host'       => $attributes->{'dbase_host'},
				'port'       => $attributes->{'dbase_port'},
				'user'       => $attributes->{'dbase_user'},
				'password'   => $attributes->{'dbase_password'}
			);
			try {
				$attributes->{'db'} = $self->{'dataConnector'}->get_connection( \%att );
			}
			catch BIGSdb::DatabaseConnectionException with {
				$logger->warn("Can not connect to database '$attributes->{'dbase_name'}'");
			};
		}
		$self->{'locus'}->{$id} = BIGSdb::Locus->new(%$attributes);
	}
	return $self->{'locus'}->{$id};
}

sub is_locus {
	my ( $self, $id ) = @_;
	$id ||= '';
	my $loci = $self->get_loci( { do_not_order => 1 } );
	return any { $_ eq $id } @$loci;
}

sub get_set_locus_label {
	my ( $self, $locus, $set_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	if ( !$self->{'sql'}->{'get_set_locus_label'} ) {
		$self->{'sql'}->{'get_set_locus_label'} = $self->{'db'}->prepare("SELECT * FROM set_loci WHERE set_id=? AND locus=?");
	}
	if ($set_id) {
		eval { $self->{'sql'}->{'get_set_locus_label'}->execute( $set_id, $locus ) };
		$logger->error($@) if $@;
		my $set_loci = $self->{'sql'}->{'get_set_locus_label'}->fetchrow_hashref;
		my $set_cleaned;
		if ( $options->{'text_output'} ) {
			$set_cleaned = $set_loci->{'set_name'} // $locus;
			$set_cleaned .= " ($set_loci->{'set_common_name'})" if $set_loci->{'set_common_name'};
		} else {
			$set_cleaned = $set_loci->{'formatted_set_name'} // $set_loci->{'set_name'} // $locus;
			my $common_name = $set_loci->{'formatted_set_common_name'} // $set_loci->{'set_common_name'};
			$set_cleaned .= " ($common_name)" if $common_name;
		}
		return $set_cleaned;
	}
	return;
}
##############ALLELES##################################################################
sub get_allele_designation {
	my ( $self, $isolate_id, $locus ) = @_;
	$logger->logcarp("Datastore::get_allele_designation is deprecated");    #TODO remove
	if ( !$self->{'sql'}->{'allele_designation'} ) {
		$self->{'sql'}->{'allele_designation'} = $self->{'db'}->prepare("SELECT * FROM allele_designations WHERE isolate_id=? AND locus=?");
		$logger->info("Statement handle 'allele_designation' prepared.");
	}
	eval { $self->{'sql'}->{'allele_designation'}->execute( $isolate_id, $locus ); };
	$logger->error($@) if $@;
	my $allele = $self->{'sql'}->{'allele_designation'}->fetchrow_hashref;
	return $allele;
}

sub get_allele_designations {
	my ( $self, $isolate_id, $locus ) = @_;
	if ( !$self->{'sql'}->{'allele_designations'} ) {
		$self->{'sql'}->{'allele_designations'} =
		  $self->{'db'}->prepare("SELECT allele_id,status FROM allele_designations WHERE isolate_id=? AND locus=?");
	}
	eval { $self->{'sql'}->{'allele_designations'}->execute( $isolate_id, $locus ); };
	$logger->error($@) if $@;
	return $self->{'sql'}->{'allele_designations'}->fetchall_arrayref( {} );
}

sub get_allele_extended_attributes {
	my ( $self, $locus, $allele_id ) = @_;
	if ( !$self->{'sql'}->{'locus_extended_attributes'} ) {
		$self->{'sql'}->{'locus_extended_attributes'} =
		  $self->{'db'}->prepare("SELECT field FROM locus_extended_attributes WHERE locus=? ORDER BY field_order");
	}
	eval { $self->{'sql'}->{'locus_extended_attributes'}->execute($locus) };
	$logger->logcarp($@) if $@;
	if ( !$self->{'sql'}->{'sequence_extended_attributes'} ) {
		$self->{'sql'}->{'sequence_extended_attributes'} =
		  $self->{'db'}->prepare("SELECT field,value FROM sequence_extended_attributes WHERE locus=? AND field=? AND allele_id=?");
	}
	my @values;
	while ( my ($field) = $self->{'sql'}->{'locus_extended_attributes'}->fetchrow_array ) {
		eval { $self->{'sql'}->{'sequence_extended_attributes'}->execute( $locus, $field, $allele_id ) };
		$logger->logcarp($@) if $@;
		my $values_ref = $self->{'sql'}->{'sequence_extended_attributes'}->fetchrow_hashref;
		push @values, $values_ref if $values_ref;
	}
	return \@values;
}

sub get_all_allele_designations {
	my ( $self, $isolate_id ) = @_;
	if ( !$self->{'sql'}->{'all_allele_designation'} ) {
		$self->{'sql'}->{'all_allele_designation'} =
		  $self->{'db'}->prepare("SELECT locus,allele_id,status FROM allele_designations WHERE isolate_id=?");
		$logger->info("Statement handle 'all_allele_designation' prepared.");
	}
	eval { $self->{'sql'}->{'all_allele_designation'}->execute($isolate_id); };
	$logger->error($@) if $@;
	my $alleles = $self->{'sql'}->{'all_allele_designation'}->fetchall_hashref('locus');
	return $alleles;
}

sub get_scheme_allele_designations {
	my ( $self, $isolate_id, $scheme_id, $options ) = @_;
	my $designations;
	if ($scheme_id) {
		if ( !$self->{'sql'}->{'scheme_allele_designations'} ) {
			$self->{'sql'}->{'scheme_allele_designations'} =
			  $self->{'db'}->prepare( "SELECT * FROM allele_designations WHERE isolate_id=? AND locus IN "
				  . "(SELECT locus FROM scheme_members WHERE scheme_id=?) ORDER BY status,date_entered,allele_id" );
		}
		eval { $self->{'sql'}->{'scheme_allele_designations'}->execute( $isolate_id, $scheme_id ) };
		$logger->error($@) if $@;
		while ( my $designation = $self->{'sql'}->{'scheme_allele_designations'}->fetchrow_hashref ) {
			push @{ $designations->{ $designation->{'locus'} } }, $designation;
		}
	} else {
		if ( !$self->{'sql'}->{'noscheme_allele_designations'} ) {
			my $set_clause =
			  $options->{'set_id'}
			  ? "SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes WHERE set_id=$options->{'set_id'})"
			  : "SELECT locus FROM scheme_members";
			$self->{'sql'}->{'noscheme_allele_designations'} =
			  $self->{'db'}->prepare( "SELECT * FROM allele_designations WHERE isolate_id=? AND locus NOT IN ($set_clause) "
				  . "ORDER BY status,date_entered,allele_id" );
		}
		eval { $self->{'sql'}->{'noscheme_allele_designations'}->execute($isolate_id) };
		$logger->error($@) if $@;
		while ( my $designation = $self->{'sql'}->{'noscheme_allele_designations'}->fetchrow_hashref ) {
			push @{ $designations->{ $designation->{'locus'} } }, $designation;
		}
	}
	return $designations;
}

sub get_all_allele_sequences {
	my ( $self, $isolate_id ) = @_;
	if ( !$self->{'sql'}->{'all_allele_sequences'} ) {
		$self->{'sql'}->{'all_allele_sequences'} =
		  $self->{'db'}->prepare("SELECT allele_sequences.* FROM allele_sequences WHERE isolate_id=?");
		$logger->info("Statement handle 'all_allele_sequences' prepared.");
	}
	eval { $self->{'sql'}->{'all_allele_sequences'}->execute($isolate_id); };
	$logger->error($@) if $@;
	my $sequences = $self->{'sql'}->{'all_allele_sequences'}->fetchall_hashref( [qw(locus seqbin_id start_pos end_pos)] );
	return $sequences;
}

sub get_sequence_flags {
	my ( $self, $id ) = @_;
	if ( !$self->{'sql'}->{'sequence_flag'} ) {
		$self->{'sql'}->{'sequence_flag'} = $self->{'db'}->prepare("SELECT flag FROM sequence_flags WHERE id=?");
	}
	eval { $self->{'sql'}->{'sequence_flag'}->execute($id) };
	$logger->error($@) if $@;
	my @flags;
	while ( my ($flag) = $self->{'sql'}->{'sequence_flag'}->fetchrow_array ) {
		push @flags, $flag;
	}
	return \@flags;
}

sub get_allele_flags {
	my ( $self, $locus, $allele_id ) = @_;
	if ( !$self->{'sql'}->{'allele_flags'} ) {
		$self->{'sql'}->{'allele_flags'} =
		  $self->{'db'}->prepare("SELECT flag FROM allele_flags WHERE locus=? AND allele_id=? ORDER BY flag");
	}
	eval { $self->{'sql'}->{'allele_flags'}->execute( $locus, $allele_id ) };
	$logger->error($@) if $@;
	my @flags;
	while ( my ($flag) = $self->{'sql'}->{'allele_flags'}->fetchrow_array ) {
		push @flags, $flag;
	}
	return \@flags;
}

sub get_allele_id {

	#quicker than get_allele_designation if you only want the allele_id field
	my ( $self, $isolate_id, $locus ) = @_;
	$logger->logcarp("Datastore::get_allele_id is deprecated");    #TODO remove
	if ( !$self->{'sql'}->{'allele_id'} ) {
		$self->{'sql'}->{'allele_id'} = $self->{'db'}->prepare("SELECT allele_id FROM allele_designations WHERE isolate_id=? AND locus=?");
		$logger->info("Statement handle 'allele_designation' prepared.");
	}
	eval { $self->{'sql'}->{'allele_id'}->execute( $isolate_id, $locus ) };
	$logger->error($@) if $@;
	my ($allele_id) = $self->{'sql'}->{'allele_id'}->fetchrow_array;
	return $allele_id;
}

sub get_all_allele_ids {
	my ( $self, $isolate_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my %allele_ids;
	if ( !$self->{'sql'}->{'all_allele_ids'} ) {
		my $set_clause =
		  $options->{'set_id'}
		  ? "AND (locus IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT "
		  . "scheme_id FROM set_schemes WHERE set_id=$options->{'set_id'})) OR locus IN (SELECT locus FROM set_loci WHERE "
		  . "set_id=$options->{'set_id'}))"
		  : '';
		$self->{'sql'}->{'all_allele_ids'} =
		  $self->{'db'}->prepare("SELECT locus,allele_id FROM allele_designations WHERE isolate_id=? $set_clause");
		$logger->info("Statement handle 'all_allele_ids' prepared.");
	}
	eval { $self->{'sql'}->{'all_allele_ids'}->execute($isolate_id) };
	$logger->error($@) if $@;
	while ( my ( $locus, $allele_id ) = $self->{'sql'}->{'all_allele_ids'}->fetchrow_array ) {
		$allele_ids{$locus} = $allele_id;
	}
	return \%allele_ids;
}

sub get_allele_sequence {
	my ( $self, $isolate_id, $locus ) = @_;
	if ( !$self->{'sql'}->{'allele_sequence'} ) {
		$self->{'sql'}->{'allele_sequence'} =
		  $self->{'db'}->prepare("SELECT * FROM allele_sequences WHERE isolate_id=? AND locus=? ORDER BY complete desc");
		$logger->info("Statement handle 'allele_sequence' prepared.");
	}
	eval { $self->{'sql'}->{'allele_sequence'}->execute( $isolate_id, $locus ) };
	$logger->error($@) if $@;
	my @allele_sequences;
	while ( my $allele_sequence = $self->{'sql'}->{'allele_sequence'}->fetchrow_hashref ) {
		push @allele_sequences, $allele_sequence;
	}
	return \@allele_sequences;
}

sub allele_sequence_exists {

	#Marginally quicker than get_allele_sequence if you just want to check presence of tag.
	my ( $self, $isolate_id, $locus ) = @_;
	if ( !$self->{'sql'}->{'allele_sequence_exists'} ) {
		$self->{'sql'}->{'allele_sequence_exists'} =
		  $self->{'db'}->prepare("SELECT EXISTS(SELECT allele_sequences.seqbin_id FROM allele_sequences WHERE isolate_id=? AND locus=?)");
	}
	eval { $self->{'sql'}->{'allele_sequence_exists'}->execute( $isolate_id, $locus ) };
	$logger->error($@) if $@;
	my ($exists) = $self->{'sql'}->{'allele_sequence_exists'}->fetchrow_array;
	return $exists;
}

sub sequences_exist {

	#used for profile/sequence definitions databases
	my ( $self, $locus ) = @_;
	if ( !$self->{'sql'}->{'sequences_exist'} ) {
		$self->{'sql'}->{'sequences_exist'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM sequences WHERE locus=?");
		$logger->info("Statement handle 'sequences_exist' prepared.");
	}
	eval { $self->{'sql'}->{'sequences_exist'}->execute($locus) };
	$logger->error($@) if $@;
	my ($exists) = $self->{'sql'}->{'sequences_exist'}->fetchrow_array;
	return $exists;
}

sub sequence_exists {

	#used for profile/sequence definitions databases
	my ( $self, $locus, $allele_id ) = @_;
	if ( !$self->{'sql'}->{'sequence_exists'} ) {
		$self->{'sql'}->{'sequence_exists'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM sequences WHERE locus=? AND allele_id=?");
		$logger->info("Statement handle 'sequence_exists' prepared.");
	}
	eval { $self->{'sql'}->{'sequence_exists'}->execute( $locus, $allele_id ) };
	$logger->error($@) if $@;
	my ($exists) = $self->{'sql'}->{'sequence_exists'}->fetchrow_array;
	return $exists;
}

sub get_profile_allele_designation {
	my ( $self, $scheme_id, $profile_id, $locus ) = @_;
	if ( !$self->{'sql'}->{'profile_allele_designation'} ) {
		$self->{'sql'}->{'profile_allele_designation'} =
		  $self->{'db'}->prepare("SELECT * FROM profile_members WHERE scheme_id=? AND profile_id=? AND locus=?");
		$logger->info("Statement handle 'profile_allele_designation' prepared.");
	}
	eval { $self->{'sql'}->{'profile_allele_designation'}->execute( $scheme_id, $profile_id, $locus ) };
	$logger->error($@) if $@;
	my $allele = $self->{'sql'}->{'profile_allele_designation'}->fetchrow_hashref;
	return $allele;
}

sub get_sequence {

	#used for profile/sequence definitions databases
	my ( $self, $locus, $allele_id ) = @_;
	if ( !$self->{'sql'}->{'sequence'} ) {
		$self->{'sql'}->{'sequence'} = $self->{'db'}->prepare("SELECT sequence FROM sequences WHERE locus=? AND allele_id=?");
		$logger->info("Statement handle 'sequence' prepared.");
	}
	eval { $self->{'sql'}->{'sequence'}->execute( $locus, $allele_id ) };
	$logger->error($@) if $@;
	my ($seq) = $self->{'sql'}->{'sequence'}->fetchrow_array;
	return \$seq;
}

sub is_allowed_to_modify_locus_sequences {

	#used for profile/sequence definitions databases
	my ( $self, $locus, $curator_id ) = @_;
	if ( !$self->{'sql'}->{'allow_locus'} ) {
		$self->{'sql'}->{'allow_locus'} = $self->{'db'}->prepare("SELECT COUNT(*) FROM locus_curators WHERE locus=? AND curator_id=?");
		$logger->info("Statement handle 'allow_locus' prepared.");
	}
	eval { $self->{'sql'}->{'allow_locus'}->execute( $locus, $curator_id ) };
	$logger->error($@) if $@;
	my ($allowed) = $self->{'sql'}->{'allow_locus'}->fetchrow_array;
	return $allowed;
}

sub get_next_allele_id {

	#used for profile/sequence definitions databases
	#finds the lowest unused id.
	my ( $self, $locus ) = @_;
	if ( !$self->{'sql'}->{'next_allele_id'} ) {
		$self->{'sql'}->{'next_allele_id'} =
		  $self->{'db'}->prepare( "SELECT DISTINCT CAST(allele_id AS int) FROM sequences WHERE locus = ? AND allele_id != 'N' ORDER BY "
			  . "CAST(allele_id AS int)" );
		$logger->info("Statement handle 'next_allele_id' prepared.");
	}
	eval { $self->{'sql'}->{'next_allele_id'}->execute($locus) };
	if ($@) {
		$logger->error("Can't execute 'next_allele_id' query $@");
		return;
	}
	my $test = 0;
	my $next = 0;
	my $id   = 0;
	while ( my @data = $self->{'sql'}->{'next_allele_id'}->fetchrow_array() ) {
		if ( $data[0] != 0 ) {
			$test++;
			$id = $data[0];
			if ( $test != $id ) {
				$next = $test;
				$logger->debug("Next id: $next");
				return $next;
			}
		}
	}
	if ( $next == 0 ) {
		$next = $id + 1;
	}
	$logger->debug("Next id: $next");
	return $next;
}

sub get_client_data_linked_to_allele {
	my ( $self, $locus, $allele_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $sql =
	  $self->{'db'}->prepare( "SELECT client_dbase_id,isolate_field FROM client_dbase_loci_fields WHERE allele_query AND "
		  . "locus = ? ORDER BY client_dbase_id,isolate_field" );
	eval { $sql->execute($locus) };
	$logger->error($@) if $@;
	my $client_field_data = $sql->fetchall_arrayref;
	my ( $dl_buffer, $td_buffer );
	my $i = 0;

	foreach my $client_field (@$client_field_data) {
		my $field          = $client_field->[1];
		my $client         = $self->get_client_db( $client_field->[0] );
		my $client_db_desc = $self->get_client_db_info( $client_field->[0] )->{'name'};
		my $proceed        = 1;
		my $field_data;
		try {
			$field_data = $client->get_fields( $field, $locus, $allele_id );
		}
		catch BIGSdb::DatabaseConfigurationException with {
			$logger->error( "Can't extract isolate field '$field' FROM client database, make sure the client_dbase_loci_fields "
				  . "table is correctly configured.  $@" );
			$proceed = 0;
		};
		next if !$proceed;
		next if !@$field_data;
		$dl_buffer .= "<dt>$field</dt>";
		my @values;
		foreach my $data (@$field_data) {
			my $value = $data->{$field};
			if ( any { $field eq $_ } qw (species genus) ) {
				$value = "<i>$value</i>";
			}
			$value .= " [n=$data->{'frequency'}]";
			push @values, $value;
		}
		local $" = @values > 10 ? "<br />\n" : '; ';
		$dl_buffer .= "<dd>@values <span class=\"source\">$client_db_desc</span></dd>";
		$td_buffer .= "<br />\n" if $i;
		$td_buffer .= "<span class=\"source\">$client_db_desc</span> <b>$field:</b> @values";
		$i++;
	}
	$dl_buffer = "<dl class=\"data\">\n$dl_buffer\n</dl>" if $dl_buffer;
	if ( $options->{'table_format'} ) {
		return $td_buffer;
	}
	return $dl_buffer;
}

sub _format_list_values {
	my ( $self, $hash_ref ) = @_;
	my $buffer = '';
	if ( keys %$hash_ref ) {
		my $first = 1;
		foreach ( sort keys %$hash_ref ) {
			local $" = ', ';
			$buffer .= '; ' if !$first;
			$buffer .= "$_: @{$hash_ref->{$_}}";
			$first = 0;
		}
	}
	return $buffer;
}

sub get_allele_attributes {
	my ( $self, $locus, $allele_ids_refs ) = @_;
	return [] if ref $allele_ids_refs ne 'ARRAY';
	my $fields = $self->run_list_query( "SELECT field FROM locus_extended_attributes WHERE locus=?", $locus );
	my $sql = $self->{'db'}->prepare("SELECT value FROM sequence_extended_attributes WHERE locus=? AND field=? AND allele_id=?");
	my $values;
	return if !@$fields;
	foreach my $field (@$fields) {
		foreach (@$allele_ids_refs) {
			eval { $sql->execute( $locus, $field, $_ ) };
			$logger->error($@) if $@;
			while ( my ($value) = $sql->fetchrow_array ) {
				next if !defined $value || $value eq '';
				push @{ $values->{$field} }, $value;
			}
		}
		if ( ref $values->{$field} eq 'ARRAY' && @{ $values->{$field} } ) {
			my @list = @{ $values->{$field} };
			@list = uniq sort @list;
			@{ $values->{$field} } = @list;
		}
	}
	return $self->_format_list_values($values);
}
##############REFERENCES###############################################################
sub get_citation_hash {
	my ( $self, $pmid_ref, $options ) = @_;
	my $citation_ref;
	my %att = (
		'dbase_name' => $self->{'config'}->{'ref_db'},
		'host'       => $self->{'system'}->{'host'},
		'port'       => $self->{'system'}->{'port'},
		'user'       => $self->{'system'}->{'user'},
		'password'   => $self->{'system'}->{'pass'}
	);
	my $dbr;
	try {
		$dbr = $self->{'dataConnector'}->get_connection( \%att );
	}
	catch BIGSdb::DatabaseConnectionException with {
		$logger->error("Can't connect to reference database");
	};
	return $citation_ref if !$self->{'config'}->{'ref_db'} || !$dbr;
	my $sqlr  = $dbr->prepare("SELECT year,journal,title,volume,pages FROM refs WHERE pmid=?");
	my $sqlr2 = $dbr->prepare("SELECT surname,initials FROM authors WHERE id=?");
	my $sqlr3 = $dbr->prepare("SELECT author FROM refauthors WHERE pmid=? ORDER BY position");
	foreach (@$pmid_ref) {
		eval { $sqlr->execute($_) };
		$logger->error($@) if $@;
		eval { $sqlr3->execute($_) };
		$logger->error($@) if $@;
		my ( $year, $journal, $title, $volume, $pages ) = $sqlr->fetchrow_array;
		if ( !defined $year && !defined $journal ) {
			$citation_ref->{$_} .= "<a href=\"http://www.ncbi.nlm.nih.gov/pubmed/$_\">" if $options->{'link_pubmed'};
			$citation_ref->{$_} .= "Pubmed id#$_";
			$citation_ref->{$_} .= "</a>"                                               if $options->{'link_pubmed'};
			$citation_ref->{$_} .= ": No details available."                            if $options->{'state_if_unavailable'};
			next;
		}
		my @authors;
		while ( my ($authorid) = $sqlr3->fetchrow_array ) {
			push @authors, $authorid;
		}
		my ( $author, @author_list );
		if ( $options->{'all_authors'} ) {
			foreach (@authors) {
				eval { $sqlr2->execute($_) };
				$logger->error($@) if $@;
				my ( $surname, $initials ) = $sqlr2->fetchrow_array;
				$author = "$surname $initials";
				push @author_list, $author;
			}
			local $" = ', ';
			$author = "@author_list";
		} else {
			eval { $sqlr2->execute( $authors[0] ) };
			$logger->error($@) if $@;
			my ( $surname, undef ) = $sqlr2->fetchrow_array;
			$author .= ( $surname || 'Unknown' );
			if ( scalar @authors > 1 ) {
				$author .= ' et al.';
			}
		}
		$volume .= ':' if $volume;
		my $citation;
		{
			no warnings 'uninitialized';
			if ( $options->{'formatted'} ) {
				$citation = "$author ($year). ";
				$citation .= "$title "                                            if !$options->{'no_title'};
				$citation .= "<a href=\"http://www.ncbi.nlm.nih.gov/pubmed/$_\">" if $options->{'link_pubmed'};
				$citation .= "<i>$journal</i> <b>$volume</b>$pages";
				$citation .= "</a>"                                               if $options->{'link_pubmed'};
			} else {
				$citation = "$author $year $journal $volume$pages";
			}
		}
		if ($author) {
			$citation_ref->{$_} = $citation;
		} else {
			if ( $options->{'state_if_unavailable'} ) {
				$citation_ref->{$_} .= 'No details available.';
			} else {
				$citation_ref->{$_} .= "Pubmed id#";
				$citation_ref->{$_} .= $options->{'link_pubmed'} ? "<a href=\"http://www.ncbi.nlm.nih.gov/pubmed/$_\">$_</a>" : $_;
			}
		}
	}
	$sqlr->finish  if $sqlr;
	$sqlr2->finish if $sqlr2;
	$sqlr3->finish if $sqlr3;
	return $citation_ref;
}

sub create_temp_ref_table {
	my ( $self, $list, $qry_ref ) = @_;
	my %att = (
		dbase_name => $self->{'config'}->{'ref_db'},
		host       => $self->{'system'}->{'host'},
		port       => $self->{'system'}->{'port'},
		user       => $self->{'system'}->{'user'},
		password   => $self->{'system'}->{'pass'}
	);
	my $dbr;
	my $continue = 1;
	try {
		$dbr = $self->{'dataConnector'}->get_connection( \%att );
	}
	catch BIGSdb::DatabaseConnectionException with {
		$continue = 0;
		print "<div class=\"box\" id=\"statusbad\"><p>Can not connect to reference database!</p></div>\n";
		$logger->error->("Can't connect to reference database");
	};
	return if !$continue;
	my $create = "CREATE TEMP TABLE temp_refs (pmid int, year int, journal text, volume text, pages text, title text, "
	  . "abstract text, authors text, isolates int);";
	eval { $self->{'db'}->do($create); };
	if ($@) {
		$logger->error("Can't create temporary reference table. $@");
		return;
	}
	my $sql1 = $dbr->prepare("SELECT pmid,year,journal,volume,pages,title,abstract FROM refs WHERE pmid=?");
	my $sql2 = $dbr->prepare("SELECT author FROM refauthors WHERE pmid=? ORDER BY position");
	my $sql3 = $dbr->prepare("SELECT id,surname,initials FROM authors");
	eval { $sql3->execute; };
	$logger->error($@) if $@;
	my $all_authors = $sql3->fetchall_hashref('id');
	my $qry4;

	if ($qry_ref) {
		my $isolate_qry = $$qry_ref;
		$isolate_qry =~ s/\*/id/;
		$qry4 = "SELECT COUNT(*) FROM refs WHERE isolate_id IN ($isolate_qry) AND refs.pubmed_id=?";
	} else {
		$qry4 = "SELECT COUNT(*) FROM refs WHERE refs.pubmed_id=?";
	}
	my $sql4 = $self->{'db'}->prepare($qry4);
	foreach my $pmid (@$list) {
		eval { $sql1->execute($pmid) };
		$logger->error($@) if $@;
		my @refdata = $sql1->fetchrow_array;
		eval { $sql2->execute($pmid) };
		$logger->error($@) if $@;
		my @authors;
		my $author_arrayref = $sql2->fetchall_arrayref;
		foreach (@$author_arrayref) {
			push @authors, "$all_authors->{$_->[0]}->{'surname'} $all_authors->{$_->[0]}->{'initials'}";
		}
		local $" = ', ';
		my $author_string = "@authors";
		eval { $sql4->execute($pmid) };
		$logger->error($@) if $@;
		my ($isolates) = $sql4->fetchrow_array;
		local $" = "','";
		eval {
			my $qry = "INSERT INTO temp_refs VALUES (?,?,?,?,?,?,?,?,?)";

			if ( $refdata[0] ) {
				$self->{'db'}->do( $qry, undef, @refdata, $author_string, $isolates );
			} else {
				$self->{'db'}->do( $qry, undef, $pmid, undef, undef, undef, undef, undef, undef, undef, $isolates );
			}
		};
		$logger->error($@) if $@;
	}
	return 1;
}
##############SQL######################################################################
sub run_simple_query {

	#runs simple query (single row returned) against current database
	my ( $self, $qry, @values ) = @_;
	$logger->debug("Query: $qry");
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute(@values) };
	$logger->logcarp("$qry $@") if $@;
	my $data = $sql->fetchrow_arrayref;
	return $data;
}

sub run_simple_query_hashref {

	#runs simple query (single row returned) against current database
	my ( $self, $qry, @values ) = @_;
	$logger->debug("Query: $qry");
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute(@values) };
	$logger->logcarp("$qry $@") if $@;
	my $data = $sql->fetchrow_hashref;
	return $data;
}

sub run_list_query_hashref {

	#runs query against current database (arrayref of hashrefs returned)
	my ( $self, $qry, @values ) = @_;
	$logger->debug("Query: $qry");
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute(@values) };
	$logger->logcarp("$qry $@") if $@;
	return $sql->fetchall_arrayref({});
}

sub run_list_query {

	#runs query against current database (multiple row of single value returned)
	my ( $self, $qry, @values ) = @_;
	$logger->debug("Query: $qry");
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute(@values) };
	$logger->logcarp("$qry $@") if $@;
	my @list;
	while ( ( my $data ) = $sql->fetchrow_array ) {
		if ( defined $data && $data ne '-999' && $data ne '0001-01-01' ) {
			push @list, $data;
		}
	}
	return \@list;
}

sub run_simple_ref_query {

	#runs simple query (single row returned) against ref database
	my ( $self, $qry, @values ) = @_;
	my %att = (
		'dbase_name' => $self->{'config'}->{'ref_db'},
		'host'       => $self->{'system'}->{'host'},
		'port'       => $self->{'system'}->{'port'},
		'user'       => $self->{'system'}->{'user'},
		'password'   => $self->{'system'}->{'pass'}
	);
	my $dbr = $self->{'dataConnector'}->get_connection( \%att );
	$logger->debug("Ref query: $qry");
	my $sql = $dbr->prepare($qry);
	eval { $sql->execute(@values); };
	$logger->logcarp("$qry $@") if $@;
	my $data = $sql->fetchrow_arrayref;
	return $data;
}

sub get_table_field_attributes {

	#Returns array ref of attributes for a specific table provided by table-specific helper functions in BIGSdb::TableAttributes.
	my ( $self, $table ) = @_;
	my $function = "BIGSdb::TableAttributes::get_$table\_table_attributes";
	my $attributes;
	eval { $attributes = $self->$function() };
	$logger->logcarp($@) if $@;
	return if ref $attributes ne 'ARRAY';
	foreach my $att (@$attributes) {
		foreach (qw(tooltip optlist required default hide hide_public hide_query main_display)) {
			$att->{$_} = '' if !defined( $att->{$_} );
		}
	}
	return $attributes;
}

sub get_table_pks {
	my ( $self, $table ) = @_;
	my @pk_fields;
	return ['id'] if $table eq 'isolates';
	my $attributes = $self->get_table_field_attributes($table);
	foreach (@$attributes) {
		if ( $_->{'primary_key'} ) {
			push @pk_fields, $_->{'name'};
		}
	}
	return \@pk_fields;
}

sub is_table {
	my ( $self, $qry ) = @_;
	$qry ||= '';
	my @tables = $self->get_tables;
	return 1 if any { $_ eq $qry } @tables;
	return 0;
}

sub get_tables {
	my ($self) = @_;
	my @tables;
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		@tables = qw(users user_groups user_group_members allele_sequences sequence_bin accession refs allele_designations
		  pending_allele_designations loci locus_aliases schemes scheme_members scheme_fields composite_fields composite_field_values
		  isolate_aliases user_permissions isolate_user_acl isolate_usergroup_acl projects project_members experiments experiment_sequences
		  isolate_field_extended_attributes isolate_value_extended_attributes scheme_groups scheme_group_scheme_members
		  scheme_group_group_members pcr pcr_locus probes probe_locus sets set_loci set_schemes set_metadata set_view samples isolates
		  history sequence_attributes);
		push @tables, $self->{'system'}->{'view'}
		  ? $self->{'system'}->{'view'}
		  : 'isolates';
	} elsif ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		@tables =
		  qw(users user_groups user_group_members sequences sequence_refs accession loci schemes scheme_members scheme_fields profiles
		  profile_refs user_permissions client_dbases client_dbase_loci client_dbase_schemes locus_extended_attributes scheme_curators
		  locus_curators locus_descriptions scheme_groups scheme_group_scheme_members scheme_group_group_members client_dbase_loci_fields
		  sets set_loci set_schemes profile_history locus_aliases);
	}
	return @tables;
}

sub get_tables_with_curator {
	my ($self) = @_;
	my @tables;
	if ( $self->{'system'}->{'dbtype'} eq 'isolates' ) {
		@tables =
		  qw(users user_groups user_group_members allele_sequences sequence_bin refs allele_designations pending_allele_designations loci schemes scheme_members
		  locus_aliases scheme_fields composite_fields composite_field_values isolate_aliases projects project_members experiments experiment_sequences
		  isolate_field_extended_attributes isolate_value_extended_attributes scheme_groups scheme_group_scheme_members scheme_group_group_members pcr pcr_locus
		  probes probe_locus accession sequence_flags sequence_attributes);
		push @tables, $self->{'system'}->{'view'}
		  ? $self->{'system'}->{'view'}
		  : 'isolates';
	} elsif ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		@tables = qw(users user_groups sequences profile_refs sequence_refs accession loci schemes
		  scheme_members scheme_fields scheme_groups scheme_group_scheme_members scheme_group_group_members
		  client_dbases client_dbase_loci client_dbase_schemes locus_links locus_descriptions locus_aliases
		  locus_extended_attributes sequence_extended_attributes locus_refs );
	}
	return @tables;
}

sub get_primary_keys {
	my ( $self, $table ) = @_;
	return 'id' if $self->{'system'}->{'dbtype'} eq 'isolates' && $table eq 'isolates';
	my @keys;
	my $attributes = $self->get_table_field_attributes($table);
	foreach (@$attributes) {
		push @keys, $_->{'name'} if $_->{'primary_key'};
	}
	return @keys;
}

sub get_set_metadata {
	my ( $self, $set_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	if ($set_id) {
		return $self->run_list_query( "SELECT metadata_id FROM set_metadata WHERE set_id=?", $set_id );
	} elsif ( $options->{'curate'} ) {
		return $self->{'xmlHandler'}->get_metadata_list;
	}
}

sub get_metadata_value {
	my ( $self, $isolate_id, $metaset, $metafield ) = @_;
	if ( !$self->{'sql'}->{"metadata_value_$metaset"} ) {
		$self->{'sql'}->{"metadata_value_$metaset"} = $self->{'db'}->prepare("SELECT * FROM meta_$metaset WHERE isolate_id = ?");
	}
	eval { $self->{'sql'}->{"metadata_value_$metaset"}->execute($isolate_id) };
	$logger->error($@) if $@;
	my $data = $self->{'sql'}->{"metadata_value_$metaset"}->fetchrow_hashref;
	return $data->{ lc($metafield) } // '';
}

sub materialized_view_exists {
	my ( $self, $scheme_id ) = @_;
	return 0 if ( ( $self->{'system'}->{'materialized_views'} // '' ) ne 'yes' );
	if ( !$self->{'sql'}->{'materialized_view_exists'} ) {
		$self->{'sql'}->{'materialized_view_exists'} = $self->{'db'}->prepare("SELECT EXISTS(SELECT * FROM matviews WHERE mv_name = ?)");
	}
	eval { $self->{'sql'}->{'materialized_view_exists'}->execute("mv_scheme_$scheme_id") };
	$logger->error($@) if $@;
	my ($exists) = $self->{'sql'}->{'materialized_view_exists'}->fetchrow_array;
	return $exists;
}
1;
