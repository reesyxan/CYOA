package Bio::Adventure::Assembly;
## LICENSE: gplv2
## ABSTRACT:  Kitty!
use Modern::Perl;
use autodie qw":all";
use diagnostics;
use feature 'try';
use warnings qw"all";
no warnings 'experimental::try';
use Moo;
extends 'Bio::Adventure';

use Cwd qw"abs_path getcwd cwd";
use File::Basename;
use File::Spec;
use File::Which qw"which";
use Parse::CSV;

use Bio::Tools::Run::Alignment::StandAloneFasta;

no warnings 'experimental::try';

=head1 NAME

Bio::Adventure::Assembly - Perform some de-novo assembly tasks.

=head1 SYNOPSIS

Invocations for a few assemblers: Abyss, Shovill/Unicycler (spades), trinity.

=head1 METHODS

=head2 C<Abyss>

This defaults to a k=41 abyss-pe or abyss-se assembly, depending on
how many input files provided.  Ideally, it should at least do a
little work to try to optimize k.  Abyss is the first program I have
ever seen which uses make as an interpreter.

=cut
sub Abyss {
    my ($class, %args) = @_;
    ## abyss-pe k=41 name=EAb01 in="r1_trimmed-corrected.fastq.gz r2_trimmed-corrected.fastq.gz"
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['input'],
        k => 41,
        modules => 'abyss',);
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $check = which('abyss-pe');
    die("Could not find abyss in your PATH.") unless($check);

    my $job_name = $class->Get_Job_Name();
    my %abyss_jobs = ();
    my $outname = basename(cwd());
    my $output_dir = qq"outputs/abyss_${outname}";
    my $k_string = qq"k=$options->{k} ";
    my $name_string = qq"name=${outname} ";
    my $input_string = "";
    my $executable = "abyss-pe";
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        my $r1 = abs_path($in[0]);
        my $r2 = abs_path($in[1]);
        $input_string = qq!in="${r1} ${r2}" !;
    } else {
        my $r1 = abs_path($options->{input});
        $input_string = qq!in=${r1} "!;
        $executable = "abyss-se"
    }
    my $comment = qq!## This is a abyss submission script
!;
    my $jstring = qq!start=\$(pwd)
