process BASECALL {
    tag "basecall"

    // The output glob already carries the fastq_pass/... prefix, so the
    // subdirectory structure is preserved without a saveAs closure.
    publishDir params.fastq_dir, mode: params.publish_mode, overwrite: true

    input:
    path pod5_dir

    output:
    path 'fastq_pass/**', emit: fastq_dir   // glob captures the full hierarchy
    path 'done_basecalling.txt', emit: done  // sentinel so Nextflow can cache this step

    script:
    """
    bash \\
    basecall_pod5_files.sh \
        --input-dir "${pod5_dir}" \
        --output-dir "./"
    touch done_basecalling.txt
    """
}
