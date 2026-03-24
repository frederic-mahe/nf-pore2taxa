process BASECALL {
    tag "basecall"

    publishDir "${params.results_dir}/fastq", mode: 'copy', overwrite: true

    input:
    path pod5_dir

    output:
    path params.fastq_dir, emit: fastq_dir

    script:
    """
    bash \\
    basecall_pod5_files.sh \\
        --input-dir "${pod5_dir}" \\
        --output-dir "${params.fastq_dir}"
    """
}
