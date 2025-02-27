package Bio::Adventure::Count;
## LICENSE: gplv2
## ABSTRACT:  Kitty!
use Modern::Perl;
use autodie qw":all";
use diagnostics;
use warnings qw"all";
use Moo;
extends 'Bio::Adventure';

use Bio::Tools::GFF;
use Cwd;
use File::Basename;
use File::Path qw"make_path";
use File::Which qw"which";
use String::Approx qw"amatch";

=head1 NAME

Bio::Adventure::Count - Perform Sequence alignments counting with HTSeq

=head1 SYNOPSIS

These functions handle the counting of reads, primarily via htseq.

=head1 METHODS

=head2 C<HT_Multi>

Invoke htseq multiple times with options for counting different transcript types.

=cut
sub HT_Multi {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['species', 'input', 'htseq_stranded'],
        gff_type => '',
        htseq_type => 'gene',
        htseq_id => 'ID',
        libtype => 'genome',
        modules => 'htseq',
        paired => 1,
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $check = which('htseq-count');
    die('Could not find htseq in your PATH.') unless($check);

    my %ro_opts = %{$options};
    my $species = $options->{species};
    my $htseq_input = $options->{input};
    my $stranded = $options->{htseq_stranded};
    my $htseq_type = $options->{htseq_type};
    my $htseq_id = $options->{htseq_id};
    my @jobs = ();
    my $script_suffix = qq"";
    if ($args{suffix}) {
        $script_suffix = $args{suffix};
    }
    my $jprefix = "";
    $jprefix = $args{jprefix} if ($args{jprefix});
    my @gff_types = ('antisense', 'exon', 'fiveputr', 'interCDS',
                     'linc', 'mi', 'misc', 'nmd', 'operons', 'pseudo',
                     'rintron', 'rrna', 'sn', 'sno', 'threeputr');
    my $htseq_runs = 0;
    ## Top level directory containing the input files.
    my $top_dir = basename(getcwd());
    ## The sam/bam input basename
    my $output_name = basename($htseq_input, ('.bam', '.sam'));

    foreach my $gff_type (@gff_types) {
        my $gff = qq"$options->{libdir}/genome/${species}_${gff_type}.gff";
        my $gtf = $gff;
        $gtf =~ s/\.gff/\.gtf/g;
        my $htseq_jobname = qq"hts_${gff_type}_${output_name}_$options->{species}_s${stranded}_${htseq_type}_${htseq_id}";
        if (-r "$gff") {
            print "Found $gff, performing htseq with it.\n";
            my $ht = $class->Bio::Adventure::Count::HTSeq(
                htseq_gff => $gff,
                input => $htseq_input,
                gff_type => $gff_type,
                htseq_type => undef, ## Force HTSeq to detect this.
                htseq_id => $options->{htseq_id},
                jdepends => $options->{jdepends},
                jname => $htseq_jobname,
                jprefix => $jprefix,
                jqueue => 'throughput',
                postscript => $options->{postscript},
                prescript => $options->{prescript},
                suffix => $options->{suffix},
            );
            push(@jobs, $ht);
            $htseq_runs++;
        } elsif (-r "$gtf") {
            print "Found $gtf, performing htseq with it.\n";
            my $ht = $class->Bio::Adventure::Count::HTSeq(
                gff_type => $gff_type,
                htseq_gff => $gtf,
                htseq_type => undef,
                htseq_id => $options->{htseq_id},
                input => $htseq_input,
                jdepends => $options->{jdepends},
                jname => $htseq_jobname,
                jprefix => $options->{jprefix},
                jqueue => 'throughput',
                postscript => $options->{postscript},
                prescript => $options->{prescript},
                suffix => $options->{suffix},
            );
            push(@jobs, $ht);
            $htseq_runs++;
        }
    } ## End foreach type
    ## Also perform a whole genome count
    my $gff = qq"$options->{libdir}/genome/${species}.gff";
    my $gtf = $gff;
    $gtf =~ s/\.gff/\.gtf/g;
    my $htall_jobname = qq"htall_${output_name}_$options->{species}_s${stranded}_$ro_opts{htseq_type}_$ro_opts{htseq_id}";
    if (-r "$gff") {
        print "Found $gff, performing htseq_all with it.\n";
        my $ht = $class->Bio::Adventure::Count::HTSeq(
            gff_type => '',
            htseq_gff => $gff,
            htseq_id => $ro_opts{htseq_id},
            htseq_type => $ro_opts{htseq_type},
            input => $htseq_input,
            jdepends => $options->{jdepends},
            jname => $htall_jobname,
            jprefix => $jprefix,
            jqueue => 'throughput',
            postscript => $options->{postscript},
            prescript => $options->{prescript},
            suffix => $options->{suffix},
        );
        push(@jobs, $ht);
    } elsif (-r "$gtf") {
        print "Found $gtf, performing htseq_all with it.\n";
        my $ht = $class->Bio::Adventure::Count::HTSeq(
            gff_type => '',
            htseq_gff => $gff,
            htseq_type => "none",
            input => $htseq_input,
            jdepends => $options->{jdepends},
            jname => $htall_jobname,
            jprefix => $jprefix,
            jqueue => 'throughput',
            postscript => $args{postscript},
            prescript => $args{prescript},
            suffix => $args{suffix},
        );
        push(@jobs, $ht);
    } else {
        print "Did not find ${gff} nor ${gtf}, not running htseq_all.\n";
    }
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return(\@jobs);
}

