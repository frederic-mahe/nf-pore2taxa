process BUILD_TABLE {
    tag "build_table"

    // Closure (lazy): evaluated per task, not at process-definition time,
    // so a null params.results_table is reported by the workflow's
    // startup parameter validation rather than a raw file() error here.
    publishDir { file(params.results_table).parent }, mode: params.publish_mode, overwrite: true

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
