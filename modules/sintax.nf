process SINTAX {
    tag "sintax"

    // TODO: once conda-based distribution lands, replace the in-script
    //       version check with `conda 'bioconda::vsearch>=2.31.0'`
    publishDir params.fastq_dir, mode: 'link', overwrite: true,
               saveAs: { filename -> filename }

    input:
    val  fastq_dir
    path references

    output:
    path 'fastq_pass/*.{sintax,log}', optional: true
    path 'fastq_pass/**/*.{sintax,log}', optional: true
    path 'done_sintax.txt', emit: done

    script:
    // Strict amplicon filtering (drop reads with no primer) is the
    // default; params.discard_untrimmed = false keeps every read.
    def primer_filter = params.discard_untrimmed ? '--discard-untrimmed' : '--keep-untrimmed'
    """
    cp --archive --link "${fastq_dir}/fastq_pass" ./fastq_pass
    bash \\
    assign_with_sintax.sh \\
        --input-dir "./fastq_pass" \\
        --references "${references}" \\
        --forward-primer "${params.primer_f}" \\
        --reverse-primer "${params.primer_r}" \\
        --threads "${task.cpus}" \\
        ${primer_filter}
    touch done_sintax.txt
    """
}
