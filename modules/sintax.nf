process SINTAX {
    tag "${barcode}"

    // The conda profile (environment.yml) pins vsearch/cutadapt; the
    // in-script version check in assign_with_sintax.sh stays as the safety
    // net for bare-PATH runs (the default `standard` profile).
    //
    // Publish the per-barcode results back next to the reads, under a
    // barcode subdirectory of fastq_pass (created for flat layouts).
    publishDir { "${params.fastq_dir}/fastq_pass/${barcode}" }, mode: params.publish_mode, overwrite: true

    input:
    tuple val(barcode), path(fastqs)
    path  references

    output:
    tuple val(barcode), path("${barcode}.sintax"), path("${barcode}.log"), emit: assigned

    script:
    // Strict amplicon filtering (drop reads with no primer) is the
    // default; params.discard_untrimmed = false keeps every read.
    def primer_filter = params.discard_untrimmed ? '--discard-untrimmed' : '--keep-untrimmed'
    """
    bash \\
    assign_with_sintax.sh \\
        --barcode "${barcode}" \\
        --references "${references}" \\
        --forward-primer "${params.primer_f}" \\
        --reverse-primer "${params.primer_r}" \\
        --threads "${task.cpus}" \\
        ${primer_filter} \\
        ${fastqs}
    """
}
