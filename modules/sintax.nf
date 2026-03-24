process SINTAX {
    tag "sintax"

    input:
    path fastq_dir
    path references

    output:
    path fastq_dir, emit: fastq_dir   // assign_with_sintax.sh writes results back into fastq_dir

    script:
    """
    bash \\
    assign_with_sintax.sh \\
        --input-dir "${fastq_dir}" \\
        --references "${references}" \\
        --forward-primer "${params.primer_f}" \\
        --reverse-primer "${params.primer_r}"
    """
}