=head2 C<HT_TYPES>

Read the first 100k lines of a gff file and use that to guess at the most likely
type of feature when invoking htseq.

FIXME: max_lines should be an option!

=cut
sub HT_Types {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        htseq_type => 'gene',
        htseq_id => 'ID',
    );
    my $my_type = $options->{htseq_type};
    my $my_id = $options->{htseq_id};
    print "Calling htseq with options for type: $my_type and tag: $my_id\n";
    $my_type = "" unless($my_type);
    $my_type = "" unless($my_id);
    my $gff_out = {};
    my $max_lines = 100000;
    my $count = 0;
    my %found_types = ();
    my %found_canonical = ();
    my $reader = new FileHandle("<$options->{annotation}");
  LOOP: while(my $line = <$reader>) {
        chomp $line;
        next LOOP if ($line =~ /^\#/);
        $count++;
        ## chr1    unprocessed_pseudogene  transcript      3054233 3054733 .       +       .       gene_id "ENSMUSG00000090025"; transcript_id "ENSMUST00000160944"; gene_name "Gm16088"; gene_source "havana"; gene_biotype "pseudogene";transcript_name "Gm16088-001"; transcript_source "havana"; tag "cds_end_NF"; tag "cds_start_NF"; tag "mRNA_end_NF"; tag "mRNA_start_NF";

        my ($chromosome, $source, $type, $start, $end, $score, $strand, $frame, $attributes) = split(/\t/, $line);
        my @attribs = split(/;\s*/, $attributes);
        my (@pairs, @names, @values) = ();
        my $splitter = '\s+';
        if ($attribs[0] =~ /=/) {
            $splitter = '=';
        }
        for my $attrib (@attribs) {
            my ($name, $value) = split(/$splitter/, $attrib);
            push(@names, $name);
            push(@values, $value);
        }
        my $canonical = $names[0];
        if ($found_types{$type}) {
            $found_types{$type}++;
        } else {
            $found_types{$type} = 1;
        }
        if ($found_canonical{$canonical}) {
            $found_canonical{$canonical}++;
        } else {
            $found_canonical{$canonical} = 1;
        }
        if ($count > $max_lines) {
            last LOOP;
        }
    } ## End loop
    $reader->close();
    my $found_my_type = 0;
    my $max_type = "";
    my $max = 0;
    foreach my $type (keys %found_types) {
        if ($found_types{$type} > $max) {
            $max_type = $type;
            $max = $found_types{$type};
        }
        if ($found_types{$my_type}) {
            print "The specified type: ${my_type} is in the gff file, comprising $found_types{$my_type} of the first 40,000.\n";
            $found_my_type = 1;
        }
    } ## End the loop

    my $max_can = 0;
    my $max_canonical = 0;
    foreach my $can (keys %found_canonical) {
        if (!defined($found_canonical{$can})) {
            $found_canonical{$can} = 0;
        }
        if ($found_canonical{$can} > $max_canonical) {
            $max_can = $can;
            $max_canonical = $found_canonical{$can};
        }
    } ## End the loop
    my $returned_canonical = $max_can;

    my $returned_type = "";
    if ($found_my_type == 1) {
        $returned_type = $my_type;
    } else {
        print "Did not find your specified type.  Changing it to: ${max_type} which had ${max} entries.\n";
        $returned_type = $max_type;
    }
    my $ret = [$returned_type, $returned_canonical];
    return($ret);
}

