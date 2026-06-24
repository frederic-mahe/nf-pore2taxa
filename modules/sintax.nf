process SINTAX {
    tag "sintax"

    // The `conda` profile (environment.yml) pins vsearch/cutadapt; the
    // in-script version check in assign_with_sintax.sh stays as the safety
    // net for bare-PATH runs (the default `standard` profile).
    publishDir params.fastq_dir, mode: params.publish_mode, overwrite: true,
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
    // Stage the input by hard link when workDir and fastq_dir share a
    // filesystem (publish_mode 'link'); fall back to a real copy
    // otherwise, since a hard link cannot cross devices.
    def stage_link = params.publish_mode == 'link' ? '--link' : ''
    """
    cp --archive ${stage_link} "${fastq_dir}/fastq_pass" ./fastq_pass
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
