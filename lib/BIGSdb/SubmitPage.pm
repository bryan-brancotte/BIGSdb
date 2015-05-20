#Written by Keith Jolley
#Copyright (c) 2015, University of Oxford
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
package BIGSdb::SubmitPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::TreeViewPage BIGSdb::CurateProfileAddPage);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use BIGSdb::Utils;
use BIGSdb::BIGSException;
use BIGSdb::Page 'SEQ_METHODS';
use List::MoreUtils qw(none);
use File::Path qw(make_path remove_tree);
use POSIX;
use constant COVERAGE                 => qw(<20x 20-49x 50-99x >100x);
use constant READ_LENGTH              => qw(<100 100-199 200-299 300-499 >500);
use constant ASSEMBLY                 => ( 'de novo', 'mapped' );
use constant MAX_UPLOAD_SIZE          => 32 * 1024 * 1024;                        #32Mb
use constant SUBMISSIONS_DELETED_DAYS => 90;

sub get_javascript {
	my ($self) = @_;
	my $tree_js = $self->get_tree_javascript( { checkboxes => 1, check_schemes => 1 } );
	my $buffer = << "END";
\$(function () {
	\$("fieldset#scheme_fieldset").css("display","block");
	\$("#filter").click(function() {	
		var fields = ["technology", "assembly", "software", "read_length", "coverage", "locus", "fasta"];
		for (i=0; i<fields.length; i++){
			\$("#" + fields[i]).prop("required",false);
		}

	});	
	\$("#technology").change(function() {	
		check_technology();
	});
	check_technology();
});

function check_technology() {
	var fields = [ "read_length", "coverage"];
	for (i=0; i<fields.length; i++){
		if (\$("#technology").val() == 'Illumina'){			
			\$("#" + fields[i]).prop("required",true);
			\$("#" + fields[i] + "_label").text((fields[i]+":!").replace("_", " "));	
		} else {
			\$("#" + fields[i]).prop("required",false);
			\$("#" + fields[i] + "_label").text((fields[i]+":").replace("_", " "));
		}
	}	
}
$tree_js
END
	return $buffer;
}

sub initiate {
	my ($self)        = @_;
	my $q             = $self->{'cgi'};
	my $submission_id = $q->param('submission_id');
	if ( $q->param('tar') && $q->param('submission_id') ) {
		$self->{'type'}       = 'tar';
		$self->{'attachment'} = "$submission_id\.tar";
		$self->{'noCache'}    = 1;
		return;
	}
	$self->{$_} = 1 foreach qw (jQuery jQuery.jstree noCache);
	return;
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	$self->choose_set;
	my $submission_id = $q->param('submission_id');
	if ($submission_id) {
		my %return_after = map { $_ => 1 } qw (tar view curate);
		foreach my $action (qw (abort finalize close remove tar view curate)) {
			if ( $q->param($action) ) {
				my $method = "_$action\_submission";
				$self->$method($submission_id);
				return if $return_after{$action};
				last;
			}
		}
	}
	say q(<h1>Manage submissions</h1>);
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	if ( !$user_info ) {
		say q(<div class="box" id="statusbad"><p>You are not a recognized user.  Submissions are disabled.</p></div>);
		return;
	}
	foreach my $type (qw (alleles profiles)) {
		if ( $q->param($type) ) {
			my $method = "_handle_$type";
			$self->$method;
			return;
		}
	}
	$self->_delete_old_closed_submissions;
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	if ( !$self->_print_started_submissions ) {    #Returns true if submissions in process
		$self->_print_new_submission_links;
	}
	$self->_print_pending_submissions;
	$self->print_submissions_for_curation;
	$self->_print_closed_submissions;
	say qq(<p style="margin-top:1em"><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}">)
	  . q(Return to index page</a></p>);
	say q(</div></div>);
	return;
}

sub _handle_alleles {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $self->{'system'}->{'dbtype'} ne 'sequences' ) {
		say q(<div class="box" id="statusbad"><p>You cannot submit new allele sequences for definition in an )
		  . q(isolate database.<p></div>);
		return;
	}
	if ( $q->param('submit') ) {
		$self->_update_allele_prefs;
	}
	$self->_submit_alleles;
	return;
}

sub _handle_profiles {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $self->{'system'}->{'dbtype'} ne 'sequences' ) {
		say q(<div class="box" id="statusbad"><p>You cannot submit new profiles for definition in an )
		  . q(isolate database.<p></div>);
		return;
	}
	$self->_submit_profiles;
	return;
}