=head2 C<HTSeq>

Invoke htseq-count.

=cut
sub HTSeq {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ["input", "species", "htseq_stranded", "htseq_args",],
        gff_type => '',
        htseq_type => 'gene',
        htseq_id => 'ID',
        jname => '',
        jprefix => '',
        libtype => 'genome',
        mapper => 'hisat2',
        modules => 'htseq',
        paired => 1,
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $stranded = $options->{htseq_stranded};
    my $htseq_type = $options->{htseq_type};
    my $htseq_id = $options->{htseq_id};
    my $htseq_input = $options->{input};
    my $gff_type = 'all';
    if ($options->{gff_type} ne '') {
        $gff_type = $options->{gff_type};
    }
    ## Top level directory containing the input files.
    my $top_dir = basename(getcwd());
    ## The sam/bam input basename
    my $output_name = basename($htseq_input, ('.bam', '.sam'));
    ## And directory containing it.
    my $output_dir = dirname($htseq_input);
    my $output = qq"${output_dir}/${output_name}";
    my $gff = qq"$options->{libdir}/$options->{libtype}/$options->{species}.gff";
    $gff = $args{htseq_gff} if ($args{htseq_gff});
    my $gtf = $gff;
    $gtf =~ s/\.gff/\.gtf/g;
    my $htseq_args = "";

        ## Set the '-t FEATURETYPE --type' argument used by htseq-count
    ## This may be provided by a series of defaults in %HT_Multi::gff_types, overridden by an argument
    ## Or finally auto-detected by HT_Types().
    ## This is imperfect to say the nicest thing possible, I need to consider more appropriate ways of handling this.
    my $htseq_type_arg = "";
    my $htseq_id_arg = "";

    my $annotation = $gtf;
    if (!-r "${gtf}") {
        $annotation = $gff;
    }
    if (!defined($htseq_type) or $htseq_type eq '' or $htseq_type eq 'auto' or
            !defined($htseq_id) or $htseq_id eq '' or $htseq_id eq 'auto') {
        my $htseq_type_pair = $class->Bio::Adventure::Count::HT_Types(
            annotation => $annotation,
            type => $htseq_type,
            );
        $htseq_type = $htseq_type_pair->[0];
        $htseq_type_arg = qq" --type ${htseq_type}";
        $htseq_id_arg = qq" --idattr ${htseq_id}"
    } elsif (ref($htseq_type) eq "ARRAY") {
        $htseq_type_arg = qq" --type $htseq_type->[0]";
        $htseq_id_arg = qq" --idattr ${htseq_id}";
    } elsif ($htseq_type eq 'none') {
        $htseq_type_arg = qq"";
        $htseq_id_arg = qq"";
    } else {
        $htseq_type_arg = qq" --type ${htseq_type}";
        $htseq_id_arg = qq" --idattr ${htseq_id}";
    }
    
    if ($options->{suffix}) {
        $output = qq"${output}_$options->{suffix}.count";
    } else {
        $output = qq"${output}_${gff_type}_$options->{species}_s${stranded}_${htseq_type}_${htseq_id}.count";
    }
    if (!-r "${gff}" and !-r "${gtf}") {
        die("Unable to read ${gff} nor ${gtf}, please fix this and try again.\n");
    }
    my $error = basename($output, ('.count'));
    $error = qq"${output_dir}/${error}.err";

    my $htseq_jobname = qq"hts_${top_dir}_${gff_type}_$options->{mapper}_$options->{species}_s${stranded}_${htseq_type}_${htseq_id}";
    ## Much like samtools, htseq versions on travis are old.
    ## Start with the default, non-stupid version.
    my $htseq_version = qx"htseq-count -h | grep version";
    my $htseq_invocation = qq!htseq-count  --help 2>&1 | tail -n 3
htseq-count \\
  -q -f bam -s ${stranded} ${htseq_type_arg} ${htseq_id_arg} \\!;
    if ($htseq_version =~ /0\.5/) {
        ## Versions older than 0.6 are stupid.
        $htseq_invocation = qq!samtools view ${htseq_input} | htseq-count -q -s ${stranded} ${htseq_id_arg} ${htseq_type_arg} \\!;
        $htseq_input = '-';
    }
    my $jstring = qq!
${htseq_invocation}
  ${htseq_input} \\
  ${annotation} \\
  2>${error} \\
  1>${output} && \\
    xz -f -9e ${output} 2>${error}.xz 1>${output}.xz
!;
    my $comment = qq!## Counting the number of hits in ${htseq_input} for each feature found in ${annotation}
## Is this stranded? ${stranded}.  The defaults of htseq are:
## $options->{htseq_args}
!;
    my $htseq = $class->Submit(
        comment => $comment,
        gff_type => $options->{gff_type},
        input => $htseq_input,
        jdepends => $options->{jdepends},
        jmem => 6,
        jname => $htseq_jobname,
        jprefix => $options->{jprefix},
        jqueue => 'throughput',
        jstring => $jstring,
        output => $output,
        postscript => $args{postscript},
        prescript => $args{prescript},
        );
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($htseq);
}

