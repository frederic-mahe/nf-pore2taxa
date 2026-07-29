process BASECALL {
    tag "basecall"

    // The output glob already carries the fastq_pass/... prefix, so the
    // subdirectory structure is preserved without a saveAs closure.
    publishDir params.fastq_dir, mode: params.publish_mode, overwrite: true

    input:
    path pod5_dir

    output:
    path 'fastq_pass/**', emit: fastq_dir   // glob captures the full hierarchy
    path 'done_basecalling.txt', emit: done  // sentinel so Nextflow can cache this step
    // dorado's version, recorded by the only task that can read it
    // honestly: it is an ONT GPU binary, absent from the conda
    // environment, and on a cluster it may not exist at all on the node
    // the DUMP_VERSIONS probe lands on. Emitted as a
    // `<name><TAB><raw>` fragment for collect_versions.py.
    path 'versions_dorado.tsv', emit: versions

    script:
    """
    bash \\
    basecall_pod5_files.sh \
        --input-dir "${pod5_dir}" \
        --output-dir "./"
    printf 'dorado\\t%s\\n' "\$(dorado --version 2>&1 | head -n 1 || true)" \\
        > versions_dorado.tsv
    touch done_basecalling.txt
    """
}
