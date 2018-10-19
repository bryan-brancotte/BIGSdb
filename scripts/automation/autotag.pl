#!/usr/bin/env perl
#Automatically tag scan genomes for exactly matching alleles
#Written by Keith Jolley
#Copyright (c) 2011-2018, University of Oxford
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
use strict;
use warnings;
use 5.010;
###########Local configuration#############################################
use constant {
	CONFIG_DIR       => '/etc/bigsdb',
	LIB_DIR          => '/usr/local/lib',
	DBASE_CONFIG_DIR => '/etc/bigsdb/dbases',
	HOST             => undef,                  #Use values in config.xml
	PORT             => undef,                  #But you can override here.
	USER             => undef,
	PASSWORD         => undef
};
#######End Local configuration#############################################
use lib (LIB_DIR);
use Getopt::Long qw(:config no_ignore_case);
use Term::Cap;
use Parallel::ForkManager;
use BIGSdb::Offline::AutoTag;
my %opts;
GetOptions(
	'd|database=s'         => \$opts{'d'},
	'e|exemplar'           => \$opts{'exemplar'},
	'f|fast'               => \$opts{'fast'},
	'i|isolates=s'         => \$opts{'i'},
	'isolate_list_file=s'  => \$opts{'isolate_list_file'},
	'I|exclude_isolates=s' => \$opts{'I'},
	'l|loci=s'             => \$opts{'l'},
	'L|exclude_loci=s'     => \$opts{'L'},
	'm|min_size=i'         => \$opts{'m'},
	'p|projects=s'         => \$opts{'p'},
	'P|exclude_projects=s' => \$opts{'P'},
	'R|locus_regex=s'      => \$opts{'R'},
	's|schemes=s'          => \$opts{'s'},
	't|time=i'             => \$opts{'t'},
	'threads=i'            => \$opts{'threads'},
	'w|word_size=i'        => \$opts{'w'},
	'x|min=i'              => \$opts{'x'},
	'y|max=i'              => \$opts{'y'},
	'0|missing'            => \$opts{'0'},
	'h|help'               => \$opts{'h'},
	'n|new_only'           => \$opts{'n'},
	'new_max_alleles=i'    => \$opts{'new_max_alleles'},
	'o|order'              => \$opts{'o'},
	'only_already_tagged'  => \$opts{'only_already_tagged'},
	'q|quiet'              => \$opts{'q'},
	'r|random'             => \$opts{'r'},
	'reuse_blast'          => \$opts{'reuse_blast'},
	'T|already_tagged'     => \$opts{'T'},
	'v|view=s'             => \$opts{'v'}
) or die("Error in command line arguments\n");
if ( $opts{'h'} ) {
	show_help();
	exit;
}
if ( !$opts{'d'} ) {
	say "\nUsage: autotag.pl -d <database configuration>\n";
	say 'Help: autotag.pl -h';
	exit;
}
if ( $opts{'threads'} && $opts{'threads'} > 1 ) {
	my $script;
	$script = BIGSdb::Offline::AutoTag->new(    #Create script object to use methods to determine isolate list
		{
			config_dir       => CONFIG_DIR,
			lib_dir          => LIB_DIR,
			dbase_config_dir => DBASE_CONFIG_DIR,
			host             => HOST,
			port             => PORT,
			user             => USER,
			password         => PASSWORD,
			options          => { query_only => 1, %opts },
			instance         => $opts{'d'},
		}
	);
	local @SIG{qw (INT TERM HUP)} =
	  ( sub { $script->{'logger'}->info("$opts{'d'}:Autotagger kill signal detected.  Waiting for child processes.") } )
	  x 3;
	die "Script initialization failed - check logs (authentication problems or server too busy?).\n"
	  if !defined $script->{'db'};
	my $isolates = $script->get_isolates_with_linked_seqs;
	$isolates = $script->filter_and_sort_isolates($isolates);
	$script->{'db'}->commit;    #Prevent idle in transaction table locks
	my $lists = [];
	my $i     = 0;
	foreach my $id (@$isolates) {
		push @{ $lists->[$i] }, $id;
		$i++;
		if ( $i == $opts{'threads'} ) {
			$i = 0;
		}
	}
	delete $opts{$_} foreach qw(i I p P x y);    #Remove options that impact isolate list
	my $isolate_count = @$isolates;
	my $threads       = @$lists;
	my $plural        = $isolate_count == 1 ? q() : q(s);
	$script->{'logger'}
	  ->info("$opts{'d'}:Running Autotagger on $isolate_count isolate$plural ($threads thread$plural)");
	my $pm = Parallel::ForkManager->new( $opts{'threads'} );
	foreach my $list (@$lists) {
		$pm->start and next;                     #Forks
		local $" = ',';
		BIGSdb::Offline::AutoTag->new(
			{
				config_dir       => CONFIG_DIR,
				lib_dir          => LIB_DIR,
				dbase_config_dir => DBASE_CONFIG_DIR,
				host             => HOST,
				port             => PORT,
				user             => USER,
				password         => PASSWORD,
				options          => { i => "@$list", %opts },
				instance         => $opts{'d'},
			}
		);
		$pm->finish;    #Terminates child process
	}
	$pm->wait_all_children;
	$script->{'logger'}->info("$opts{'d'}:All Autotagger threads finished");
	exit;
}