=head2 C<Mi_Map>

Given a set of alignments, map reads to mature/immature miRNA species.

=cut
sub Mi_Map {
    my ($class, %args) = @_;
    eval "use Bio::DB::Sam; 1;";
    my $options = $class->Get_Vars(
        args => \%args,
        required => ["mirbase_data", "mature_fasta",
                     "mi_genome", "bamfile",]
    );
    my $bam_base = basename($options->{bamfile}, (".bam", ".sam"));
    my $pre_map = qq"${bam_base}_mirnadb.txt";
    my $final_map = qq"${bam_base}_mature.count";

    ## Step 1:  Read the mature miRNAs to get the global IDs and sequences of the longer transcripts.
    ## This provides the IDs as 'mm_miR_xxx_3p' and short sequences ~21 nt.
    print "Starting to read miRNA sequences.\n";
    my $sequence_db = Bio::Adventure::Count::Read_Mi(
        $class,
        seqfile => $options->{mature_fasta},
    );

    ## Step 2:  Collate those IDs against the set of miRNA_transcripts->miRNA_mature IDs using
    ## the tab delimited file downloaded from mirbase.org
    print "Starting to read miRNA mappings.\n";
    my $sequence_mappings = Bio::Adventure::Count::Read_Mappings_Mi(
        $class,
        mappings => $options->{mirbase_data},
        output => $pre_map,
        seqdb => $sequence_db,
    );
    ## At this point, we have brought together mature sequence/mature IDs to parent transcript IDs
    ## When we read the provided bam alignment, we will simultaneously read the immature miRNA database
    ## and use them to make a bridge from the mature sequence/IDs to immature miRNA IDs.
    my $final_hits = Bio::Adventure::Count::Read_Bam_Mi(
        $class,
        mappings => $sequence_mappings,
        mi_genome => $options->{mi_genome},
        bamfile => $options->{bamfile},
    );
    my $printed = Bio::Adventure::Count::Final_Print_Mi(
        $class,
        data => $final_hits,
        output => $final_map,
    );

    my $job = $printed;
    $job->{final_hits} = $final_hits;
    return($job);    
} ## End of Mi_Map

=head2 C<Read_Mi>

Read an miRNA database.

=cut
sub Read_Mi {
    my ($class, %args) = @_;
    my $fasta = Bio::SeqIO->new(-file => $args{seqfile}, -format => "Fasta");
    my %sequences = ();
    while (my $mi_seq = $fasta->next_seq()) {
        next unless(defined($mi_seq->id));
        my $id = $mi_seq->id;
        my $length = $mi_seq->length;
        my $seq = $mi_seq->seq;
        $sequences{$id}->{sequence} = $seq;
    }
    return(\%sequences);
}

=head2 C<Read_Mappings_Mi>

Read an miRNA database and get the connections between the various IDs, mature
sequences, and immature sequences.

