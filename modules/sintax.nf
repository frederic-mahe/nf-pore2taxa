process SINTAX {
    tag "sintax"

    publishDir params.fastq_dir, mode: 'link', overwrite: true

    input:
    val  fastq_dir
    path references

    output:
    path 'done_sintax.txt', emit: done  // sentinel so Nextflow can cache this step

    script:
    """
    bash \\
    assign_with_sintax.sh \\
        --input-dir "${fastq_dir}" \\
        --references "${references}" \\
        --forward-primer "${params.primer_f}" \\
        --reverse-primer "${params.primer_r}"
    echo "done" > done_sintax.txt
    """
}