#Run non-threaded job
BIGSdb::Offline::AutoTag->new(
	{
		config_dir       => CONFIG_DIR,
		lib_dir          => LIB_DIR,
		dbase_config_dir => DBASE_CONFIG_DIR,
		host             => HOST,
		port             => PORT,
		user             => USER,
		password         => PASSWORD,
		options          => \%opts,
		instance         => $opts{'d'},
	}
);

sub show_help {
	my $termios = POSIX::Termios->new;
	$termios->getattr;
	my $ospeed = $termios->getospeed;
	my $t = Tgetent Term::Cap { TERM => undef, OSPEED => $ospeed };
	my ( $norm, $bold, $under ) = map { $t->Tputs( $_, 1 ) } qw(me md us);
	say << "HELP";
${bold}NAME$norm
    ${bold}autotag.pl$norm - BIGSdb automated allele tagger

${bold}SYNOPSIS$norm
    ${bold}autotag.pl --database$norm ${under}NAME$norm [${under}options$norm]

${bold}OPTIONS$norm
${bold}-0, --missing$norm
    Marks missing loci as provisional allele 0. Sets default word size to 15.
           
${bold}-d, --database$norm ${under}NAME$norm
    Database configuration name.
    
${bold}-e, --exemplar$norm
    Only use alleles with the 'exemplar' flag set in BLAST searches to identify
    locus within genome. Specific allele is then identified using a database 
    lookup. This may be quicker than using all alleles for the BLAST search, 
    but will be at the expense of sensitivity. If no exemplar alleles are set 
    for a locus then all alleles will be used. Sets default word size to 15.

${bold}-f --fast$norm
    Perform single BLAST query against all selected loci together. This will
    take longer to return any results but the overall scan should finish 
    quicker. This method will also use more memory - this can be used with
    --exemplar to mitigate against this.

${bold}-h, --help$norm
    This help page.

${bold}-i, --isolates$norm ${under}LIST$norm  
    Comma-separated list of isolate ids to scan (ignored if -p used).
    
${bold}--isolate_list_file$norm ${under}FILE$norm  
    File containing list of isolate ids (ignored if -i or -p used).
           
${bold}-I, --exclude_isolates$norm ${under}LIST$norm
    Comma-separated list of isolate ids to ignore.

${bold}-l, --loci$norm ${under}LIST$norm
    Comma-separated list of loci to scan (ignored if -s used).

${bold}-L, --exclude_loci$norm ${under}LIST$norm
    Comma-separated list of loci to exclude

${bold}-m, --min_size$norm ${under}SIZE$norm
    Minimum size of seqbin (bp) - limit search to isolates with at least this
    much sequence.
           
${bold}-n, --new_only$norm
    New (previously untagged) isolates only.  Combine with --new_max_alleles
    if required.
    
${bold}--new_max_alleles$norm ${under}ALLELES$norm
    Set the maximum number of alleles that can be designated or sequences
    tagged before an isolate is not considered new when using the --new_only
    option.    

${bold}-o, --order$norm
    Order so that isolates last tagged the longest time ago get scanned first
    (ignored if -r used).
    
${bold}--only_already_tagged$norm
    Only check loci that already have a tag present (but no allele designation).
    This must be combined with the --already_tagged option or no loci will
    match. This option is used to perform a catch-up scan where a curator has
    previously tagged sequence regions prior to alleles being defined, without
    the need to scan all missing loci.
           
${bold}-p, --projects$norm ${under}LIST$norm
    Comma-separated list of project isolates to scan.

${bold}-P, --exclude_projects$norm ${under}LIST$norm
    Comma-separated list of projects whose isolates will be excluded.
        
${bold}-q, --quiet$norm
    Only error messages displayed.

${bold}-r, --random$norm
    Shuffle order of isolate ids to scan.
    
${bold}--reuse_blast$norm
    Reuse the BLAST database for every isolate (when running --fast option). 
    All loci will be scanned rather than just those missing from an isolate. 
    Consequently, this may be slower if isolates have already been scanned, 
    and for the first isolate scanned by a thread. On larger schemes, such as 
    wgMLST, or when isolates have not been previously scanned, setting up the
    BLAST database can take a significant amount of time, so this may be 
    quicker. This option is always selected if --new_only is used.

${bold}-R, --locus_regex$norm ${under}REGEX$norm
    Regex for locus names.

${bold}-s, --schemes$norm ${under}LIST$norm
    Comma-separated list of scheme loci to scan.

${bold}-t, --time$norm ${under}MINS$norm
    Stop after t minutes.

${bold}--threads$norm ${under}THREADS$norm
    Maximum number of threads to use.

${bold}-T, --already_tagged$norm
    Scan even when sequence tagged (no designation).
    
${bold}-v, --view$norm ${under}VIEW$norm
    Isolate database view (overrides value set in config.xml).

${bold}-w, --word_size$norm ${under}SIZE$norm
    BLASTN word size.

${bold}-x, --min$norm ${under}ID$norm
    Minimum isolate id.

${bold}-y, --max$norm ${under}ID$norm
    Maximum isolate id.
HELP
	return;
}
