process BUILD_TABLE {
    tag "build_table"

    publishDir "${params.results_dir}", mode: 'copy', overwrite: true

    input:
    path fastq_dir

    output:
    path "*.tsv", emit: results_table

    script:
    """
    Rscript --no-save --no-restore \\
        build_occurrence_table.R \\
        --input-dir "${fastq_dir}" \\
        --output "${params.results_table}"
    """
}