=cut
sub Read_Mappings_Mi {
    my ($class, %args) = @_;
    my $output = $args{output};
    my $seqdb = $args{seqdb};
    my $inmap = new FileHandle($args{mappings});
    my $mimap = {};
    while (my $line = <$inmap>) {
        chomp $line;
        $line =~ s/"//g;
        my ($hit_id, $ensembl, $mirbase_id, $fivep_mature, $fivep_id, $threep_mature, $threep_id) = split(/\s+/, $line);
        if (defined($fivep_id) and $fivep_id ne "") {
            $mimap->{$fivep_id}->{mirbase_id} = $mirbase_id;
            $mimap->{$fivep_id}->{hit_id} = $hit_id;
            $mimap->{$fivep_id}->{ensembl} = $ensembl;
            $mimap->{$fivep_id}->{mimat} = $fivep_id;
        }
        if (defined($threep_id) and $threep_id ne "") {
            $mimap->{$threep_id}->{mirbase_id} = $mirbase_id;
            $mimap->{$threep_id}->{hit_id} = $hit_id;
            $mimap->{$threep_id}->{ensembl} = $ensembl;
            $mimap->{$threep_id}->{mimat} = $threep_id;
        }
    }
    $inmap->close();
    my $out = FileHandle->new(">${output}");
    ## Now re-key the database of miRNAs so that there are (potentially) multiple elements to each mirbase ID
    ## This is a bit redundant, but hopefully clearer.  The idea is to first gather all miR data, then make a list of specific
    ## ID/sequences for each mature miRNA child of the mirbase_id parent entry.  Eg:
    ## mirbase_id parent ->  [ mature_id1, mature_id2, ... ]
    ## where each mature_id is a { sequence, count, id, ensembl, ... }
    my $newdb = {};
  LOOP: foreach my $id (keys %{$seqdb}) {
        next LOOP unless ($id =~ /^mmu/);
        my @hit_list = ();
        if (defined($mimap->{$id})) {
            ##print "Found $id across the mappings.\n";
            my $new_id = $id;
            my $sequence = $seqdb->{$id}->{sequence};
            if ($mimap->{$id}->{hit_id}) {
                $new_id = $mimap->{$id}->{hit_id};
            }
            my $element = {
                count => 0,
                ensembl => $mimap->{$id}->{ensembl},
                hit_id => $mimap->{$id}->{hit_id},
                id => $id,
                mimat => $mimap->{$id}->{mimat},
                mirbase_id => $mimap->{$id}->{mirbase_id},
                sequence => $sequence,
            };
            my $ensembl_id = $element->{ensembl};
            if (defined($newdb->{$ensembl_id})) {
                ## Then there should be an existing element, append to it.
                @hit_list = @{$newdb->{$ensembl_id}};
                push(@hit_list, $element);
                ## $newdb->{$new_id} = \@hit_list;
                $newdb->{$ensembl_id} = \@hit_list;
                print $out "$id; $element->{mirbase_id}; $element->{ensembl}; $element->{hit_id}; $element->{mimat}; $element->{sequence}\n";
            } else {
                @hit_list = ();
                push(@hit_list, $element);
                ## $newdb->{$new_id} = \@hit_list;
                $newdb->{$ensembl_id} = \@hit_list;
            }
        } else {
            ## print "Did not find $id\n";
        }
    }
    $out->close();
    return($newdb);
}

=head2 C<Read_Bam_Mi>

Read a bam file and cross reference it against an miRNA database.

=cut
sub Read_Bam_Mi {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
    );
    my $mappings = $args{mappings};
    my $sam = Bio::DB::Sam->new(-bam => $args{bamfile}, -fasta=> $args{mi_genome},);
    my $bam = $sam->bam;
    my $header = $bam->header;
    my $target_count = $header->n_targets;
    my $target_names = $header->target_name;
    my $align_count = 0;
    print "Started reading bamfile.\n";
    ## I probably don't need to acquire most of this information, as I am only really taking
    ## the read_seq and read_seqid
  BAM: while (my $align = $bam->read1) {
        if ($options->{debug}) {
            last BAM if ($align_count > 4000);
        }
        my $read_seqid = $target_names->[$align->tid];
        ## my $read_start = $align->pos + 1;
        ## my $read_end = $align->calend;
        ## my $read_strand = $align->strand;
        ## my $read_cigar = $align->cigar_str;
        ## my @read_scores = $align->qscore;        # per-base quality scores
        ## my $read_match_qual= $align->qual;       # quality of the match
        ## my $read_length = $align->query->end;
        my $read_seq = $align->query->seq->seq; ## maybe?
        $align_count++;

        ## Check each element in the mappings to see if they are contained in the read's sequence and vice versa.
        ## If so, increment the count for that element and move on.
        $read_seqid =~ s/^chr[\d+]_//g;
        if ($mappings->{$read_seqid}) {
            my @element_list = @{$mappings->{$read_seqid}};
            my $found_element = 0;
            my $element_length = scalar(@element_list);
            ## print "Found map, checking against ${element_length} mature RNAs.\n";

            foreach my $c (0 .. $#element_list) {
                my $element_datum = $element_list[$c];
                my $element_seq = $element_list[$c]->{sequence};
                ## print "Comparing: $read_seq vs. $element_seq\n";

                my @read_vs_element = amatch($read_seq, [ 'S1' ], ($element_seq));
                my @element_vs_read = amatch($element_seq, [ 'S1' ], ($read_seq));
                if (scalar(@read_vs_element) > 0 or scalar(@element_vs_read) > 0) {
                    $mappings->{$read_seqid}->[$c]->{count}++;
                    ##print "Found hit with amatch against $element_seq: ";
                    ##print "We need to get the slot in position: {ensembl_id} -> [c] -> {id}\n";
                    ##print "is read_seqid ensembl? $read_seqid  \n";
                    ##print "Incremented $mappings->{$read_seqid}->[$c]->{id} to $mappings->{$read_seqid}->[$c]->{count}\n";
                    $found_element = 1;
                }
                ## if ($read_seq =~ /$element_seq/ or $element_seq =~ /$read_seq/) {
                ##     $mappings->{$read_seqid}->[$c]->{count}++;
                ##     print "Using an exact match: ";
                ##     print "Incremented $mappings->{$read_seqid}->[$c]->{mirbase_id} to $mappings->{$read_seqid}->[$c]->{count}\n";
                ##     $found_element = 1;
                ## }
            }
            ##if ($found_element == 0) {
            ##    print "No map for $read_seq\n";
            ##}
        }
    } ## Finish iterating through every read
    return($mappings);
}

