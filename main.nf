#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { BASECALL          } from './modules/basecall'
include { DISCOVER_BARCODES } from './modules/discover'
include { SINTAX            } from './modules/sintax'
include { BUILD_TABLE       } from './modules/build_table'


// Hand-written help (printed by `--help`). Kept in sync with the params
// block in nextflow.config and the validation below; there is no schema
// plugin to generate it for us.
def helpMessage() {
    """
    ${workflow.manifest.name} ${workflow.manifest.version}
    ${workflow.manifest.description}

    Usage:

      nextflow run main.nf -config <project.config> [-profile standard,conda]

    Parameters are normally supplied through a -config file (see the README);
    each one below can also be passed on the command line as --<name> <value>.

    Required parameters:
      --sintax_references  Path to the sintax-formatted reference FASTA.
                           Taxonomy is encoded in each header (README "sintax format").
      --results_table      Output occurrence table (TSV) path.
      --primer_f           Forward primer sequence.
      --primer_r           Reverse primer sequence.
      --pod5_dir           Directory of pod5 files to basecall.
                           Required unless --skip_basecall is set.
      --fastq_dir          Directory holding a fastq_pass/ tree.
                           Required when --skip_basecall is set.

    Optional parameters:
      --skip_basecall      Reuse existing fastq instead of basecalling pod5
                           (default: ${params.skip_basecall}). Needs --fastq_dir.
      --discard_untrimmed  Drop reads with no detectable primer, i.e. strict
                           amplicon filtering (default: ${params.discard_untrimmed}).
                           Set false to keep and trim every read.
      --randseed           Seed for vsearch's random generator in the sintax
                           step (default: ${params.randseed}). 0 picks a
                           pseudo-random seed; set a positive integer for
                           reproducible single-threaded runs.
      --publish_mode       publishDir mode for outputs: link, copy, symlink,
                           rellink, move, copyNoFollow (default: ${params.publish_mode}).
                           'link' needs workDir and outputs on one filesystem.
      --help               Show this message and exit.

    Profiles (-profile):
      standard             Local executor (default).
      cluster              SLURM executor.
      conda                Resolve cutadapt/vsearch/python from environment.yml.
                           Compose with an executor, e.g. -profile standard,conda.

    Example:

      nextflow run main.nf -profile standard,conda \\
          --skip_basecall --fastq_dir data/run1 \\
          --sintax_references refs.fasta.gz \\
          --results_table results/sintax.tsv \\
          --primer_f GTACACACCGCCCGTCG --primer_r CGCCTSCSCTTANTDATATGC
    """.stripIndent()
}


workflow {

    // Print help and exit before any validation, so `--help` works on its
    // own (returning from the workflow body invokes no process).
    if (params.help) {
        println helpMessage()
        return
    }

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
    // CLI overrides arrive as Strings, config values as Integers; match
    // the string form so both a non-negative integer and its CLI spelling
    // pass (and a float, sign, or non-numeric value is rejected).
    if (!("${params.randseed}" ==~ /\d+/))
        errors << "  - 'randseed' must be a non-negative integer (got: '${params.randseed}')."
    def valid_modes = ['link', 'copy', 'symlink', 'rellink', 'move', 'copyNoFollow']
    if (!(params.publish_mode in valid_modes))
        errors << "  - 'publish_mode' must be one of ${valid_modes} (got: '${params.publish_mode}')."
    if (errors)
        error "Parameter validation failed:\n${errors.join('\n')}\nRun with --help for the full parameter list, or see the README for the expected project config."

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
