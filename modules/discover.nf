process DISCOVER_BARCODES {
    tag "discover"

    input:
    val fastq_pass   // absolute path to the fastq_pass directory (not staged)
    // The sorted list of fastq paths under fastq_pass, enumerated by the
    // workflow. The script does not read it — discovery re-walks the
    // directory itself — but it is what makes this task's cache key
    // reflect the input set. Without it, adding a fastq to an *existing*
    // barcode directory was a silent `-resume` cache hit that dropped the
    // new reads (see the comment at the call site in main.nf).
    val fastq_files

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
