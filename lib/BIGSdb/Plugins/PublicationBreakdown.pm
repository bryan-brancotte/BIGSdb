#PublicationBreakdown.pm - PublicationBreakdown plugin for BIGSdb
#Written by Keith Jolley
#Copyright (c) 2010-2012, University of Oxford
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
package BIGSdb::Plugins::PublicationBreakdown;
use strict;
use warnings;
use parent qw(BIGSdb::Plugin BIGSdb::ResultsTablePage);
use List::MoreUtils qw(any uniq);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Plugins');
use Error qw(:try);

sub get_attributes {
	my %att = (
		name        => 'Publication Breakdown',
		author      => 'Keith Jolley',
		affiliation => 'University of Oxford, UK',
		email       => 'keith.jolley@zoo.ox.ac.uk',
		description => 'Breakdown of query results by publication',
		category    => 'Breakdown',
		buttontext  => 'Publications',
		menutext    => 'Publications',
		module      => 'PublicationBreakdown',
		version     => '1.1.0',
		dbtype      => 'isolates',
		section     => 'breakdown,postquery',
		url         => 'http://pubmlst.org/software/database/bigsdb/userguide/isolates/publications.shtml',
		input       => 'query',
		requires    => 'ref_db',
		order       => 30,
	);
	return \%att;
}

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { 'general' => 1, 'main_display' => 0, 'isolate_display' => 0, 'analysis' => 0, 'query_field' => 0 };
	return;
}

sub run {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $query_file = $q->param('query_file');
	print "<h1>Publication breakdown of dataset</h1>\n";
	if ( !$self->{'config'}->{'ref_db'} ) {
		print "<div class=\"box\" id=\"statusbad\">No reference database has been defined.</p></div>\n";
		return;
	}
	my %prefs;
	my $qry_ref = $self->get_query($query_file);
	return if ref $qry_ref ne 'SCALAR';
	my $qry = $$qry_ref;
	$qry =~ s/ORDER BY.*$//g;
	my $isolate_qry = $qry;
	$logger->debug("Breakdown query: $qry");
	return if !$self->create_temp_tables($qry_ref);
	$qry =~ s/SELECT \* FROM $self->{'system'}->{'view'}/SELECT id FROM $self->{'system'}->{'view'}/;
	my $new_qry = "SELECT DISTINCT(refs.pubmed_id) FROM refs WHERE refs.isolate_id IN ($qry)";
	my $sql     = $self->{'db'}->prepare($new_qry);
	eval { $sql->execute };
	$logger->error($@) if $@;
	my @list;
	while ( my ($pmid) = $sql->fetchrow_array ) {
		push @list, $pmid if $pmid;
	}
	my $guid = $self->get_guid;
	if ( $self->{'datastore'}->create_temp_ref_table( \@list, \$isolate_qry ) ) {
		print "<div class=\"box\" id=\"queryform\">\n";
		print $q->startform;
		$q->param( 'all_records', 1 ) if !$query_file;
		print $q->hidden($_) foreach qw (db name query_file page all_records);
		print "<fieldset class=\"filter\"><legend>Filter query by</legend>\n";
		my $author_list = $self->_get_author_list;
		print "<ul><li><label for=\"author_list\" class=\"display\">Author:</label>\n";
		print $q->popup_menu( -name => 'author_list', -id => 'author_list', -values => $author_list );
		print "</li>\n<li><label for=\"year_list\" class=\"display\">Year:</label>\n";
		my $year_list = $self->{'datastore'}->run_list_query("SELECT DISTINCT year FROM temp_refs ORDER BY year");
		unshift @$year_list, 'All years';
		print $q->popup_menu( -name => 'year_list', -id => 'year_list', -values => $year_list );
		print "</li>\n</ul>\n</fieldset>\n";
		print "<fieldset class=\"display\">\n";
		print "<ul><li><label for=\"order\" class=\"display\">Order by: </label>\n";
		my %labels = ( pmid => 'Pubmed id', first_author => 'first author', isolates => 'number of isolates' );
		my @order_list = qw(pmid authors year title isolates);
		print $q->popup_menu( -name => 'order', -id => 'order', -values => \@order_list, -labels => \%labels, -default => 'isolates' );
		print $q->popup_menu(
			-name    => 'direction',
			-values  => [qw (asc desc)],
			-labels  => { 'asc' => 'ascending', 'desc' => 'descending' },
			-default => 'desc'
		);
		print "</li>\n<li><label for=\"displayrecs\" class=\"display\">Display: </label>\n";

		if ( $q->param('displayrecs') ) {
			$self->{'prefs'}->{'displayrecs'} = $q->param('displayrecs');
		}
		print $q->popup_menu(
			-name    => 'displayrecs',
			-id      => 'displayrecs',
			-values  => [ qw (10 25 50 100 200 500 all) ],
			-default => $self->{'prefs'}->{'displayrecs'}
		);
		print " records per page</li>\n</ul>\n";
		print
		  "<span style=\"float:right\"><input type=\"submit\" name=\"submit\" value=\"Submit\" class=\"submit\" /></span>\n</fieldset>\n";
		print $q->endform;
		print "</div>\n";
		my @filters;
		my $author =
		  ( any { defined $q->param('author_list') && $q->param('author_list') eq $_ } @$author_list )
		  ? $q->param('author_list')
		  : 'All authors';
		$author =~ s/'/\\'/g;
		push @filters, "authors LIKE E'%$author%'" if $author ne 'All authors';
		my $year = BIGSdb::Utils::is_int( $q->param('year_list') ) ? $q->param('year_list') : '';
		push @filters, "year=$year" if $year;
		local $" = ' AND ';
		my $filter_string = @filters ? " WHERE @filters" : '';
		my $order = ( any { defined $q->param('order') && $q->param('order') eq $_ } @order_list ) ? $q->param('order') : 'isolates';
		my $dir = ( any { defined $q->param('direction') && $q->param('direction') eq $_ } qw(desc asc) ) ? $q->param('direction') : 'desc';
		my $refquery          = "SELECT * FROM temp_refs$filter_string ORDER BY $order $dir;";
		my @hidden_attributes = qw (name all_records author_list year_list query_file);
		$self->paged_display( 'refs', $refquery, '', \@hidden_attributes );
		return;
	}
}

sub _get_author_list {
	my ($self) = @_;
	my @authornames;
	my $qry = "SELECT authors FROM temp_refs";
	my $sql = $self->{'db'}->prepare($qry);
	eval { $sql->execute };
	$logger->error($@) if $@;
	while ( my ($authorstring) = $sql->fetchrow_array ) {
		push @authornames, split /, /, $authorstring if defined $authorstring;
	}
	@authornames = sort { lc($a) cmp lc($b) } uniq @authornames;
	unshift @authornames, 'All authors';
	return \@authornames;
}
1;
