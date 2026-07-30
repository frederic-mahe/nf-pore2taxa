// Fetch the basecalling model once and keep it.
//
// storeDir makes this a persistent cache OUTSIDE the work directory: on the
// second run Nextflow finds the model already there and does not execute the
// process at all, so basecalling stops needing ~1 GB of download and a
// network connection every time. Previously the model was fetched into the
// task directory and then deleted by the script's own clean_up.
process DOWNLOAD_MODEL {
    tag "${model}"

    storeDir params.basecall_model_dir

    input:
    // The FULL dorado model name, resolved by full_model_name() in main.nf.
    // Passed in rather than derived here for two reasons: an `output:`
    // declaration cannot call an included function, and the stored output has
    // to be named after the model — storeDir decides whether to skip the
    // process by whether that output already exists, so a name that did not
    // vary with the model would serve a cached copy of the WRONG one to
    // anyone who changed --basecall_model.
    val model

    output:
    path model, emit: model

    script:
    """
    dorado \\
        download \\
        --model "${model}" \\
        --models-directory .
    """

    // Under -stub-run: create the directory dorado would have fetched,
    // without the ~1 GB download or a network.
    stub:
    """
    mkdir -p "${model}"
    touch "${model}/stub.txt"
    """
}


process BASECALL {
    tag "basecall"

    // The output glob already carries the fastq_pass/... prefix, so the
    // subdirectory structure is preserved without a saveAs closure.
    publishDir params.fastq_dir, mode: params.publish_mode, overwrite: true

    input:
    path pod5_dir
    // Staged under models/ rather than at the top level so the script's
    // clean_up, which deletes every other top-level directory, has a stable
    // name to exclude.
    path model, stageAs: 'models/*'

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
        --output-dir "./" \
        --model "${params.basecall_model}" \
        --kit-name "${params.basecall_kit}" \
        --device "${params.basecall_device}" \
        --models-dir "models"
    printf 'dorado\\t%s\\n' "\$(dorado --version 2>&1 | head -n 1 || true)" \\
        > versions_dorado.tsv
    touch done_basecalling.txt
    """

    // Under -stub-run: fabricate the demultiplexed layout the real dorado
    // would emit, so discovery downstream has something to find and the
    // per-barcode fan-out is genuinely exercised. Two barcodes rather than
    // one, because a fan-out of width 1 is not a fan-out.
    stub:
    """
    mkdir -p fastq_pass/barcode01 fastq_pass/barcode02
    printf '@stub_b01_read1\\nACGT\\n+\\nIIII\\n' | gzip > fastq_pass/barcode01/reads.fastq.gz
    printf '@stub_b02_read1\\nACGT\\n+\\nIIII\\n' | gzip > fastq_pass/barcode02/reads.fastq.gz
    printf 'dorado\\tstub\\n' > versions_dorado.tsv
    touch done_basecalling.txt
    """
}
