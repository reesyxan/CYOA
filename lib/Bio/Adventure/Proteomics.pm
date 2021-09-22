package Bio::Adventure::Proteomics;
use Modern::Perl;
use autodie qw":all";
use diagnostics;
use feature 'try';
use warnings qw"all";
extends 'Bio::Adventure';


use File::Basename;
use File::Which qw"which";
use List::MoreUtils qw"uniq";
use Text::CSV_XS::TSV;

no warnings "experimental::try";

=head1 NAME
Bio::Adventure::Convert - Perform conversions between various formats.
=head1 SYNOPSIS
The functions here handle the various likely conversions one may perform.
sam to bam, gff to fasta, genbank to fasta, etc.
=head1 METHODS

=head2 C<ConvertProteomics>
$hpgl->Proteomics() calls (in order): samtools view, samtools sort,
and samtools index.  Upon completion, it invokes bamtools stats to
see what the alignments looked like.
It explicitly does not pipe one samtools invocation into the next,
not for any real reason but because when I first wrote it, it
seemed like the sorting was taking too long if I did not already
have the alignments in a bam file.
=over
=item I<input> * Input sam file.
=item I<species> * Input species prefix for finding a genome.
=back
=cut
sub ConvertProteomics {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['input', 'species'],
        jname => 'proteomics',
        jprefix => '',
        paired => 1,
        modules => 'samtools',);
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $input = $options->{input};

    my $output = $input;
    $output =~ s/\.sam$/\.bam/g;
    my $sorted_name = $input;
    $sorted_name =~ s/\.sam$//g;
    $sorted_name = qq"${sorted_name}-sorted";
    my $paired_name = $sorted_name;
    $paired_name =~ s/\-sorted/\-paired/g;
    ## Add a samtools version check because *sigh*
    my $samtools_version = qx"samtools 2>&1 | grep Version";
    ## Start out assuming we will use the new samtools syntax.
    my $samtools_first = qq"samtools view -u -t $options->{libdir}/genome/$options->{species}.fasta \\
  -S ${input} -o ${output} --write-index \\
  2>${output}.err 1>${output}.out && \\";
    my $samtools_second = qq"  samtools sort -l 9 ${output} -o ${sorted_name}.bam --write-index \\
  2>${sorted_name}.err 1>${sorted_name}.out && \\";
    ## If there is a 0.1 in the version string, then use the old syntax.
    if ($samtools_version =~ /0\.1/) {
        $samtools_first = qq"samtools view -u -t $options->{libdir}/genome/$options->{species}.fasta \\
  -S ${input} 1>${output} && \\";
        $samtools_second = qq"  samtools sort -l 9 ${output} ${sorted_name} --write-index \\
  2>${sorted_name}.err 1>${sorted_name}.out && \\";
    }
    my $jstring = qq!
if \$(test \! -r ${input}); then
    echo "Could not find the samtools input file."
    exit 1
fi
${samtools_first}
${samtools_second}
  rm ${output} && \\
  rm ${input} && \\
  mv ${sorted_name}.bam ${output} ## &&  samtools index ${output}
bamtools stats -in ${output} 2>${output}.stats 1>&2
!;
    if ($options->{paired}) {
        $jstring .= qq!
## The following will fail if this is single-ended.
samtools view -b -f 2 -o ${paired_name}.bam ${output} ## && samtools index ${paired_name}.bam
bamtools stats -in ${paired_name}.bam 2>${paired_name}.stats 1>&2
##bamtools filter -tag XM:0 -in ${output} -out ${sorted_name}_nomismatch.bam &&
##  samtools index ${sorted_name}_nomismatch.bam
!;
    }
    my $comment = qq!## Converting the text sam to a compressed, sorted, indexed bamfile.
## Also printing alignment statistics to ${output}.stats
## This job depended on: $options->{jdepends}!;
    my $jobname = qq"$options->{jname}_$options->{species}";
    my $samtools = $class->Submit(
        comment => $comment,
        depends => $options->{jdepends},
        input => $input,
        jmem => '28',
        jname => $jobname,
        jprefix => $options->{jprefix},
        jqueue => 'throughput',
        jstring => $jstring,
        output => qq"${output}",
        paired => $options->{paired},
        paired_output => qq"${paired_name}.bam",
        postscript => $options->{postscript},
        prescript => $options->{prescript},);
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload',);
    return($samtools);
}

=head1 AUTHOR - atb
Email abelew@gmail.com
=head1 SEE ALSO
L<samtools> L<Bio::FeatureIO> L<Bio::Tools::GFF> L<Bio::Seq> L<Bio::SeqIO>
=cut

1;
