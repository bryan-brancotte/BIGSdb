#Written by Keith Jolley
#Copyright (c) 2010-2015, University of Oxford
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
package BIGSdb::ChangePasswordPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::LoginMD5);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use constant MIN_PASSWORD_LENGTH => 8;

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return $self->{'cgi'}->param('page') eq 'changePassword' ? "Change password - $desc" : "Set user password - $desc";
}

sub print_content {
	my ($self)   = @_;
	my $q        = $self->{'cgi'};
	my $continue = 1;
	say $q->param('page') eq 'changePassword' ? "<h1>Change password</h1>" : "<h1>Set user password</h1>";
	if ( $self->{'system'}->{'authentication'} ne 'builtin' ) {
		say qq(<div class="box" id="statusbad"><p>This database uses external means of authentication and the password )
		  . qq(cannot be changed from within the web application.</p></div>);
		return;
	} elsif ( $q->param('page') eq 'setPassword' && !$self->{'permissions'}->{'set_user_passwords'} && !$self->is_admin ) {
		say qq(<div class="box" id="statusbad"><p>You are not allowed to change other users' passwords.</p></div>);
		return;
	} elsif ( $q->param('sent') && $q->param('page') eq 'setPassword' && !$q->param('user') ) {
		say qq(<div class="box" id="statusbad"><p>Please select a user.</p></div>);
		$continue = 0;
	}
	if ( $continue && $q->param('sent') && $q->param('existing_password') ) {
		my $further_checks = 1;
		if ( $q->param('page') eq 'changePassword' ) {

			#make sure user is only attempting to change their own password (user parameter is passed as a hidden
			#parameter and could be changed)
			if ( $self->{'username'} ne $q->param('user') ) {
				say qq(<div class="box" id="statusbad"><p>You are attempting to change another user's password.  You are not )
				  . qq(allowed to do that!</p></div>);
				$further_checks = 0;
			} else {

				#existing password not set when admin setting user passwords
				my $stored_hash = $self->get_password_hash( $self->{'username'} );
				if ( $stored_hash ne $q->param('existing_password') ) {
					say qq(<div class="box" id="statusbad"><p>Your existing password was entered incorrectly. The password has not )
					  . qq(been updated.</p></div>);
					$further_checks = 0;
				}
			}
		}
		if ($further_checks) {
			if ( $q->param('new_length') < MIN_PASSWORD_LENGTH ) {
				say qq(<div class="box" id="statusbad"><p>The password is too short and has not been updated.  It must be at least )
				  . MIN_PASSWORD_LENGTH
				  . qq( characters long.</p></div>);
			} elsif ( $q->param('new_password1') ne $q->param('new_password2') ) {
				say qq(<div class="box" id="statusbad"><p>The password was not re-typed the same as the first time.</p></div>);
			} elsif ( $q->param('username_as_password') eq $q->param('new_password1') ) {
				say qq(<div class="box" id="statusbad"><p>You can't use your username as your password!</p></div>);
			} else {
				my $username = $q->param('page') eq 'changePassword' ? $self->{'username'} : $q->param('user');
				if ( $self->set_password_hash( $username, $q->param('new_password1') ) ) {
					say qq(<div class="box" id="resultsheader"><p>)
					  . ( $q->param('page') eq 'changePassword' ? "Password updated ok." : "Password set for user '$username'." ) . "</p>";
				} else {
					say qq(<div class="box" id="resultsheader"><p>Password not updated.  Please check with the system administrator.</p>);
				}
				say qq(<p><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}">Return to index</a></p></div>);
				return;
			}
		}
	}
	say qq(<div class="box" id="queryform">);
	say "<p>Please enter your existing and new passwords.</p>" if $q->param('page') eq 'changePassword';
	say
	  qq(<noscript><p class="highlight">Please note that Javascript must be enabled in order to login.  Passwords are encrypted using )
	  . qq(Javascript prior to transmitting to the server.</p></noscript>);
	say $q->start_form( -onSubmit => "existing_password.value=existing.value; existing.value='';new_length.value=new1.value.length;"
		  . "var username;"
		  . "if (\$('#user').length){username=document.getElementById('user').value} else {username=user.value}"
		  . "new_password1.value=new1.value;new1.value='';new_password2.value=new2.value;new2.value='';"
		  . "existing_password.value=calcMD5(existing_password.value+username);"
		  . "new_password1.value=calcMD5(new_password1.value+username);"
		  . "new_password2.value=calcMD5(new_password2.value+username);"
		  . "username_as_password.value=calcMD5(username+username);"
		  . "return true" );
	say qq(<fieldset style="float:left"><legend>Passwords</legend>);
	say "<ul>";

	if ( $q->param('page') eq 'changePassword' ) {
		say qq(<li><label for="existing" class="form" style="width:10em">Existing password:</label>);
		say $q->password_field( -name => 'existing', -id => 'existing' );
		say '</li>';
	} else {
		my $user_data =
		  $self->{'datastore'}->run_query( "SELECT user_name, first_name, surname FROM users WHERE id>0 ORDER BY lower(surname)",
			undef, { fetch => 'all_arrayref', slice => {} } );
		my ( @users, %labels );
		push @users, '';
		foreach my $user (@$user_data) {
			push @users, $user->{'user_name'};
			$labels{ $user->{'user_name'} } = "$user->{'surname'}, $user->{'first_name'} ($user->{'user_name'})";
		}
		say qq(<li><label for="user" class="form" style="width:10em">User:</label>);
		say $q->popup_menu( -name => 'user', -id => 'user', -values => [@users], -labels => \%labels );
		say $q->hidden( existing => '' );
		say '</li>';
	}
	say qq(<li><label for="new1" class="form" style="width:10em">New password:</label>);
	say $q->password_field( -name => 'new1', -id => 'new1' );
	say '</li>';
	say qq(<li><label for="new2" class="form" style="width:10em">Retype password:</label>);
	say $q->password_field( -name => 'new2', -id => 'new2' );
	say '</li></ul></fieldset>';
	$self->print_action_fieldset( { no_reset => 1, submit_label => 'Set password' } );
	$q->param( $_ => '' ) foreach qw (existing_password new_password1 new_password2 new_length username_as_password);
	$q->param( user => $self->{'username'} ) if $q->param('page') eq 'changePassword';
	$q->param( sent => 1 );
	say $q->hidden($_) foreach qw (db page existing_password new_password1 new_password2 new_length user sent username_as_password);
	say $q->end_form;
	say "</div>";
	return;
}
1;
