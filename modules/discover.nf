process DISCOVER_BARCODES {
    tag "discover"

    input:
    val fastq_pass   // absolute path to the fastq_pass directory (not staged)

    output:
    path 'barcodes.tsv', emit: barcodes

    script:
    """
    python3 \\
        ${projectDir}/bin/discover_barcodes.py \\
        --input-dir "${fastq_pass}" \\
        --output barcodes.tsv
    """
}