mkdir -p ${output_dir}
cd ${output_dir}
rm -f ./*
${executable} -C \$(pwd) \\
    ${k_string} ${name_string} \\
    ${input_string} \\
    2>abyss_${outname}.err \\
    1>abyss_${outname}.out
cd \${start}
!;
    my $abyss = $class->Submit(
        cpus => 6,
        comment => $comment,
        jdepends => $options->{jdepends},
        jname => "abyss_${job_name}",
        jprefix => $options->{jprefix},
        jstring => $jstring,
        jmem => 30,
        output => qq"${output_dir}/${outname}.fasta",
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        jqueue => "workstation",
        jwalltime => "4:00:00",
        );
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($abyss);
}



sub Assembly_Coverage {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        ## input is the corrected/filtered reads, library is the assembly
        jprefix => 14,
        required => ['input', 'library'],
        modules => ['hisat', 'bbmap'],
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});

    my $job_name = $class->Get_Job_Name();

    my $outname = basename(cwd());
    my $output_dir = qq"outputs/$options->{jprefix}assembly_coverage_${outname}";
    my $input_string = '';
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        my $r1 = abs_path($in[0]);
        my $r2 = abs_path($in[1]);
        $input_string = qq"-1 ${r1} -2 ${r2} ";
    } else {
        my $r1 = abs_path($options->{input});
        $input_string = qq"-1 ${r1} ";
    }
    my $comment = qq!## This is a script to remap the reads against an assembly
and calculate the coverage by contig.
!;
    my $jstring = qq!start=\$(pwd)
mkdir -p ${output_dir}
hisat2-build $options->{library} ${output_dir}/coverage_test
hisat2 -x ${output_dir}/coverage_test -q \\
  ${input_string} -S ${output_dir}/coverage.sam \\
  2>coverage_hisat.err 1>coverage_hisat.out
pileup.sh in=${output_dir}/coverage.sam out=${output_dir}/coverage.txt overwrite=true
samtools view -u -t $options->{library} \\
  -S ${output_dir}/coverage.sam -o ${output_dir}/coverage.bam \\
  2>coverage_samtools.err 1>coverage_samtools.out
rm ${output_dir}/coverage.sam
samtools sort -l 9 ${output_dir}/coverage.bam -o ${output_dir}/coverage_sorted.bam
mv ${output_dir}/coverage_sorted.bam ${output_dir}/coverage.bam
samtools index ${output_dir}/coverage.bam
!;
    my $coverage = $class->Submit(
        cpus => 6,
        comment => $comment,
        jdepends => $options->{jdepends},
        jname => qq"coverage_${job_name}",
        jprefix => '46',
        jstring => $jstring,
        jmem => $options->{jprefix},
        jqueue => 'workstation',
        jwalltime => '4:00:00',
        output => qq"${output_dir}/coverage.txt",
        output_bam => qq"${output_dir}/coverage.bam",
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        );
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($coverage);
}


=head2 C<Shovill>

Use shovill to perform/optimize a spades assembly.  Shovill has a lot
of interesting options, this only includes a few at the moment.

=cut
sub Shovill {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['input'],
        depth => 40,
        jprefix => '13',
        arbitrary => '',
        modules => 'shovill',
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $check = which('shovill');
    die("Could not find shovill in your PATH.") unless($check);    
    my $job_name = $class->Get_Job_Name();
    my $outname = basename(cwd());
    my $output_dir = qq"outputs/$options->{jprefix}shovill";
    my $input_string = "";
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        $input_string = qq" -R1 $in[0] -R2 $in[1]";
    } else {
        $input_string = qq" -R1 $options->{input}";
    }
    my $comment = qq!## This is a shovill submission script
!;
    my $jstring = qq!mkdir -p ${output_dir}
shovill $options->{arbitrary} --force --keepfiles --depth $options->{depth} \\
   --outdir ${output_dir} \\
  $input_string \\
  2>${output_dir}/shovill_${outname}.err \\
  1>${output_dir}/shovill_${outname}.out
if [[ -f ${output_dir}/contigs.fa ]]; then
  mv ${output_dir}/contigs.fa ${output_dir}/final_assembly.fasta
elif [[ -f ${output_dir}/spades.fasta.uncorrected ]]; then
  cp ${output_dir}/spades.fasta.uncorrected ${output_dir}/final_assembly.fasta
else
  mv ${output_dir}/spades.fasta ${output_dir}/final_assembly.fasta
fi
!;
    my $shovill_job = $class->Submit(
        cpus => 6,
        comment => $comment,
        jdepends => $options->{jdepends},
        jname => qq"shovill_${job_name}",
        jprefix => $options->{jprefix},
        jstring => $jstring,
        jmem => 30,
        jqueue => 'workstation',
        jwalltime => '4:00:00',
        output => qq"${output_dir}/final_assembly.fasta",
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        );
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($shovill_job);
}


=head2 C<Trinity>

$hpgl->Trinity() submits a trinity denovo sequence assembly and runs its default
post-processing tools.

=over

=item I<input> * File(s) containing reads to be assembled by trinity.

=item I<contig_length> (600) Minimum length for a contig to keep.

=back

=head3 C<Invocation>

> cyoa --task assembly --method trinity --input forward.fastq.gz:reverse.fastq.gz

=cut
sub Trinity {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        contig_length => 600,
        modules => 'trinity',
        required => ['input'],
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $check = which('Trinity');
    die("Could not find trinity in your PATH.") unless($check);

    my $job_name = $class->Get_Job_Name();
    my $output_dir = qq"outputs/trinity_${job_name}";
    my $input_string = "";
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        $input_string = qq"--left $in[0] --right $in[1] ";
    } else {
        $input_string = qq"--single $options->{input} ";
    }
    my $comment = qq!## This is a trinity submission script
!;
    my $jstring = qq!mkdir -p ${output_dir} && \\
  Trinity --seqType fq --min_contig_length $options->{contig_length} --normalize_reads \\
    --trimmomatic --max_memory 90G --CPU 6 \\
    --output ${output_dir} \\
    ${input_string} \\
    2>${output_dir}/trinity_${job_name}.err \\
    1>${output_dir}/trinity_${job_name}.out
!;
    my $trinity = $class->Submit(
        cpus => 6,
        comment => $comment,
        jdepends => $options->{jdepends},
        jname => "$options->{jprefix}trin_${job_name}",
        jprefix => $options->{jprefix},
        jstring => $jstring,
        jmem => 96,
        jqueue => 'large',
        jwalltime => '144:00:00',
        output => qq"${output_dir}/Trinity.xls",
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        );
    my $rsem = Bio::Adventure::Assembly::Trinity_Post(
        $class, %args,
        jdepends => $trinity->{job_id},
        jname => "$options->{jprefix}_1trin_rsem",
        input => $options->{input},
        );
    my $trinotate = Bio::Adventure::Annotation::Trinotate(
        $class, %args,
        jdepends => $trinity->{job_id},
        jname => "$options->{jprefix}_2trinotate",
        input => qq"${output_dir}/Trinity.fasta",
        );
    $trinity->{rsem_job} = $rsem;
    $trinity->{trinotate_job} = $trinotate;
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($trinity);
}

=head2 C<Trinity_Post>

Perform some of the post-processing tools provided by trinity.

=over

=item I<input> * Input fasta from trinity.

=back

=head3 C<Invocation>

> cyoa --task assembly --method trinitypost --input trinity.fasta

=cut
sub Trinity_Post {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['input'],
        jname => "trin_rsem",
        modules => 'rsem',
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $job_name = $class->Get_Job_Name();
    my $trinity_out_dir = qq"outputs/trinity_${job_name}";

    my $rsem_input = qq"${trinity_out_dir}/Trinity.fasta";
    my $trinity_path = which('Trinity');
    my $trinity_exe_dir = dirname($trinity_path);
    my $input_string = "";
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        $input_string = qq"--left $in[0] --right $in[1] ";
    } else {
        $input_string = qq"--single $options->{input} ";
    }

    my $comment = qq!## This is a trinity post-processing submission script.
!;
    my $jstring = qq!
start=\$(pwd)
cd ${trinity_out_dir}
${trinity_exe_dir}/util/TrinityStats.pl Trinity.fasta \\
  2>${trinity_out_dir}/trinpost_stats.err \\
  1>${trinity_out_dir}/trinpost_stats.out &

${trinity_exe_dir}/util/align_and_estimate_abundance.pl \\
  --output_dir align_estimate.out \\
  --transcripts ${rsem_input} \\
  --seqType fq \\
  ${input_string} \\
  --est_method RSEM \\
  --aln_method bowtie \\
  --trinity_mode --prep_reference \\
  2>trinpost_align_estimate.err \\
  1>trinpost_align_estimate.out

${trinity_exe_dir}/util/abundance_estimates_to_matrix.pl \\
  --est_method RSEM \\
  --gene_trans_map Trinity.fasta.gene_trans_map \\
  align_estimate.out/RSEM.isoform.results \\
  2>trinpost_estimate_to_matrix.err \\
  1>trinpost_estimate_to_matrix.out

${trinity_exe_dir}/util/SAM_nameSorted_to_uniq_count_stats.pl \\
  bowtie_out/bowtie_out.nameSorted.bam \\
  2>trinpost_count_stats.err \\
  1>trinpost_count_stats.out

cd \${start}
!;
    my $trinpost = $class->Submit(
        comment => $comment,
        input => $options->{input},
        jdepends => $options->{jdepends},
        jmem => 90,
        jname => "$options->{jprefix}trinpost_${job_name}",
        jprefix => $options->{jprefix},
        jqueue => 'large',
        jstring => $jstring,
        jwalltime => '144:00:00',
        output => qq"${trinity_out_dir}/RSEM.isoform.results",
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        ##        queue => "long",
        ##        walltime => "144:00:00",
        );
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($trinpost);
}


=head2 C<Unicycler>

Use unicycler to assemble bacterial/viral reads.

=cut
sub Unicycler {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        required => ['input'],
        depth => 20,
        jprefix => '13',
        mode => 'bold',
        min_length => 1000,
        arbitrary => '',
        modules => ['trimomatic', 'spades', 'unicycler'],
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $check = which('unicycler');
    die("Could not find unicycler in your PATH.") unless($check);

    my $job_name = $class->Get_Job_Name();
    my $outname = basename(cwd());
    my $output_dir = qq"outputs/$options->{jprefix}unicycler";
    my $input_string = '';;
    my $ln_string = '';
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        $input_string = qq" -1 ${output_dir}/r1.fastq.gz -2 ${output_dir}/r2.fastq.gz";
        $ln_string = qq"cp $in[0] ${output_dir}/r1.fastq.gz
cp $in[1] ${output_dir}/r2.fastq.gz
";
    } else {
        $input_string = qq" -1 ${output_dir}/r1.fastq.gz";
        $ln_string = qq"cp $options->{input} ${output_dir}/r1.fastq.gz
";
    }
    my $comment = qq!## This is a unicycler submission script
!;
    my $jstring = qq!mkdir -p ${output_dir}
${ln_string}
unicycler $options->{arbitrary} \\
  --mode $options->{mode} \\
  --min_fasta_length $options->{min_length} \\
  ${input_string} \\
  -o ${output_dir} \\
  2>${output_dir}/unicycler_${outname}.err \\
  1>${output_dir}/unicycler_${outname}.out
mv ${output_dir}/assembly.fasta ${output_dir}/${outname}_final_assembly.fasta
rm -f r1.fastq.gz r2.fastq.gz
!;
    my $unicycler = $class->Submit(
        jdepends => $options->{jdepends},
        cpus => 6,
        comment => $comment,
        jmem => 30,
        jname => qq"unicycler_${job_name}",
        jprefix => $options->{jprefix},
        jqueue => 'workstation',
        jstring => $jstring,
        jwalltime => '4:00:00',
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        output => qq"${output_dir}/${outname}_final_assembly.fasta",
        output_gfa => qq"${output_dir}/assembly.gfa",
        output_log => qq"${output_dir}/unicycler.log",);
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($unicycler);
}

=head2 C<Velvet>

Submit sequences for a generic assembly by velvet and pass it to ragoo.

=over

=item I<input> * Input reads passed to velveth.

=item I<species> * Species name for passing to ragoo.py.

=back

=head3 C<Invocation>

> cyoa --task assembly --method velvet --input forward.fastq.gz:reverse.fastq.gz

=cut
sub Velvet {
    my ($class, %args) = @_;
    my $options = $class->Get_Vars(
        args => \%args,
        kmer => 31,
        required => ['input', 'species'],
        modules => 'velvet',
        );
    my $loaded = $class->Module_Loader(modules => $options->{modules});
    my $check = which('velveth');
    die("Could not find velvet in your PATH.") unless($check);
    my $job_name = $class->Get_Job_Name();
    my $output_dir = qq"outputs/velvet_${job_name}";
    my $input_string = "";
    if ($options->{input} =~ /\:|\;|\,|\s+/) {
        my @in = split(/\:|\;|\,|\s+/, $options->{input});
        $input_string = qq" -fastq -short2 -separate <(less $in[0]) <(less $in[1])";
    } else {
        $input_string = qq" -fastq -short <(less $options->{input})";
    }
    my $comment = qq!## This is a velvet submission script
!;
    my $jstring = qq!mkdir -p ${output_dir} && \\
  velveth ${output_dir} $options->{kmer} \\
    $input_string \\
    2>${output_dir}/velveth_${job_name}.err \\
    1>${output_dir}/velveth_${job_name}.out
  velvetg ${output_dir} \\
    -exp_cov auto -cov_cutoff auto \\
    2>${output_dir}/velvetg_${job_name}.err \\
    1>${output_dir}/velvetg_${job_name}.out
  new_params=\$(velvet-estimate-exp_cov.pl ${output_dir}/stats.txt \|
    grep velvetg parameters \|
    sed 's/velvetg parameters: //g')
  ##velvetg ${output_dir} \${new_params} -read_trkg yes -amos_file yes \\
  ##  2>${output_dir}/second_velvetg.txt 2>&1
  ragoo.py \\
    ${output_dir}/configs.fa \\
    $options->{libdir}/$options->{libtype}/$options->{species}.fasta
!;
    my $velvet = $class->Submit(
        cpus => 6,
        comment => $comment,
        jdepends => $options->{jdepends},
        jname => qq"velveth_${job_name}",
        jprefix => $options->{jprefix},
        jstring => $jstring,
        jmem => '30',
        output => qq"$output_dir/Sequences",
        prescript => $options->{prescript},
        postscript => $options->{postscript},
        jqueue => 'workstation',
        jwalltime => '4:00:00',
        );
    $loaded = $class->Module_Loader(modules => $options->{modules},
                                    action => 'unload');
    return($velvet);
}


=head1 AUTHOR - atb

Email  <abelew@gmail.com>

=head1 SEE ALSO

L<trinity> L<trinotate> L<transdecoder> L<velvet> L<ragoo>

=cut

1;
