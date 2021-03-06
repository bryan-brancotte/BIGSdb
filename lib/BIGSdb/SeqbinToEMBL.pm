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
package BIGSdb::SeqbinToEMBL;
use strict;
use warnings;
use 5.010;
use IO::Handle;
use Bio::SeqIO;
use Bio::SeqFeature::Generic;
use parent qw(BIGSdb::Page);
use Log::Log4perl qw(get_logger);
use Error qw(:try);
my $logger = get_logger('BIGSdb.Page');

sub initiate {
	my ($self) = @_;
	$self->{'type'} = 'embl';
	return;
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	my $isolate_id;
	my $seqbin_ids = [];
	if ( ( $q->param('seqbin_id') // '' ) =~ /^(\d+)$/x ) {
		push @$seqbin_ids, $1;
	} elsif ( ( $q->param('isolate_id') // '' ) =~ /^(\d+)$/x ) {
		$isolate_id = $1;
		$seqbin_ids =
		  $self->{'datastore'}
		  ->run_query( 'SELECT id FROM sequence_bin WHERE isolate_id=?', $isolate_id, { fetch => 'col_arrayref' } );
	} else {
		print "Invalid isolate or sequence bin id.\n";
		return;
	}
	$self->write_embl($seqbin_ids);
	return;
}

sub write_embl {
	my ( $self, $seqbin_ids, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $buffer;
	foreach my $seqbin_id (@$seqbin_ids) {
		my $seq = $self->{'datastore'}->run_query(
			'SELECT s.sequence,s.comments,r.uri FROM sequence_bin s LEFT JOIN remote_contigs r '
			  . 'ON s.id=r.seqbin_id WHERE s.id=?',
			$seqbin_id,
			{ fetch => 'row_hashref', cache => 'SeqbinToEMBL::write_embl::seq' }
		);
		if ( !$seq->{'sequence'} && $seq->{'uri'} ) {
			my $contig_record = $self->{'contigManager'}->get_remote_contig( $seq->{'uri'} );
			$seq->{'sequence'} = $contig_record->{'sequence'};
		}
		my $seq_length   = length $seq->{'sequence'};
		my $fasta_string = ">$seqbin_id\n$seq->{'sequence'}\n";
		open( my $stringfh_in, '<:encoding(utf8)', \$fasta_string )
		  || $logger->error("Could not open string for reading: $!");
		$stringfh_in->untaint;
		my $seqin      = Bio::SeqIO->new( -fh => $stringfh_in, -format => 'fasta' );
		my $seq_object = $seqin->next_seq;
		my $accessions = $self->{'datastore'}->run_query( 'SELECT databank_id FROM accession WHERE seqbin_id=?',
			$seqbin_id, { fetch => 'col_arrayref', cache => 'SeqbinToEMBL::write_embl::databank' } );
		unshift @$accessions, $seqbin_id;
		local $" = '; ';
		$seq_object->accession_number("@$accessions") if @$accessions;
		$seq_object->desc( $seq->{'comments'} );
		my $set_id = $self->get_set_id;
		my $set_clause =
		  $set_id
		  ? 'AND (locus IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes '
		  . "WHERE set_id=$set_id)) OR locus IN (SELECT locus FROM set_loci WHERE set_id=$set_id))"
		  : '';
		my $qry = "SELECT * FROM allele_sequences WHERE seqbin_id=? $set_clause ORDER BY start_pos";
		my $allele_sequences =
		  $self->{'datastore'}->run_query( $qry, $seqbin_id,
			{ fetch => 'all_arrayref', slice => {}, cache => 'SeqbinToEMBL::write_embl::allele_sequences' } );

		foreach my $allele_sequence (@$allele_sequences) {
			my $locus_info = $self->{'datastore'}->get_locus_info( $allele_sequence->{'locus'} );
			my $frame;

			#BIGSdb stored ORF as 1-6.  BioPerl expects 0-2.
			$locus_info->{'orf'} ||= 0;
			if    ( $locus_info->{'orf'} == 2 || $locus_info->{'orf'} == 5 ) { $frame = 1 }
			elsif ( $locus_info->{'orf'} == 3 || $locus_info->{'orf'} == 6 ) { $frame = 2 }
			else                                                             { $frame = 0 }
			$allele_sequence->{'start_pos'} = 1 if $allele_sequence->{'start_pos'} < 1;
			my ( $product, $desc );
			if ( $locus_info->{'dbase_name'} && ( $locus_info->{'description_url'} // '' ) =~ /bigsdb/ ) {
				my $locus_desc = $self->{'datastore'}->get_locus( $allele_sequence->{'locus'} )->get_description;
				$product = $locus_desc->{'product'};
				$desc    = $locus_desc->{'full_name'};
				$desc .= ' - ' if $desc && $locus_desc->{'description'};
				$desc .= $locus_desc->{'description'} // '';
			}
			$allele_sequence->{'locus'} = $self->clean_locus( $allele_sequence->{'locus'}, { text_output => 1 } );
			my $end = $allele_sequence->{'end_pos'};
			$end = $seq_length if $end > $seq_length;
			my $feature = Bio::SeqFeature::Generic->new(
				-start       => $allele_sequence->{'start_pos'},
				-end         => $end,
				-primary_tag => 'CDS',
				-strand      => ( $allele_sequence->{'reverse'} ? -1 : 1 ),
				-frame       => $frame,
				-tag         => { gene => $allele_sequence->{'locus'}, product => $product, note => $desc }
			);
			$seq_object->add_SeqFeature($feature);
		}
		close $stringfh_in;
		my $str;
		open( my $stringfh_out, '>:encoding(utf8)', \$str ) or $logger->error("Could not open string for writing: $!");
		my $seq_out = Bio::SeqIO->new( -fh => $stringfh_out, -format => 'embl' );
		$seq_out->verbose(-1);    #Otherwise apache error log can fill rapidly on old version of BioPerl.
		$seq_out->write_seq($seq_object);
		close $stringfh_out;

		if ( $options->{'get_buffer'} ) {
			$buffer .= $str;
		} else {
			print $str;
		}
	}
	return $options->{'get_buffer'} ? $buffer : undef;
}
1;