=head2 C<Final_Print_Mi>

Print out the final counts of miRNA mappings.

=cut
sub Final_Print_Mi {
    my ($class, %args) = @_;
    my $final = $args{data};
    my $output = FileHandle->new(">$args{output}");
    my $hits = 0;
    foreach my $immature (keys %{$final}) {
        foreach my $mature (@{$final->{$immature}}) {
            $hits = $hits++;
            print $output "$mature->{mimat} $mature->{count}\n";
        }
    }
    $output->close();
    return($hits);
}                               ## End of Final_Print

sub Count_Alignments {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['input', 'genome'],
        para_pattern => '^Tc',
        host_pattern => '',
    );
    my $result = {
        mapped => 0,
        unmapped => 0,
        multi_count => 0,
        single_count => 0,
        unmapped_count => 0,
        single_para => 0,       ## Single-hit parasite
        single_host => 0,       ## Single-hit host
        multi_host => 0, ## Multi-hit host -- keep in mind htseq will not count these.
        multi_para => 0, ## Ditto parasite
        single_both => 0, ## These are the dangerzone reads, 1 hit on both. -- false positives
        single_para_multi_host => 0,
        single_host_multi_para => 0,
        multi_both => 0,      ## These have multi on both and are not a problem.
        zero_both => 0,       ## This should stay zero.
        wtf => 0,
    };

    my %group = (
        para => 0,
        host => 0,
    );
    my %null_group = (
        para => 0,
        host => 0,
    );

    my $fasta = qq"$options->{libdir}/$options->{libtype}/$options->{species}.fasta";
    my $sam = Bio::DB::Sam->new(-bam => $options->{input},
                                -fasta => $fasta,);
    my @targets = $sam->seq_ids;
    my $num = scalar(@targets);
    my $bam = Bio::DB::Bam->open($options->{input});
    my $header = $bam->header;
    my $target_count = $header->n_targets;
    my $target_names = $header->target_name;
    my $align_count = 0;
    my $million_aligns = 0;
    my $alignstats = qx"samtools idxstats $options->{input}";
    my @alignfun = split(/\n/, $alignstats);
    my @aligns = split(/\t/, $alignfun[0]);
    my @unaligns = split(/\t/, $alignfun[1]);
    my $number_reads = $aligns[2] + $unaligns[3];
    my $output_name = qq"$options->{input}.out";
    my $out = FileHandle->new(">${output_name}");
    print $out "There are ${number_reads} alignments in $options->{input} made of $aligns[2] aligned reads and $unaligns[3] unaligned reads.\n";
    my $last_readid = "";
  BAMLOOP: while (my $align = $bam->read1) {
        $align_count++;
        ##if ($class->{debug}) {  ## Stop after a relatively small number of reads when debugging.
        ##    last BAMLOOP if ($align_count > 200);
        ##}
        if (($align_count % 1000000) == 0) {
            $million_aligns++;
            print $out "Finished $million_aligns million alignments out of ${number_reads}.\n";
        }
        my $seqid = $target_names->[$align->tid];
        my $readid = $align->qname;
        ## my $start = $align->pos + 1;
        ## my $end = $align->calend;
        my $start = $align->pos;
        my $end = $align->calend - 1;
        my $cigar = $align->cigar_str;
        my $strand = $align->strand;
        my $seq = $align->query->dna;
        my $qual= $align->qual;
        if ($cigar eq '') {
            $result->{unmapped}++;
            ##print "$result->{unmapped} $readid unaligned.\n";
            next BAMLOOP;
        } else {
            ## Everything which follows is for a mapped read.
            $result->{mapped}++;
            my $type;
            if ($options->{para_pattern}) {
                if ($seqid =~ m/$options->{para_pattern}/) {
                    $type = 'para';
                } else {
                    $type = 'host';
                }
            } elsif ($options->{host_pattern}) {
                if ($seqid =~ m/$options->{host_pattern}/) {
                    $type = 'host';
                } else {
                    $type = 'para';
                }
            }
            if ($readid ne $last_readid) {
                ## Count up what is currently in the group, then reset it.
                my $reads_in_group = $group{host} + $group{para};
                if ($reads_in_group > 1) {
                    $result->{multi_count}++;
                } elsif ($reads_in_group == 1) {
                    $result->{single_count}++;
                } else {
                    $result->{unmapped_count}++;
                }
                if ($group{host} == 0) {
                    if ($group{para} == 0) {
                        $result->{zero_both}++;
                    } elsif ($group{para} == 1) {
                        $result->{single_para} = $result->{single_para} + $reads_in_group;
                    } elsif ($group{para} > 1) {
                        $result->{multi_para} = $result->{multi_para} + $reads_in_group;
                    } else {
                        $result->{wtf}++;
                    }
                } elsif ($group{host} == 1) {
                    if ($group{para} == 0) {
                        $result->{single_host} = $result->{single_host} + $reads_in_group;
                    } elsif ($group{para} == 1) {
                        $result->{single_both} = $result->{single_both} + $reads_in_group;
                    } elsif ($group{para} > 1) {
                        $result->{single_host_multi_para} = $result->{single_host_multi_para} + $reads_in_group;
                    } else {
                        $result->{wtf}++;
                    }
                } elsif ($group{host} > 1) {
                    if ($group{para} == 0) {
                        $result->{multi_host} = $result->{multi_host} + $reads_in_group;
                    } elsif ($group{para} == 1) {
                        $result->{single_para_multi_host} = $result->{single_para_multi_host} + $reads_in_group;
                    } elsif ($group{host} > 1) {
                        $result->{multi_both} = $result->{multi_both} + $reads_in_group;
                    } else {
                        $result->{wtf}++;
                    }
                } else {
                    $result->{wtf}++;
                }
                print "Map:$result->{mapped} Un:$result->{unmapped} SingleC:$result->{single_count} MultC:$result->{multi_count} sp:$result->{single_para} sh:$result->{single_host} mh:$result->{multi_host} mp:$result->{multi_para} SB:$result->{single_both} spmh:$result->{single_para_multi_host} shmp:$result->{single_host_multi_para} bm:$result->{multi_both} bz:$result->{zero_both} wtf:$result->{wtf}\n" if ($options->{debug});
                %group = %null_group;
                ## Now set the first read for the new group to the type of this read.
                $group{$type}++;
            } else {
                $group{$type}++;
            }
        }
        $last_readid = $readid;
    } ## End reading each bam entry
    print $out "Mapped: $result->{mapped}
Unmapped: $result->{unmapped}
Multi-mapped: $result->{multi}
Single-parasite: $result->{single_para}
Single-host: $result->{single_host}
Multi-parasite, no host: $result->{multi_para}
Multi-host, no parasite: $result->{multi_host}
DANGER Single-both: $result->{single_both}
DANGER Single-parasite, multi-host: $result->{single_para_multi_host}
DANGER Single-host, multi-parasite: $result->{single_host_multi_para}
Multi-both: $result->{both_multi}\n";
    $out->close();
    return($result);
}

=head1 AUTHOR - atb

Email <abelew@gmail.com>

=head1 SEE ALSO

    L<htseq-count> L<Bio::DB::Sam> L<Bio::SeqIO>

=cut

1;
