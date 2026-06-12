process BUILD_TABLE {
    tag "build_table"

    publishDir "${file(params.results_table).parent}", mode: 'link', overwrite: true

    input:
    val fastq_dir  // pass absolute path as a value, no staging

    output:
    path "*.tsv", emit: results_table

    script:
    def output_file = file(params.results_table).name  // extract filename only
    """
    python3 \\
        ${projectDir}/bin/build_occurrence_table.py \\
        --input-dir "${fastq_dir}" \\
        --output "${output_file}"
    """
}
