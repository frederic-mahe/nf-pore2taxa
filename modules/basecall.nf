process BASECALL {
    tag "basecall"
    publishDir params.fastq_dir, mode: 'link', overwrite: true,
               saveAs: { filename -> filename }  // preserves subdirectory structure

    input:
    path pod5_dir

    output:
    path 'fastq_pass/**', emit: fastq_dir   // glob captures the full hierarchy

    script:
    """
    bash \\
    basecall_pod5_files.sh \
        --input-dir "${pod5_dir}" \
        --output-dir "./"
    """
}