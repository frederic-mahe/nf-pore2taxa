process SINTAX {
    tag "sintax"

    publishDir params.fastq_dir, mode: 'link', overwrite: true,
               saveAs: { filename -> filename }

    input:
    val  fastq_dir
    path references

    output:
    path 'fastq_pass/**/*.sintax', emit: sintax_files
    path 'done_sintax.txt',        emit: done

    script:
    """
    cp -r "${fastq_dir}" ./fastq_pass
    bash \\
    assign_with_sintax.sh \\
        --input-dir "./fastq_pass" \\
        --references "${references}" \\
        --forward-primer "${params.primer_f}" \\
        --reverse-primer "${params.primer_r}"
    echo "done" > done_sintax.txt
    """
}