sub _print_new_submission_links {
	my ($self) = @_;
	say q(<h2>Submit new data</h2>);
	say q(<p>Data submitted here will go in to a queue for handling by a curator or by an automated script. You )
	  . q(will be able to track the status of any submission.</p>);
	say q(<h3>Submission type:</h3>);
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		say q(<ul>);
		say qq(<li><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
		  . q(alleles=1">alleles</a></li>);

		#Don't allow profile submissions by default - normally new isolate data should be submitted and they
		#can be extracted from those records.  This ensures that every new profile has accompanying isolate data.
		if ( ( $self->{'system'}->{'profile_submissions'} // '' ) eq 'yes' ) {
			my $set_id = $self->get_set_id;
			my $schemes = $self->{'datastore'}->get_scheme_list( { with_pk => 1, set_id => $set_id } );
			foreach my $scheme (@$schemes) {
				say qq(<li><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit)
				  . qq(&amp;profiles=1&amp;scheme_id=$scheme->{'id'}">$scheme->{'description'} profiles</a></li>);
			}
		}
		say q(</ul>);
	}
	return;
}

sub _delete_old_closed_submissions {
	my ($self) = @_;
	my $days = $self->{'system'}->{'submissions_deleted_days'} // $self->{'config'}->{'submissions_deleted_days'}
	  // SUBMISSIONS_DELETED_DAYS;
	$days = SUBMISSIONS_DELETED_DAYS if !BIGSdb::Utils::is_int($days);
	my $submissions =
	  $self->{'datastore'}
	  ->run_query( qq(SELECT id FROM submissions WHERE status=? AND datestamp<now()-interval '$days days'),
		'closed', { fetch => 'col_arrayref' } );
	foreach my $submission_id (@$submissions) {
		$self->_delete_submission($submission_id);
	}
	return;
}

sub _delete_submission {
	my ( $self, $submission_id ) = @_;
	eval { $self->{'db'}->do( 'DELETE FROM submissions WHERE id=?', undef, $submission_id ) };
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
		$self->_delete_submission_files($submission_id);
	}
	return;
}

sub _get_submissions_by_status {
	my ( $self, $status, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	my ( $qry, $get_all, @args );
	if ( $options->{'get_all'} ) {
		$qry     = 'SELECT * FROM submissions WHERE status=? ORDER BY datestamp desc';
		$get_all = 1;
		push @args, $status;
	} else {
		$qry     = 'SELECT * FROM submissions WHERE (submitter,status)=(?,?) ORDER BY datestamp desc';
		$get_all = 0;
		push @args, ( $user_info->{'id'}, $status );
	}
	my $submissions =
	  $self->{'datastore'}->run_query( $qry, \@args,
		{ fetch => 'all_arrayref', slice => {}, cache => "SubmitPage::get_submissions_by_status$get_all" } );
	return $submissions;
}

sub _print_started_submissions {
	my ($self) = @_;
	my $incomplete = $self->_get_submissions_by_status('started');
	if (@$incomplete) {
		say q(<h2>Submission in process</h2>);
		say q(<p>Please note that you must either proceed with or abort the in process submission before you can )
		  . q(start another.</p>);
		foreach my $submission (@$incomplete) { #There should only be one but this isn't enforced at the database level.
			say qq(<dl class="data"><dt>Submission</dt><dd>$submission->{'id'}</dd>);
			say qq(<dt>Datestamp</dt><dd>$submission->{'datestamp'}</dd>);
			say qq(<dt>Type</dt><dd>$submission->{'type'}</dd>);
			if ( $submission->{'type'} eq 'alleles' ) {
				my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
				if ($allele_submission) {
					say qq(<dt>Locus</dt><dd>$allele_submission->{'locus'}</dd>);
					my $seq_count = @{ $allele_submission->{'seqs'} };
					say qq(<dt>Sequences</dt><dd>$seq_count</dd>);
				}
			} elsif ( $submission->{'type'} eq 'profiles' ) {
				my $profile_submission = $self->get_profile_submission( $submission->{'id'} );
				if ($profile_submission) {
					my $scheme_id   = $profile_submission->{'scheme_id'};
					my $set_id      = $self->get_set_id;
					my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { set_id => $set_id } );
					say qq(<dt>Scheme</dt><dd>$scheme_info->{'description'}</dd>);
					my $profile_count = @{ $profile_submission->{'profiles'} };
					say qq(<dt>Profiles</dt><dd>$profile_count</dd>);

					#					use Data::Dumper;
					#					$logger->error( Dumper $profile_submission);
				}
			}
			say qq(<dt>Action</dt><dd><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;)
			  . qq(page=submit&amp;$submission->{'type'}=1&amp;abort=1&amp;no_check=1">Abort</a> | )
			  . qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
			  . qq($submission->{'type'}=1&amp;continue=1">Continue</a>);
			say q(</dl>);
		}
		return 1;
	}
	return;
}

sub _get_own_submissions {
	my ( $self, $status, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $submissions = $self->_get_submissions_by_status( $status, { get_all => 0 } );
	my $buffer;
	if (@$submissions) {
		$buffer .= q(<table class="resultstable"><tr><th>Submission id</th><th>Submitted</th><th>Updated</th>)
		  . q(<th>Type</th><th>Details</th>);
		$buffer .= q(<th>Outcome</th>) if $options->{'show_outcome'};
		$buffer .= q(<th>Remove</th>)  if $options->{'allow_remove'};
		$buffer .= q(</tr>);
		my $td = 1;
		foreach my $submission (@$submissions) {
			my $url = qq($self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
			  . qq(submission_id=$submission->{'id'}&amp;view=1);
			$buffer .=
			    qq(<tr class="td$td"><td><a href="$url">$submission->{'id'}</a></td>)
			  . qq(<td>$submission->{'date_submitted'}</td><td>$submission->{'datestamp'}</td>)
			  . qq(<td>$submission->{'type'}</td>);
			my $details = '';
			my ( $all_assigned, $all_rejected ) = ( 1, 1 );
			if ( $submission->{'type'} eq 'alleles' ) {
				my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
				my $allele_count      = @{ $allele_submission->{'seqs'} };
				my $plural            = $allele_count == 1 ? '' : 's';
				$details = "$allele_count $allele_submission->{'locus'} sequence$plural";
				foreach my $seq ( @{ $allele_submission->{'seqs'} } ) {
					$all_assigned = 0 if $seq->{'status'} ne 'assigned';
					$all_rejected = 0 if $seq->{'status'} ne 'rejected';
				}
			}
			$buffer .= qq(<td>$details</td>);
			if ( $options->{'show_outcome'} ) {
				if ($all_assigned) {
					$buffer .= q(<td><span class="fa fa-lg fa-smile-o" style="color:green"></span></td>);
				} elsif ($all_rejected) {
					$buffer .= q(<td><span class="fa fa-lg fa-frown-o" style="color:red"></span></td>);
				} else {
					$buffer .= q(<td><span class="fa fa-lg fa-meh-o" style="color:blue"></span></td>);
				}
			}
			if ( $options->{'allow_remove'} ) {
				$buffer .=
				    qq(<td><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;)
				  . qq(page=submit&amp;submission_id=$submission->{'id'}&amp;remove=1">)
				  . q(<span class="fa fa-lg fa-remove"></span></a></td>);
			}
			$buffer .= q(</tr>);
			$td = $td == 1 ? 2 : 1;
		}
		$buffer .= q(</table>);
	}
	return $buffer;
}

sub _print_pending_submissions {
	my ($self) = @_;
	my $buffer = $self->_get_own_submissions('pending');
	if ($buffer) {
		say q(<h2>Pending submissions</h2>);
		say q(<p>You have submitted the following submissions that are pending curation:</p>);
		say $buffer;
	}
	return;
}

sub print_submissions_for_curation {
	my ( $self, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	return if !$user_info || ( $user_info->{'status'} ne 'admin' && $user_info->{'status'} ne 'curator' );
	my $buffer;
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		$buffer .= $self->_get_allele_submissions_for_curation;
	}
	return $buffer if $options->{'get_only'};
	say $buffer if $buffer;
	return;
}

sub _get_allele_submissions_for_curation {
	my ($self) = @_;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	my $submissions = $self->_get_submissions_by_status( 'pending', { get_all => 1 } );
	my $buffer;
	my $td = 1;
	foreach my $submission (@$submissions) {
		next if $submission->{'type'} ne 'alleles';
		my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
		next
		  if !($self->is_admin
			|| $self->{'datastore'}
			->is_allowed_to_modify_locus_sequences( $allele_submission->{'locus'}, $user_info->{'id'} ) );
		my $submitter_string = $self->{'datastore'}->get_user_string( $submission->{'submitter'}, { email => 1 } );
		my $row =
		    qq(<tr class="td$td"><td><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;)
		  . qq(page=submit&amp;submission_id=$submission->{'id'}&amp;curate=1">$submission->{'id'}</a></td>)
		  . qq(<td>$submission->{'date_submitted'}</td><td>$submission->{'datestamp'}</td><td>$submitter_string</td>)
		  . qq(<td>$allele_submission->{'locus'}</td>);
		my $seq_count = @{ $allele_submission->{'seqs'} };
		$row .= qq(<td>$seq_count</td></tr>\n);
		$td = $td == 1 ? 2 : 1;
		$buffer .= $row;
	}
	my $return_buffer = '';
	if ($buffer) {
		$return_buffer .= qq(<h2>New allele sequence submissions waiting for curation</h2>\n);
		$return_buffer .= qq(<p>Your account is authorized to handle the following submissions:<p>\n);
		$return_buffer .= q(<table class="resultstable"><tr><th>Submission id</th><th>Submitted</th><th>Updated</th>)
		  . qq(<th>Submitter</th><th>Locus</th><th>Sequences</th></tr>\n);
		$return_buffer .= $buffer;
		$return_buffer .= qq(</table>\n);
	}
	return $return_buffer;
}

sub _print_closed_submissions {
	my ($self) = @_;
	my $buffer = $self->_get_own_submissions( 'closed', { show_outcome => 1, allow_remove => 1 } );
	if ($buffer) {
		say q(<h2>Recently closed submissions</h2>);
		say q(<p>You have submitted the following submissions which are now closed:</p>);
		say $buffer;
	}
	return;
}

sub _print_allele_warnings {
	my ( $self, $warnings ) = @_;
	return if ref $warnings ne 'ARRAY' || !@$warnings;
	my @info = @$warnings;
	local $" = q(<br />);
	my $plural = @info == 1 ? '' : 's';
	say qq(<div class="box" id="statuswarn"><h2>Warning$plural:</h2><p>@info</p><p>Warnings do not prevent submission )
	  . q(but may result in the submission being rejected depending on curation criteria.</p></div>);
	return;
}

sub _abort_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	return if !$self->{'cgi'}->param('confirm');
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	my $submission =
	  $self->{'datastore'}
	  ->run_query( 'SELECT id FROM submissions WHERE (id,submitter)=(?,?)', [ $submission_id, $user_info->{'id'} ] );
	$self->_delete_submission($submission_id) if $submission_id;
	return;
}

sub _delete_submission_files {
	my ( $self, $submission_id ) = @_;
	my $dir = $self->_get_submission_dir($submission_id);
	if ( $dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+$)/x ) {
		remove_tree $1;
	}
	return;
}

sub _delete_selected_submission_files {
	my ( $self, $submission_id ) = @_;
	my $q     = $self->{'cgi'};
	my $files = $self->_get_submission_files($submission_id);
	my $i     = 0;
	my $dir   = $self->_get_submission_dir($submission_id) . '/supporting_files';
	foreach my $file (@$files) {
		if ( $q->param("file$i") ) {
			if ( $file->{'filename'} =~ /^([^\/]+)$/x ) {
				my $filename = $1;
				unlink "$dir/$filename" || $logger->error("Cannot delete $dir/$filename.");
			}
			$q->delete("file$i");
		}
		$i++;
	}
	return;
}

sub _finalize_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	my $q          = $self->{'cgi'};
	my $submission = $self->_get_submission($submission_id);
	return if !$submission;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	eval {
		if ( $submission->{'type'} eq 'alleles' )
		{
			$self->{'db'}->do(
				'UPDATE allele_submissions SET (technology,read_length,coverage,assembly,software)=(?,?,?,?,?) '
				  . 'WHERE submission_id=? AND submission_id IN (SELECT id FROM submissions WHERE submitter=?)',
				undef,
				$q->param('technology'),
				$q->param('read_length'),
				$q->param('coverage'),
				$q->param('assembly'),
				$q->param('software'),
				$submission_id,
				$user_info->{'id'}
			);
		}
		$self->{'db'}->do( 'UPDATE submissions SET (status,datestamp)=(?,?) WHERE (id,submitter)=(?,?)',
			undef, 'pending', 'now', $submission_id, $user_info->{'id'} );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _submit_alleles {
	my ($self)        = @_;
	my $q             = $self->{'cgi'};
	my $submission_id = $self->_get_started_submission_id;
	$q->param( submission_id => $submission_id );
	my $ret;
	if ($submission_id) {
		my $allele_submission = $self->get_allele_submission($submission_id);
		my $fasta_string;
		foreach my $seq ( @{ $allele_submission->{'seqs'} } ) {
			$fasta_string .= ">$seq->{'seq_id'}\n";
			$fasta_string .= "$seq->{'sequence'}\n";
		}
		if ( !$q->param('no_check') ) {
			$ret = $self->{'datastore'}->check_new_alleles_fasta( $allele_submission->{'locus'}, \$fasta_string );
			$self->_print_allele_warnings( $ret->{'info'} );
		}
		$self->_presubmit_alleles( $submission_id, undef );
		return;
	} elsif ( $q->param('submit') || $q->param('continue') || $q->param('abort') ) {
		$ret = $self->_check_new_alleles;
		if ( $ret->{'err'} ) {
			my @err = @{ $ret->{'err'} };
			local $" = '<br />';
			my $plural = @err == 1 ? '' : 's';
			say qq(<div class="box" id="statusbad"><h2>Error$plural:</h2><p>@err</p></div>);
		} else {
			if ( $ret->{'info'} ) {
				$self->_print_allele_warnings( $ret->{'info'} );
			}
			$self->_presubmit_alleles( undef, $ret->{'seqs'} );
			return;
		}
	}
	say q(<div class="box" id="queryform"><div class="scrollable">);
	say q(<h2>Submit new alleles</h2>);
	say q(<p>You need to make a separate submission for each locus for which you have new alleles - this is because )
	  . q(different loci may have different curators.  You can submit any number of new sequences for a single locus )
	  . q(as one submission. Sequences should be trimmed to the correct start/end sites for the selected locus.</p>);
	my $set_id = $self->get_set_id;
	my ( $loci, $labels );
	say $q->start_form;
	my $schemes =
	  $self->{'datastore'}
	  ->run_query( 'SELECT id FROM schemes ORDER BY display_order,description', undef, { fetch => 'col_arrayref' } );

	if ( @$schemes > 1 ) {
		say q(<fieldset id="scheme_fieldset" style="float:left;display:none"><legend>Filter loci by scheme</legend>);
		say q(<div id="tree" class="scheme_tree" style="float:left;max-height:initial">);
		say $self->get_tree( undef, { no_link_out => 1, select_schemes => 1 } );
		say q(</div>);
		say $q->submit( -name => 'filter', -id => 'filter', -label => 'Filter', -class => 'submit' );
		say q(</fieldset>);
		my @selected_schemes;
		foreach ( @$schemes, 0 ) {
			push @selected_schemes, $_ if $q->param("s_$_");
		}
		my $scheme_loci = @selected_schemes ? $self->_get_scheme_loci( \@selected_schemes ) : undef;
		( $loci, $labels ) =
		  $self->{'datastore'}->get_locus_list( { only_include => $scheme_loci, set_id => $set_id } );
	} else {
		( $loci, $labels ) = $self->{'datastore'}->get_locus_list( { set_id => $set_id } );
	}
	say q(<fieldset style="float:left"><legend>Select locus</legend>);
	say $q->popup_menu(
		-name     => 'locus',
		-id       => 'locus',
		-values   => $loci,
		-labels   => $labels,
		-size     => 9,
		-required => 'required'
	);
	say q(</fieldset>);
	$self->_print_sequence_details_fieldset($submission_id);
	say q(<fieldset style="float:left"><legend>FASTA or single sequence</legend>);
	say $q->textarea( -name => 'fasta', -cols => 30, -rows => 5, -id => 'fasta', -required => 'required' );
	say q(</fieldset>);
	say $q->hidden($_) foreach qw(db page alleles);
	$self->print_action_fieldset( { no_reset => 1 } );
	say $q->end_form;
	say q(</div></div>);
	return;
}

sub _submit_profiles {
	my ($self)        = @_;
	my $q             = $self->{'cgi'};
	my $submission_id = $self->_get_started_submission_id;
	$q->param( submission_id => $submission_id );
	my $ret;
	if ($submission_id) {
		$self->_presubmit_profiles( $submission_id, undef );
		return;
	} elsif ( ( $q->param('submit') && $q->param('data') ) || $q->param('continue') || $q->param('abort') ) {
		my $scheme_id = $q->param('scheme_id');
		$ret = $self->_check_new_profiles( $scheme_id, \$q->param('data') );
		if ( $ret->{'err'} ) {
			my $err = $ret->{'err'};
			local $" = '<br />';
			my $plural = @$err == 1 ? '' : 's';
			say qq(<div class="box" id="statusbad"><h2>Error$plural:</h2><p>@$err</p></div>);
		} else {
			$self->_presubmit_profiles( undef, $ret->{'profiles'} );
			return;
		}
	}
	my $scheme_id   = $q->param('scheme_id');
	my $set_id      = $self->get_set_id;
	my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { get_pk => 1, set_id => $set_id } );
	if ( !$scheme_info || !$scheme_info->{'primary_key'} ) {
		say q(<div class="box" id="statusbad"><p>Invalid scheme passed.</p></div>);
	}
	say q(<div class="box" id="queryform"><div class="scrollable">);
	say qq(<h2>Submit new $scheme_info->{'description'} profiles</h2>);
	say q(<p>Paste in your profiles for assignment using the template available below.</p>);
	say qq(<ul><li><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=tableHeader&amp;)
	  . qq(table=profiles&amp;scheme_id=$scheme_id&amp;no_fields=1&amp;id_field=1">Download tab-delimited )
	  . q(header for your spreadsheet</a> - use 'Paste Special <span class="fa fa-arrow-circle-right"></span> Text' )
	  . q(to paste the data.</li>);
	say qq[<li><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=excelTemplate&amp;]
	  . qq[table=profiles&amp;scheme_id=$scheme_id&amp;no_fields=1&amp;id_field=1">Download submission template ]
	  . q[(xlsx format)</a></li></ul>];
	say $q->start_form;
	say q[<fieldset style="float:left"><legend>Please paste in tab-delimited text <b>(include a field header line)</b>]
	  . q(</legend>);
	say $q->textarea( -name => 'data', -rows => 20, -columns => 80, -required => 'required' );
	say q(</fieldset>);
	say $q->hidden($_) foreach qw(db page profiles scheme_id);
	$self->print_action_fieldset( { no_reset => 1 } );
	say $q->end_form;
	say q(</div></div>);
	return;
}

sub _print_sequence_details_fieldset {
	my ( $self, $submission_id ) = @_;
	my $q = $self->{'cgi'};
	say q(<fieldset style="float:left"><legend>Sequence details</legend>);
	say q(<ul><li><label for="technology" class="parameter">technology:!</label>);
	my $allele_submission = $submission_id ? $self->get_allele_submission($submission_id) : undef;
	my $att_labels = { '' => ' ' };    #Required for HTML5 validation
	say $q->popup_menu(
		-name     => 'technology',
		-id       => 'technology',
		-values   => [ '', SEQ_METHODS ],
		-labels   => $att_labels,
		-required => 'required',
		-default  => $allele_submission->{'technology'} // $self->{'prefs'}->{'submit_allele_technology'}
	);
	say q(<li><label for="read_length" id="read_length_label" class="parameter">read length:</label>);
	say $q->popup_menu(
		-name    => 'read_length',
		-id      => 'read_length',
		-values  => [ '', READ_LENGTH ],
		-labels  => $att_labels,
		-default => $allele_submission->{'read_length'} // $self->{'prefs'}->{'submit_allele_read_length'}
	);
	say q(</li><li><label for="coverage" id="coverage_label" class="parameter">coverage:</label>);
	say $q->popup_menu(
		-name    => 'coverage',
		-id      => 'coverage',
		-values  => [ '', COVERAGE ],
		-labels  => $att_labels,
		-default => $allele_submission->{'coverage'} // $self->{'prefs'}->{'submit_allele_coverage'}
	);
	say q(</li><li><label for="assembly" class="parameter">assembly:!</label>);
	say $q->popup_menu(
		-name     => 'assembly',
		-id       => 'assembly',
		-values   => [ '', ASSEMBLY ],
		-labels   => $att_labels,
		-required => 'required',
		-default  => $allele_submission->{'assembly'} // $self->{'prefs'}->{'submit_allele_assembly'}
	);
	say q(</li><li><label for="software" class="parameter">assembly software:!</label>);
	say $q->textfield(
		-name     => 'software',
		-id       => 'software',
		-required => 'required',
		-default  => $allele_submission->{'software'} // $self->{'prefs'}->{'submit_allele_software'}
	);
	say q(</li></ul>);
	say q(</fieldset>);
	return;
}

sub _check_new_alleles {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $locus  = $q->param('locus');
	if ( !$locus ) {
		return { err => ['No locus is selected.'] };
	}
	$locus =~ s/^cn_//x;
	$q->param( locus => $locus );
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	if ( !$locus_info ) {
		return { err => ['Locus $locus is not recognized.'] };
	}
	if ( $q->param('fasta') ) {
		my $fasta_string = $q->param('fasta');
		$fasta_string = ">seq\n$fasta_string" if $fasta_string !~ /^\s*>/x;
		return $self->{'datastore'}->check_new_alleles_fasta( $locus, \$fasta_string );
	}
	return;
}

sub _check_new_profiles {
	my ( $self, $scheme_id, $profiles_csv_ref ) = @_;
	my @err;
	my @profiles;
	my @rows          = split /\n/x, $$profiles_csv_ref;
	my $header_row    = shift @rows;
	my $header_status = $self->_get_profile_header_positions( $header_row, $scheme_id );
	my $positions     = $header_status->{'positions'};
	my %field_by_pos  = reverse %$positions;
	my %err_message =
	  ( missing => 'The header is missing a column for', duplicates => 'The header has duplicate columns for' );

	foreach my $status (qw(missing duplicates)) {
		if ( $header_status->{$status} ) {
			my $list = $header_status->{$status};
			my $plural = @$list == 1 ? 'us' : 'i';
			local $" = q(, );
			push @err, "$err_message{$status} loc$plural: @$list.";
		}
	}
	my $scheme = $self->{'datastore'}->get_scheme($scheme_id);
	if ( !@err ) {
		my $loci        = $self->{'datastore'}->get_scheme_loci($scheme_id);
		my $scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { get_pk => 1 } );
		my $row_number  = 1;
		my %id_exists;
		foreach my $row (@rows) {
			$row =~ s/\s*$//x;
			next if !$row;
			my @values = split /\t/x, $row;
			my $row_id =
			  defined $positions->{'id'} ? ( $values[ $positions->{'id'} ] || "Row $row_number" ) : "Row $row_number";
			$id_exists{$row_id}++;
			push @err, "$row_id: Identifier exists more than once in submission." if $id_exists{$row_id} == 2;
			my $locus_count  = @$loci;
			my $value_count  = @values;
			my $plural       = $value_count == 1 ? '' : 's';
			my $designations = {};

			for my $i ( 0 .. @values - 1 ) {
				$values[$i] //= '';
				$values[$i] =~ s/^\s*//x;
				$values[$i] =~ s/\s*$//x;
				next if !$field_by_pos{$i} || $field_by_pos{$i} eq 'id';
				if ( $values[$i] eq q(N) && !$scheme_info->{'allow_missing_loci'} ) {
					push @err, "$row_id: Arbitrary values (N) are not allowed for locus $field_by_pos{$i}.";
				} elsif ( $values[$i] eq q() ) {
					push @err, "$row_id: No value for locus $field_by_pos{$i}.";
				} else {
					my $allele_exists = $self->{'datastore'}->sequence_exists( $field_by_pos{$i}, $values[$i] );
					push @err, "$row_id: $field_by_pos{$i}:$values[$i] has not been defined." if !$allele_exists;
					$designations->{ $field_by_pos{$i} } = $values[$i];
				}
			}
			my $pk = $scheme_info->{'primary_key'};
			my ( $profile_exists, $msg ) = $self->{'datastore'}->check_new_profile( $scheme_id, $designations );
			push @err, "$row_id: $msg" if $profile_exists;
			push @profiles, { id => $row_id, %$designations };
			$row_number++;
		}
	}
	my $ret = { profiles => \@profiles };
	$ret->{'err'} = \@err if @err;
	return $ret;
}

sub _get_profile_header_positions {
	my ( $self, $header_row, $scheme_id ) = @_;
	$header_row =~ s/\s*$//x;
	my ( @missing, @duplicates, %positions );
	my $loci   = $self->{'datastore'}->get_scheme_loci($scheme_id);
	my @header = split /\t/x, $header_row;
	my $set_id = $self->get_set_id;
	foreach my $locus (@$loci) {
		for my $i ( 0 .. @header - 1 ) {
			$header[$i] =~ s/\s//gx;
			$header[$i] = $self->{'datastore'}->get_set_locus_real_id( $header[$i], $set_id ) if $set_id;
			if ( $locus eq $header[$i] ) {
				push @duplicates, $locus if defined $positions{$locus};
				$positions{$locus} = $i;
			}
		}
	}
	for my $i ( 0 .. @header - 1 ) {
		$positions{'id'} = $i if ( $header[$i] eq 'id' );
	}
	foreach my $locus (@$loci) {
		push @missing, $locus if !defined $positions{$locus};
	}
	my $ret = { positions => \%positions };
	$ret->{'missing'}    = \@missing    if @missing;
	$ret->{'duplicates'} = \@duplicates if @duplicates;
	return $ret;
}

sub _start_submission {
	my ( $self, $type ) = @_;
	$logger->logdie("Invalid submission type '$type'") if none { $type eq $_ } qw (alleles profiles);
	my $submission_id = 'BIGSdb_' . strftime( '%Y%m%d%H%M%S', localtime ) . "_$$\_" . int( rand(99999) );
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	eval {
		$self->{'db'}
		  ->do( 'INSERT INTO submissions (id,type,submitter,date_submitted,datestamp,status) VALUES (?,?,?,?,?,?)',
			undef, $submission_id, $type, $user_info->{'id'}, 'now', 'now', 'started' );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return $submission_id;
}

sub _get_started_submission_id {
	my ($self) = @_;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	return $self->{'datastore'}->run_query(
		'SELECT id FROM submissions WHERE (submitter,status)=(?,?)',
		[ $user_info->{'id'}, 'started' ],
		{ cache => 'SubmitPage::get_started_submission' }
	);
}

sub _get_submission {
	my ( $self, $submission_id ) = @_;
	$logger->logcarp('No submission_id passed') if !$submission_id;
	return $self->{'datastore'}->run_query( 'SELECT * FROM submissions WHERE id=?',
		$submission_id, { fetch => 'row_hashref', cache => 'SubmitPage::get_submission' } );
}

sub get_allele_submission {
	my ( $self, $submission_id ) = @_;
	$logger->logcarp('No submission_id passed') if !$submission_id;
	my $submission = $self->{'datastore'}->run_query( 'SELECT * FROM allele_submissions WHERE submission_id=?',
		$submission_id, { fetch => 'row_hashref', cache => 'SubmitPage::get_allele_submission' } );
	return if !$submission;
	my $seq_data =
	  $self->{'datastore'}
	  ->run_query( 'SELECT * FROM allele_submission_sequences WHERE submission_id=? ORDER BY seq_id',
		$submission_id,
		{ fetch => 'all_arrayref', slice => {}, cache => 'SubmitPage::get_allele_submission::sequences' } );
	$submission->{'seqs'} = $seq_data;
	return $submission;
}

sub get_profile_submission {
	my ( $self, $submission_id ) = @_;
	$logger->logcarp('No submission_id passed') if !$submission_id;
	my $submission = $self->{'datastore'}->run_query( 'SELECT * FROM profile_submissions WHERE submission_id=?',
		$submission_id, { fetch => 'row_hashref', cache => 'SubmitPage::get_profile_submission' } );
	return if !$submission;
	my $profiles =
	  $self->{'datastore'}
	  ->run_query( 'SELECT profile_id,status,assigned_id FROM profile_submission_profiles WHERE submission_id=?',
		$submission_id,
		{ fetch => 'all_arrayref', slice => {}, cache => 'SubmitPage::get_profile_submission::profiles' } );
	$submission->{'profiles'} = [];
	foreach my $profile (@$profiles) {
		my $designations = $self->{'datastore'}->run_query(
			'SELECT locus,allele_id FROM '
			  . 'profile_submission_designations WHERE (submission_id,profile_id)=(?,?) ORDER BY locus',
			[ $submission_id, $profile->{'profile_id'} ],
			{ fetch => 'all_arrayref', slice => {}, cache => 'SubmitPage::get_profile_submission::designations' }
		);
		$profile->{'designations'}->{ $_->{'locus'} } = $_->{'allele_id'} foreach @$designations;
		push @{ $submission->{'profiles'} }, $profile;
	}
	return $submission;
}

sub _start_allele_submission {
	my ( $self, $submission_id, $locus, $seqs ) = @_;
	my $q = $self->{'cgi'};
	eval {
		$self->{'db'}->do(
			'INSERT INTO allele_submissions (submission_id,locus,technology,read_length,coverage,assembly,'
			  . 'software) VALUES (?,?,?,?,?,?,?)',
			undef,
			$submission_id,
			$locus,
			$q->param('technology'),
			$q->param('read_length'),
			$q->param('coverage'),
			$q->param('assembly'),
			$q->param('software'),
		);
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
		return;
	}
	if (@$seqs) {
		my $insert_sql =
		  $self->{'db'}
		  ->prepare('INSERT INTO allele_submission_sequences (submission_id,seq_id,sequence,status) VALUES (?,?,?,?)');
		foreach my $seq (@$seqs) {
			eval { $insert_sql->execute( $submission_id, $seq->{'seq_id'}, $seq->{'sequence'}, 'pending' ) };
			if ($@) {
				$logger->error($@);
				$self->{'db'}->rollback;
				return;
			}
		}
		$self->_write_allele_FASTA($submission_id);
	}
	$self->{'db'}->commit;
	return;
}

sub _start_profile_submission {
	my ( $self, $submission_id, $scheme_id, $profiles ) = @_;
	my $q = $self->{'cgi'};
	eval {
		$self->{'db'}->do( 'INSERT INTO profile_submissions (submission_id,scheme_id) VALUES (?,?)',
			undef, $submission_id, $scheme_id, );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
		return;
	}
	my $loci = $self->{'datastore'}->get_scheme_loci($scheme_id);
	if (@$profiles) {
		foreach my $profile (@$profiles) {
			eval {
				$self->{'db'}
				  ->do( 'INSERT INTO profile_submission_profiles (submission_id,profile_id,status) VALUES (?,?,?)',
					undef, $submission_id, $profile->{'id'}, 'pending' );
				foreach my $locus (@$loci) {
					$self->{'db'}->do(
						'INSERT INTO profile_submission_designations (submission_id,profile_id,locus,'
						  . 'allele_id) VALUES (?,?,?,?)',
						undef, $submission_id, $profile->{'id'}, $locus, $profile->{$locus}
					);
				}
			};
			if ($@) {
				$logger->error($@);
				$self->{'db'}->rollback;
				return;
			}
		}

		#		$self->_write_allele_FASTA($submission_id);
	}
	$self->{'db'}->commit;
	return;
}

sub _print_abort_form {
	my ( $self, $submission_id ) = @_;
	my $q = $self->{'cgi'};
	say q(<div style="float:left">);
	$self->print_warning_sign( { no_div => 1 } );
	say q(</div>);
	say $q->start_form;
	$self->print_action_fieldset( { no_reset => 1, submit_label => 'Abort submission!' } );
	$q->param( confirm       => 1 );
	$q->param( submission_id => $submission_id );
	say $q->hidden($_) foreach qw(db page submission_id abort confirm);
	say $q->end_form;
	return;
}

sub _print_file_upload_fieldset {
	my ( $self, $submission_id ) = @_;
	my $q = $self->{'cgi'};
	say q(<fieldset style="float:left"><legend>Supporting files</legend>);
	say q(<p>Please upload any supporting files required for curation.  Ensure that these are named unambiguously or )
	  . q(add an explanatory note so that they can be linked to the appropriate sequence.  Individual filesize is )
	  . q(limited to )
	  . BIGSdb::Utils::get_nice_size(MAX_UPLOAD_SIZE)
	  . q(.</p>);
	say $q->start_form;
	print $q->filefield( -name => 'file_upload', -id => 'file_upload', -multiple );
	say $q->submit(
		-name  => 'Upload files',
		-class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all'
	);
	$q->param( no_check => 1 );
	say $q->hidden($_) foreach qw(db page alleles profiles locus submit submission_id no_check);
	say $q->end_form;
	my $files = $self->_get_submission_files($submission_id);

	if (@$files) {
		say $q->start_form;
		$self->_print_submission_file_table( $submission_id, { delete_checkbox => 1 } );
		$q->param( delete => 1 );
		say $q->hidden($_) foreach qw(db page alleles profiles delete no_check);
		say $q->submit(
			-label => 'Delete selected files',
			-class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all'
		);
		say $q->end_form;
	}
	say q(</fieldset>);
	return;
}

sub _presubmit_alleles {
	my ( $self, $submission_id, $seqs ) = @_;
	$seqs //= [];
	return if !$submission_id && !@$seqs;
	my $q = $self->{'cgi'};
	my $locus;
	if ($submission_id) {
		my $allele_submission = $self->get_allele_submission($submission_id);
		$locus = $allele_submission->{'locus'} // '';
		$seqs  = $allele_submission->{'seqs'}  // [];
	} else {
		$locus         = $q->param('locus');
		$submission_id = $self->_start_submission('alleles');
		$self->_start_allele_submission( $submission_id, $locus, $seqs );
	}
	if ( $q->param('file_upload') ) {
		$self->_upload_files($submission_id);
	}
	if ( $q->param('delete') ) {
		$self->_delete_selected_submission_files($submission_id);
	}
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	if ( $q->param('abort') ) {
		$self->_print_abort_form($submission_id);
	}
	say qq(<h2>Submission: $submission_id</h2>);
	$self->_print_sequence_table_fieldset( $submission_id, { download_link => 1 } );
	$self->_print_finalize_form;
	say $q->start_form;
	$self->_print_sequence_details_fieldset($submission_id);
	$self->print_action_fieldset( { no_reset => 1, submit_label => 'Finalize submission!' } );
	$q->param( finalize      => 1 );
	$q->param( submission_id => $submission_id );
	say $q->hidden($_) foreach qw(db page locus submit finalize submission_id);
	say $q->end_form;
	$self->_print_file_upload_fieldset($submission_id);
	$self->_print_message_fieldset($submission_id);
	say q(</div></div>);
	return;
}

sub _presubmit_profiles {
	my ( $self, $submission_id, $profiles ) = @_;
	$profiles //= [];
	return if !$submission_id && !@$profiles;
	my $scheme_id;
	my $q = $self->{'cgi'};
	if ($submission_id) {
		my $profile_submission = $self->get_profile_submission($submission_id);
		$profiles = $profile_submission->{'profiles'} // [];
	} else {
		$scheme_id     = $q->param('scheme_id');
		$submission_id = $self->_start_submission('profiles');
		$self->_start_profile_submission( $submission_id, $scheme_id, $profiles );
	}
	if ( $q->param('file_upload') ) {
		$self->_upload_files($submission_id);
	}
	if ( $q->param('delete') ) {
		$self->_delete_selected_submission_files($submission_id);
	}
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	if ( $q->param('abort') ) {
		$self->_print_abort_form($submission_id);
	}
	say qq(<h2>Submission: $submission_id</h2>);
	$self->_print_file_upload_fieldset($submission_id);
	$self->_print_message_fieldset($submission_id);
	say q(</div></div>);
	return;
}

sub _update_allele_submission_sequence_status {
	my ( $self, $submission_id, $seqs ) = @_;
	my $q = $self->{'cgi'};
	foreach my $seq (@$seqs) {
		my $status = $q->param("status_$seq->{'seq_id'}");
		next if !defined $status;
		eval {
			$self->{'db'}->do( 'UPDATE allele_submission_sequences SET status=? WHERE (submission_id,seq_id)=(?,?)',
				undef, $status, $submission_id, $seq->{'seq_id'} );
		};
		if ($@) {
			$logger->error($@);
			$self->{'db'}->rollback;
		} else {
			$self->{'db'}->commit;
		}
	}
	return;
}

sub _print_sequence_table {
	my ( $self, $submission_id, $options ) = @_;
	my $q                 = $self->{'cgi'};
	my $submission        = $self->_get_submission($submission_id);
	my $allele_submission = $self->get_allele_submission($submission_id);
	my $seqs              = $allele_submission->{'seqs'};
	my $locus             = $allele_submission->{'locus'};
	my $locus_info        = $self->{'datastore'}->get_locus_info($locus);
	my $cds = $locus_info->{'data_type'} eq 'DNA' && $locus_info->{'complete_cds'} ? '<th>Complete CDS</th>' : '';
	say q(<table class="resultstable">);
	say qq(<tr><th>Identifier</th><th>Length</th><th>Sequence</th>$cds<th>Status</th><th>Assigned allele</th></tr>);
	my $all_assigned_or_rejected = 1;
	my $all_assigned             = 1;
	my $td                       = 1;
	my $pending_seqs             = [];

	foreach my $seq (@$seqs) {
		my $id       = $seq->{'seq_id'};
		my $length   = length $seq->{'sequence'};
		my $sequence = BIGSdb::Utils::truncate_seq( \$seq->{'sequence'}, 40 );
		$cds = '';
		if ( $locus_info->{'data_type'} eq 'DNA' && $locus_info->{'complete_cds'} ) {
			$cds =
			  BIGSdb::Utils::is_complete_cds( \$seq->{'sequence'} )->{'cds'}
			  ? q(<td><span class="fa fa-check fa-lg" style="color:green"></span></td>)
			  : q(<td><span class="fa fa-times fa-lg" style="color:red"></span></td>);
		}
		say qq(<tr class="td$td"><td>$id</td><td>$length</td>);
		say qq(<td class="seq">$sequence</td>$cds);
		my $assigned = $self->{'datastore'}->run_query(
			'SELECT allele_id FROM sequences WHERE (locus,sequence)=(?,?)',
			[ $allele_submission->{'locus'}, $seq->{'sequence'} ],
			{ cache => 'SubmitPage::print_sequence_table_fieldset' }
		);
		if ( !defined $assigned ) {
			if ( defined $seq->{'assigned_id'} ) {
				$self->_clear_assigned_id( $submission_id, $seq->{'seq_id'} );
			}
			if ( $seq->{'status'} eq 'assigned' ) {
				$self->_set_allele_status( $submission_id, $seq->{'seq_id'}, 'pending' );
			}
			push @$pending_seqs, $seq if $seq->{'status'} ne 'rejected';
		}
		$assigned //= '';
		if ( $options->{'curate'} && !$assigned ) {
			say q(<td>);
			say $q->popup_menu(
				-name    => "status_$seq->{'seq_id'}",
				-values  => [qw(pending rejected)],
				-default => $seq->{'status'}
			);
			say q(</td>);
			$all_assigned_or_rejected = 0 if $seq->{'status'} ne 'rejected';
			$all_assigned = 0;
		} else {
			say qq(<td>$seq->{'status'}</td>);
		}
		if ( $options->{'curate'} && $seq->{'status'} ne 'rejected' && $assigned eq '' ) {
			say qq(<td><a href="$self->{'system'}->{'curate_script'}?db=$self->{'instance'}&amp;page=add&amp;)
			  . qq(table=sequences&amp;locus=$locus&amp;submission_id=$submission_id&amp;seq_id=$seq->{'seq_id'}&amp;)
			  . qq(sender=$submission->{'submitter'}"><span class="fa fa-lg fa-edit"></span>Curate</a></td>);
		} else {
			say qq(<td>$assigned</td>);
		}
		say q(</tr>);
		$td = $td == 1 ? 2 : 1;
	}
	say q(</table>);
	return {
		all_assigned_or_rejected => $all_assigned_or_rejected,
		all_assigned             => $all_assigned,
		pending_seqs             => $pending_seqs
	};
}

sub _print_sequence_table_fieldset {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $q          = $self->{'cgi'};
	my $submission = $self->_get_submission($submission_id);
	return if !$submission;
	return if $submission->{'type'} ne 'alleles';
	my $allele_submission = $self->get_allele_submission($submission_id);
	return if !$allele_submission;
	my $seqs = $allele_submission->{'seqs'};

	if ( $q->param('curate') && $q->param('update') ) {
		$self->_update_allele_submission_sequence_status( $submission_id, $seqs );
		$allele_submission = $self->get_allele_submission($submission_id);
		$seqs              = $allele_submission->{'seqs'};
	}
	my $locus      = $allele_submission->{'locus'};
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	say q(<fieldset style="float:left"><legend>Sequences</legend>);
	my $fasta_icon = $self->get_file_icon('FAS');
	my $plural = @$seqs == 1 ? '' : 's';
	say qq(<p>You are submitting the following $allele_submission->{'locus'} sequence$plural: )
	  . qq(<a href="/submissions/$submission_id/sequences.fas">Download$fasta_icon</a></p>)
	  if ( $options->{'download_link'} );
	say $q->start_form;
	my $status = $self->_print_sequence_table( $submission_id, $options );

	if ( $options->{'curate'} && !$status->{'all_assigned'} ) {
		say q(<div style="float:right">);
		say $q->submit(
			-name  => 'update',
			-label => 'Update',
			-class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all'
		);
		say q(</div>);
	}
	say $q->hidden($_) foreach qw(db page submission_id curate);
	say $q->end_form;
	if ( $options->{'curate'} && !$status->{'all_assigned_or_rejected'} ) {
		say $q->start_form( -action => $self->{'system'}->{'curate_script'} );
		say $q->submit(
			-name  => 'Batch curate',
			-class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all'
		);
		my $page = $q->param('page');
		$q->param( page         => 'batchAddFasta' );
		$q->param( locus        => $locus );
		$q->param( sender       => $submission->{'submitter'} );
		$q->param( sequence     => $self->_get_fasta_string( $status->{'pending_seqs'} ) );
		$q->param( complete_CDS => $locus_info->{'complete_cds'} ? 'on' : 'off' );
		say $q->hidden($_) foreach qw( db page submission_id locus sender sequence complete_CDS );
		say $q->end_form;
		$q->param( page => $page );    #Restore value
	}
	say q(</fieldset>);
	$self->{'all_assigned_or_rejected'} = $status->{'all_assigned_or_rejected'};
	return;
}

sub _clear_assigned_id {
	my ( $self, $submission_id, $seq_id ) = @_;
	eval {
		$self->{'db'}->do( 'UPDATE allele_submission_sequences SET assigned_id=NULL WHERE (submission_id,seq_id)=(?,?)',
			undef, $submission_id, $seq_id );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
		$self->_update_submission_datestamp($submission_id);
	}
	return;
}

sub _set_allele_status {
	my ( $self, $submission_id, $seq_id, $status ) = @_;
	eval {
		$self->{'db'}->do( 'UPDATE allele_submission_sequences SET status=? WHERE (submission_id,seq_id)=(?,?)',
			undef, $status, $submission_id, $seq_id );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
		$self->_update_submission_datestamp($submission_id);
	}
	return;
}

sub _update_submission_datestamp {
	my ( $self, $submission_id ) = @_;
	eval { $self->{'db'}->do( 'UPDATE submissions SET datestamp=?', undef, 'now' ) };
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _print_message_fieldset {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $q = $self->{'cgi'};
	if ( $q->param('message') ) {
		my $user = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
		if ( !$user ) {
			$logger->error('Invalid user.');
			return;
		}
		eval {
			$self->{'db'}->do( 'INSERT INTO messages (submission_id,timestamp,user_id,message) VALUES (?,?,?,?)',
				undef, $submission_id, 'now', $user->{'id'}, $q->param('message') );
		};
		if ($@) {
			$logger->error($@);
			$self->{'db'}->rollback;
		} else {
			$self->{'db'}->commit;
			$self->_append_message( $submission_id, $user->{'id'}, $q->param('message') );
			$q->delete('message');
			$self->_update_submission_datestamp($submission_id);
		}
	}
	my $buffer;
	my $qry = q(SELECT date_trunc('second',timestamp) AS timestamp,user_id,message FROM messages )
	  . q(WHERE submission_id=? ORDER BY timestamp asc);
	my $messages = $self->{'datastore'}->run_query( $qry, $submission_id, { fetch => 'all_arrayref', slice => {} } );
	if (@$messages) {
		$buffer .= q(<table class="resultstable"><tr><th>Timestamp</th><th>User</th><th>Message</th></tr>);
		my $td = 1;
		foreach my $message (@$messages) {
			my $user_string = $self->{'datastore'}->get_user_string( $message->{'user_id'} );
			$buffer .= qq(<tr class="td$td"><td>$message->{'timestamp'}</td><td>$user_string</td>)
			  . qq(<td style="text-align:left">$message->{'message'}</td></tr>);
			$td = $td == 1 ? 2 : 1;
		}
		$buffer .= q(</table>);
	}
	if ( !$options->{'no_add'} ) {
		$buffer .= $q->start_form;
		$buffer .= q(<div>);
		$buffer .= $q->textarea( -name => 'message', -id => 'message', -style => 'width:100%' );
		$buffer .= q(</div><div style="float:right">);
		$buffer .= $q->submit(
			-name  => 'Add message',
			-class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all'
		);
		$buffer .= q(</div>);
		$buffer .= $q->hidden($_)
		  foreach qw(db page alleles profiles locus submit continue view curate abort submission_id no_check );
		$buffer .= $q->end_form;
	}
	say qq(<fieldset style="float:left"><legend>Messages</legend>$buffer</fieldset>) if $buffer;
	return;
}

sub _print_archive_fieldset {
	my ( $self, $submission_id ) = @_;
	say q(<fieldset style="float:left"><legend>Archive</legend>);
	say q(<p>Archive of submission and any supporting files:</p>);
	my $tar_icon = $self->get_file_icon('TAR');
	say qq(<p><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
	  . qq(submission_id=$submission_id&amp;tar=1">Download$tar_icon</a></p>);
	say q(</fieldset>);
	return;
}

sub _print_close_submission_fieldset {
	my ( $self, $submission_id ) = @_;
	return if !$self->{'all_assigned_or_rejected'};    #Set in _print_sequence_table_fieldset.
	my $q = $self->{'cgi'};
	say $q->start_form;
	$q->param( close => 1 );
	say $q->hidden($_) foreach qw( db page submission_id close );
	$self->print_action_fieldset( { no_reset => 1, submit_label => 'Close submission' } );
	say $q->end_form;
	return;
}

sub _append_message {
	my ( $self, $submission_id, $user_id, $message ) = @_;
	my $dir = $self->_get_submission_dir($submission_id);
	$dir = $dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+$)/x ? $1 : undef;    #Untaint
	make_path $dir;
	my $filename = 'messages.txt';
	open( my $fh, '>>:encoding(utf8)', "$dir/$filename" )
	  || $logger->error("Can't open $dir/$filename for appending");
	my $user_string = $self->{'datastore'}->get_user_string($user_id);
	say $fh $user_string;
	my $timestamp = localtime(time);
	say $fh $timestamp;
	say $fh $message;
	say $fh '';
	close $fh;
	return;
}

sub _print_submission_file_table {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $q     = $self->{'cgi'};
	my $files = $self->_get_submission_files($submission_id);
	return if !@$files;
	my $buffer = q(<table class="resultstable"><tr><th>Filename</th><th>Size</th>);
	$buffer .= q(<th>Delete</th>) if $options->{'delete_checkbox'};
	$buffer .= qq(</tr>\n);
	my $td = 1;
	my $i  = 0;

	foreach my $file (@$files) {
		$buffer .=
		    qq(<tr class="td$td"><td><a href="/submissions/$submission_id/supporting_files/$file->{'filename'}">)
		  . qq($file->{'filename'}</a></td><td>$file->{'size'}</td>);
		if ( $options->{'delete_checkbox'} ) {
			$buffer .= q(<td>);
			$buffer .= $q->checkbox( -name => "file$i", -label => '' );
			$buffer .= q(</td>);
		}
		$i++;
		$buffer .= qq(</tr>\n);
		$td = $td == 1 ? 2 : 1;
	}
	$buffer .= q(</table>);
	return $buffer if $options->{'get_only'};
	say $buffer;
	return;
}

sub _get_submission_files {
	my ( $self, $submission_id ) = @_;
	my $dir = $self->_get_submission_dir($submission_id) . '/supporting_files';
	return [] if !-e $dir;
	my @files;
	opendir( my $dh, $dir ) || $logger->error("Can't open directory $dir");
	while ( my $filename = readdir $dh ) {
		next if $filename =~ /^\./x;
		next if $filename =~ /^submission/x;    #Temp file created by script
		push @files, { filename => $filename, size => BIGSdb::Utils::get_nice_size( -s "$dir/$filename" ) };
	}
	closedir $dh;
	return \@files;
}

sub _get_submission_dir {
	my ( $self, $submission_id ) = @_;
	return "$self->{'config'}->{'submission_dir'}/$submission_id";
}

sub _upload_files {
	my ( $self, $submission_id ) = @_;
	my $q         = $self->{'cgi'};
	my @filenames = $q->param('file_upload');
	my $i         = 0;
	my $dir       = $self->_get_submission_dir($submission_id) . '/supporting_files';
	if ( !-e $dir ) {
		make_path $dir || $logger->error("Cannot create $dir directory.");
	}
	foreach my $fh2 ( $q->upload('file_upload') ) {
		if ( $filenames[$i] =~ /([A-z0-9_\-\.'\ \(\)]+)/x ) {
			$filenames[$i] = $1;
		} else {
			$filenames[$i] = 'file';
		}
		my $filename = "$dir/$filenames[$i]";
		$i++;
		next if -e $filename;    #Don't reupload if already done.
		my $buffer;
		open( my $fh, '>', $filename ) || $logger->error("Could not open $filename for writing.");
		binmode $fh2;
		binmode $fh;
		read( $fh2, $buffer, MAX_UPLOAD_SIZE );
		print $fh $buffer;
		close $fh;
	}
	return;
}

sub _print_file_fieldset {
	my ( $self, $submission_id ) = @_;
	my $file_table = $self->_print_submission_file_table( $submission_id, { get_only => 1 } );
	if ($file_table) {
		say q(<fieldset style="float:left"><legend>Supporting files</legend>);
		say $file_table;
		say q(</fieldset>);
	}
	return;
}

sub _print_summary {
	my ( $self, $submission_id ) = @_;
	my $submission = $self->_get_submission($submission_id);
	say q(<fieldset style="float:left"><legend>Summary</legend>);
	say qq(<dl class="data"><dt>type</dt><dd>$submission->{'type'}</dd>);
	my $user_string =
	  $self->{'datastore'}->get_user_string( $submission->{'submitter'}, { email => 1, affiliation => 1 } );
	say qq(<dt>submitter</dt><dd>$user_string</dd>);
	say qq(<dt>datestamp</dt><dd>$submission->{'datestamp'}</dd>);
	say qq(<dt>status</dt><dd>$submission->{'status'}</dd>);

	if ( $submission->{'type'} eq 'alleles' ) {
		my $allele_submission = $self->get_allele_submission($submission_id);
		say qq(<dt>locus</dt><dd>$allele_submission->{'locus'}</dd>);
		my $allele_count   = @{ $allele_submission->{'seqs'} };
		my $fasta_icon     = $self->get_file_icon('FAS');
		my $submission_dir = $self->_get_submission_dir($submission_id);
		if ( -e "$submission_dir/sequences.fas" ) {
			say q(<dt>sequences</dt>)
			  . qq(<dd><a href="/submissions/$submission_id/sequences.fas">$allele_count$fasta_icon</a></dd>);
		} else {
			$logger->error("No submission FASTA file for allele submission $submission_id.");
		}
		say qq(<dt>technology</dt><dd>$allele_submission->{'technology'}</dd>);
		say qq(<dt>read length</dt><dd>$allele_submission->{'read_length'}</dd>)
		  if $allele_submission->{'read_length'};
		say qq(<dt>coverage</dt><dd>$allele_submission->{'coverage'}</dd>) if $allele_submission->{'coverage'};
		say qq(<dt>assembly</dt><dd>$allele_submission->{'assembly'}</dd>);
		say qq(<dt>assembly software</dt><dd>$allele_submission->{'software'}</dd>);
	}
	say q(</dl></fieldset>);
	return;
}

#Check submission exists and curator has appropriate permissions.
sub _is_submission_valid {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	if ( !$submission_id ) {
		say q(<div class="box" id="statusbad"><p>No submission id passed.</p></div>) if !$options->{'no_message'};
		return;
	}
	my $submission = $self->_get_submission($submission_id);
	if ( !$submission ) {
		say qq(<div class="box" id="statusbad"><p>Submission '$submission_id' does not exist.</p></div>)
		  if !$options->{'no_message'};
		return;
	}
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	if ( $options->{'curate'} ) {
		if ( !$user_info || ( $user_info->{'status'} ne 'admin' && $user_info->{'status'} ne 'curator' ) ) {
			say q(<div class="box" id="statusbad"><p>Your account does not have the required )
			  . q(permissions to curate this submission.</p></div>)
			  if !$options->{'no_message'};
			return;
		}
		if ( $submission->{'type'} eq 'alleles' ) {
			my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
			my $curator_allowed =
			  $self->{'datastore'}
			  ->is_allowed_to_modify_locus_sequences( $allele_submission->{'locus'}, $user_info->{'id'} );
			if ( !( $self->is_admin || $curator_allowed ) ) {
				say q(<div class="box" id="statusbad"><p>Your account does not have the required )
				  . qq(permissions to curate new $allele_submission->{'locus'} sequences.</p></div>)
				  if !$options->{'no_message'};
				return;
			}
		}
	}
	if ( $options->{'user_owns'} ) {
		return if $submission->{'submitter'} != $user_info->{'id'};
	}
	return 1;
}

sub _curate_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	say q(<h1>Curate submission</h1>);
	return if !$self->_is_submission_valid( $submission_id, { curate => 1 } );
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	say qq(<h2>Submission: $submission_id</h2>);
	$self->_print_summary($submission_id);
	$self->_print_sequence_table_fieldset( $submission_id, { curate => 1 } );
	$self->_print_file_fieldset($submission_id);
	$self->_print_message_fieldset($submission_id);
	$self->_print_archive_fieldset($submission_id);
	$self->_print_close_submission_fieldset($submission_id);
	say q(</div></div>);
	return;
}

sub _view_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	say q(<h1>Submission summary</h1>);
	return if !$self->_is_submission_valid($submission_id);
	my $submission = $self->_get_submission($submission_id);
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	say qq(<h2>Submission: $submission_id</h2>);
	$self->_print_summary($submission_id);
	$self->_print_sequence_table_fieldset($submission_id);
	$self->_print_file_fieldset($submission_id);
	$self->_print_message_fieldset( $submission_id, { no_add => $submission->{'status'} eq 'closed' ? 1 : 0 } );
	$self->_print_archive_fieldset($submission_id);
	say q(</div></div>);
	return;
}

sub _close_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	return if !$self->_is_submission_valid( $submission_id, { curate => 1, no_message => 1 } );
	eval {
		$self->{'db'}
		  ->do( 'UPDATE submissions SET (status,datestamp)=(?,?) WHERE id=?', undef, 'closed', 'now', $submission_id );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _remove_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	return if !$self->_is_submission_valid( $submission_id, { no_message => 1, user_owns => 1 } );
	$self->_delete_submission($submission_id);
	return;
}

sub _get_fasta_string {
	my ( $self, $seqs ) = @_;
	my $buffer;
	foreach my $seq (@$seqs) {
		$buffer .= ">$seq->{'seq_id'}\n";
		$buffer .= "$seq->{'sequence'}\n";
	}
	return $buffer;
}

sub _write_allele_FASTA {
	my ( $self, $submission_id ) = @_;
	my $allele_submission = $self->get_allele_submission($submission_id);
	my $seqs              = $allele_submission->{'seqs'};
	return if !@$seqs;
	my $dir = $self->_get_submission_dir($submission_id);
	$dir = $dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+$)/x ? $1 : undef;    #Untaint
	make_path $dir;
	my $filename = 'sequences.fas';
	open( my $fh, '>', "$dir/$filename" ) || $logger->error("Can't open $dir/$filename for writing");

	foreach my $seq (@$seqs) {
		say $fh ">$seq->{'seq_id'}";
		say $fh $seq->{'sequence'};
	}
	close $fh;
	return $filename;
}

sub _tar_submission {    ## no critic (ProhibitUnusedPrivateSubroutines ) #Called by dispatch table
	my ( $self, $submission_id ) = @_;
	return if !defined $submission_id || $submission_id !~ /BIGSdb_\d+/x;
	my $submission = $self->_get_submission($submission_id);
	return if !$submission;
	my $submission_dir = $self->_get_submission_dir($submission_id);
	$submission_dir =
	  $submission_dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+)$/x ? $1 : undef;    #Untaint
	binmode STDOUT;
	local $" = ' ';
	my $command = "cd $submission_dir && tar -cf - *";

	if ( $ENV{'MOD_PERL'} ) {
		print `$command`;    # http://modperlbook.org/html/6-4-8-Output-from-System-Calls.html
	} else {
		system $command || $logger->error("Can't create tar: $?");
	}
	return;
}

sub _update_allele_prefs {
	my ($self) = @_;
	my $guid = $self->get_guid;
	return if !$guid;
	my $q = $self->{'cgi'};
	foreach my $param (qw(technology read_length coverage assembly software)) {
		my $field = "submit_allele_$param";
		my $value = $q->param($param);
		next if !$value;
		$self->{'prefstore'}->set_general( $guid, $self->{'system'}->{'db'}, $field, $value );
	}
	return;
}

sub _get_scheme_loci {
	my ( $self, $scheme_ids ) = @_;
	my @loci;
	my %locus_selected;
	my $set_id = $self->get_set_id;
	foreach (@$scheme_ids) {
		my $scheme_loci =
		    $_
		  ? $self->{'datastore'}->get_scheme_loci($_)
		  : $self->{'datastore'}->get_loci_in_no_scheme( { set_id => $set_id } );
		foreach my $locus (@$scheme_loci) {
			if ( !$locus_selected{$locus} ) {
				push @loci, $locus;
				$locus_selected{$locus} = 1;
			}
		}
	}
	return \@loci;
}

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} =
	  { general => 1, main_display => 0, isolate_display => 0, analysis => 0, query_field => 0 };
	return;
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return " Manage submissions - $desc ";
}
1;
