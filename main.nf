#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { BASECALL          } from './modules/basecall'
include { DISCOVER_BARCODES } from './modules/discover'
include { SINTAX            } from './modules/sintax'
include { BUILD_TABLE       } from './modules/build_table'


workflow {

    // Resolve the deprecated `sintax_silva` alias for `sintax_references`
    if (params.sintax_silva != null) {
        log.warn "Parameter 'sintax_silva' is deprecated; please use 'sintax_references' instead."
    }
    sintax_references = params.sintax_references ?: params.sintax_silva

    // Validate parameters up front so a misconfigured run aborts with a
    // single, readable report instead of a deep Groovy/tool error mid-run.
    // Path *existence* is still enforced by `checkIfExists` below; this
    // catches missing/invalid values before any channel or process.
    def errors = []
    if (!sintax_references)
        errors << "  - 'sintax_references' is required (path to the sintax-formatted reference fasta)."
    if (!params.results_table)
        errors << "  - 'results_table' is required (output TSV path)."
    if (!params.primer_f)
        errors << "  - 'primer_f' is required (forward primer sequence)."
    if (!params.primer_r)
        errors << "  - 'primer_r' is required (reverse primer sequence)."
    if (params.skip_basecall) {
        if (!params.fastq_dir)
            errors << "  - 'fastq_dir' is required when 'skip_basecall = true'."
    }
    else if (!params.pod5_dir) {
        errors << "  - 'pod5_dir' is required when 'skip_basecall = false' (set 'skip_basecall = true' to reuse existing fastq)."
    }
    if (!(params.discard_untrimmed in [true, false]))
        errors << "  - 'discard_untrimmed' must be true or false (got: '${params.discard_untrimmed}')."
    def valid_modes = ['link', 'copy', 'symlink', 'rellink', 'move', 'copyNoFollow']
    if (!(params.publish_mode in valid_modes))
        errors << "  - 'publish_mode' must be one of ${valid_modes} (got: '${params.publish_mode}')."
    if (errors)
        error "Parameter validation failed:\n${errors.join('\n')}\nSee the README for the expected project config."

    // .first() turns the reference into a value channel so it is reused
    // across every barcode SINTAX task (a queue channel would be consumed
    // by the first barcode only).
    references_ch = Channel.fromPath(sintax_references, type: 'file', checkIfExists: true).first()

    if (params.skip_basecall) {
        // fastq_dir must already exist on disk and hold a fastq_pass tree.
        fastq_pass_ch = Channel.fromPath("${params.fastq_dir}/fastq_pass", type: 'dir', checkIfExists: true)
    } else {
        pod5_dir_ch = Channel.fromPath(params.pod5_dir, type: 'dir', checkIfExists: true)
        BASECALL(pod5_dir_ch)
        // the sentinel sits beside the freshly written fastq_pass
        fastq_pass_ch = BASECALL.out.done.map { file("${it.parent}/fastq_pass") }
    }

    // Discover fastq files and group them by barcode (handles both the
    // demultiplexed-into-folders and flat/embedded-name layouts; a sibling
    // fastq_fail is never seen since discovery is rooted at fastq_pass).
    DISCOVER_BARCODES(fastq_pass_ch)
    barcodes_ch = DISCOVER_BARCODES.out.barcodes
        .splitCsv(header: true, sep: '\t')
        .map { row -> tuple(row.barcode, file(row.path)) }
        .groupTuple()

    // One SINTAX task per barcode (one reference load each), then gather
    // every per-barcode .sintax into a single BUILD_TABLE invocation.
    SINTAX(barcodes_ch, references_ch)
    BUILD_TABLE(SINTAX.out.assigned.map { barcode, sintax, log -> sintax }.collect())
}
