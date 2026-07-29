#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { BASECALL          } from './modules/basecall'
include { DISCOVER_BARCODES } from './modules/discover'
include { SINTAX            } from './modules/sintax'
include { BUILD_TABLE       } from './modules/build_table'
include { KRONA             } from './modules/krona'
include { DUMP_VERSIONS     } from './modules/provenance'
include { DUMP_PARAMS       } from './modules/provenance'
include { coerce_bool       } from './modules/local/functions'
include { valid_bool        } from './modules/local/functions'
include { optimistic_name   } from './modules/local/functions'
include { fastq_extensions  } from './modules/local/functions'
include { valid_memory      } from './modules/local/functions'
include { effective_threads } from './modules/local/functions'


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
      --subsample          Cap each barcode at this many reads before trimming
                           (default: ${params.subsample}). 0 keeps every read;
                           a positive integer subsamples (seeded by --randseed)
                           so only that many reads are processed and assigned.
      --krona              Render interactive Krona HTML charts (krona.html and
                           krona_optimistic.html) beside the results table
                           (default: ${params.krona}). Requires KronaTools
                           (ktImportText); provided by the conda profile.
      --publish_mode       publishDir mode for outputs: link, copy, copyNoFollow,
                           symlink, rellink (default: ${params.publish_mode}).
                           'link' needs workDir and outputs on one filesystem;
                           'copy' when they are not. The link modes require
                           --cleanup to be off (else the links would dangle).
      --cleanup            Delete the work directory on success
                           (default: ${params.cleanup}). Off by default so
                           -resume works across runs and published links stay
                           valid; turn on for throwaway runs.
      --max_cpus           Ceiling on any single task's cpu request
                           (default: this machine's ${params.max_cpus}).
      --max_memory         Ceiling on any single task's memory request
                           (default: this machine's ${params.max_memory}).
                           Every request, including a retry's escalated one,
                           is clamped to these — so the pipeline runs on a
                           small workstation without editing any config.
                           Lower them to leave headroom for other work.
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


// The run's effective parameters, as JSON, for
// pipeline_info/params.json.
//
// Deliberately an explicit list rather than a dump of `params`: the map
// also holds the deprecated alias, `help`, and a MemoryUnit that does not
// serialise cleanly — and an explicit list keeps the artefact's shape
// stable across releases, which is the point of a provenance record.
//
// Values are the EFFECTIVE ones, not the raw ones: booleans go through
// coerce_bool (so a CLI `--krona false`, which arrives as the string
// 'false', is recorded as JSON `false`, not as a truthy string), and
// sintax_references records the path actually used after the
// sintax_silva alias is resolved.
//
// Deliberately excluded: the session id and the command line. They vary
// per *invocation* rather than per configuration, so including them made
// DUMP_PARAMS re-run on every `-resume` — costing the clean "nothing
// changed" signal (SX-35) to duplicate what Nextflow's own execution
// report and .nextflow.log already record. This file answers "with what
// settings?", the report answers "which run?". Everything kept below is
// stable for a given checkout + configuration, so the task caches.
def paramsJson(references) {
    def record = [
        pipeline         : "${workflow.manifest.name} ${workflow.manifest.version}",
        nextflow         : "${workflow.nextflow.version}",
        revision         : "${workflow.revision ?: 'n/a'}",
        commitId         : "${workflow.commitId ?: 'n/a'}",
        profile          : "${workflow.profile}",
        params           : [
            skip_basecall    : coerce_bool(params.skip_basecall),
            pod5_dir         : params.pod5_dir,
            fastq_dir        : params.fastq_dir,
            sintax_references: references,
            results_table    : params.results_table,
            primer_f         : params.primer_f,
            primer_r         : params.primer_r,
            discard_untrimmed: coerce_bool(params.discard_untrimmed),
            randseed         : params.randseed,
            subsample        : params.subsample,
            krona            : coerce_bool(params.krona),
            publish_mode     : params.publish_mode,
            cleanup          : coerce_bool(params.cleanup),
            max_cpus         : params.max_cpus,
            max_memory       : "${params.max_memory}",
        ],
    ]
    groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(record))
}


// One-screen record of what this run is actually doing: every parameter
// that can change the result, plus the resolved resource ceiling.
//
// Written for the run log, not for interactive reading. Nextflow's own
// header covers the pipeline version, profile and work directory; what it
// never shows is the effective *parameters*, which is exactly what a lab
// needs six months later to answer "what did this table come from?".
// Until versions.yml lands, this block is the pipeline's only provenance.
def runSummary(sintax_threads) {
    def references = params.sintax_references ?: params.sintax_silva
    def rows = [
        'mode'             : coerce_bool(params.skip_basecall)
                                 ? 'reuse existing fastq (skip_basecall)'
                                 : 'basecall pod5 with dorado',
        'fastq_dir'        : params.fastq_dir,
    ]
    if (!coerce_bool(params.skip_basecall))
        rows['pod5_dir'] = params.pod5_dir
    rows += [
        'sintax_references': references,
        'results_table'    : params.results_table,
        'primer_f'         : params.primer_f,
        'primer_r'         : params.primer_r,
        'discard_untrimmed': "${params.discard_untrimmed}" +
                             (coerce_bool(params.discard_untrimmed)
                                  ? ' (strict amplicon filtering)'
                                  : ' (keep every read)'),
        'subsample'        : "${params.subsample}" +
                             ("${params.subsample}" == '0' ? ' (disabled)' : ' reads per barcode'),
        'randseed'         : "${params.randseed}" +
                             ("${params.randseed}" == '0' ? ' (pseudo-random each run)' : ''),
        'krona'            : params.krona,
        'publish_mode'     : params.publish_mode,
        'cleanup'          : params.cleanup,
        'resource ceiling' : "${params.max_cpus} cpus / ${params.max_memory}" +
                             " (every request is clamped to this; SINTAX gets ${sintax_threads} thread(s))",
    ]
    def width = rows.keySet()*.length().max()
    def body = rows.collect { key, value ->
        "  ${key.padRight(width)} : ${value}"
    }.join('\n')
    // Trailing newline: Nextflow's own header follows immediately after,
    // and without it the last row and that header share a line.
    "${workflow.manifest.name} ${workflow.manifest.version}\n${body}\n"
}


workflow {

    // Print help and exit before any validation, so `--help` works on its
    // own (returning from the workflow body invokes no process).
    if (coerce_bool(params.help)) {
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
    // fastq_dir is required in BOTH modes, not just when reusing fastq:
    // BASECALL publishes into it and SINTAX publishes each barcode's
    // results under ${fastq_dir}/fastq_pass/<barcode>. Left unset with
    // skip_basecall = false, Nextflow resolved 'null/...' and silently
    // wrote a directory literally named 'null' in the launch dir — after
    // basecalling had already run.
    if (!params.fastq_dir)
        errors << "  - 'fastq_dir' is required (basecalled reads are written there, and per-barcode results beside them)."
    if (!coerce_bool(params.skip_basecall) && !params.pod5_dir) {
        errors << "  - 'pod5_dir' is required when 'skip_basecall = false' (set 'skip_basecall = true' to reuse existing fastq)."
    }
    // Boolean params accept a config boolean or a CLI flag (the string
    // 'true'/'false'); valid_bool()/coerce_bool() (modules/local/functions)
    // handle both forms, so e.g. `--discard_untrimmed false` is honoured.
    // EVERY declared boolean goes through this list: a plain Groovy
    // truthiness test on a CLI override reads the string 'false' as true
    // (the v1.7.1 skip_basecall bug), so a new boolean param that skips
    // valid_bool/coerce_bool is a defect waiting to happen.
    ['skip_basecall', 'discard_untrimmed', 'krona', 'cleanup', 'help'].each { name ->
        if (!valid_bool(params[name]))
            errors << "  - '${name}' must be true or false (got: '${params[name]}')."
    }
    // CLI overrides arrive as Strings, config values as Integers; match
    // the string form so both a non-negative integer and its CLI spelling
    // pass (and a float, sign, or non-numeric value is rejected).
    if (!("${params.randseed}" ==~ /\d+/))
        errors << "  - 'randseed' must be a non-negative integer (got: '${params.randseed}')."
    if (!("${params.subsample}" ==~ /\d+/))
        errors << "  - 'subsample' must be a non-negative integer (got: '${params.subsample}')."
    // Resource ceiling. Caught here rather than at first task submission,
    // where a bad value surfaces as a bare "Not a valid FileSize value".
    if (!("${params.max_cpus}" ==~ /[1-9]\d*/))
        errors << "  - 'max_cpus' must be a positive integer (got: '${params.max_cpus}')."
    if (!valid_memory(params.max_memory))
        errors << "  - 'max_memory' must be a positive memory size such as '32.GB' (got: '${params.max_memory}')."
    // 'move' is deliberately absent: BASECALL's downstream handoff reads
    // the freshly written fastq_pass back out of the task work directory,
    // and moving the files away empties it.
    def valid_modes = ['link', 'copy', 'copyNoFollow', 'symlink', 'rellink']
    if (!(params.publish_mode in valid_modes))
        errors << "  - 'publish_mode' must be one of ${valid_modes} (got: '${params.publish_mode}')."
    // The link modes publish pointers *into* the work directory, so
    // deleting it on success leaves every output dangling — an
    // unreadable results table under a run that reported SUCCESS.
    def link_modes = ['symlink', 'rellink']
    if (coerce_bool(params.cleanup) && params.publish_mode in link_modes)
        errors << "  - 'publish_mode = ${params.publish_mode}' cannot be combined with 'cleanup = true': the published outputs are links into the work directory, which cleanup deletes. Use 'copy' (or leave cleanup off)."
    if (errors)
        error "Parameter validation failed:\n${errors.join('\n')}\nRun with --help for the full parameter list, or see the README for the expected project config."

    // How many threads SINTAX will really get: its configured request,
    // reduced by the ceiling. Read from the resolved config so a project
    // config that lowers the request is reflected, rather than assuming
    // the shipped 20.
    def sintax_cpus = workflow.session?.config?.navigate('process.withName:SINTAX.cpus')
                   ?: workflow.session?.config?.navigate('process.cpus')
    def sintax_threads = effective_threads(sintax_cpus, params.max_cpus)

    // Effective configuration, including the ceiling — clamping is silent
    // in Nextflow, so without this a run where SINTAX asked for 20 threads
    // and got 8 gives no clue why, nor that raising the request would not
    // help.
    log.info runSummary(sintax_threads)

    // vsearch sintax is order-dependent across threads, so a fixed seed
    // does NOT make a multithreaded run replayable. Say so at the point
    // where the user has just asked for reproducibility, instead of only
    // in the README — a seed that quietly fails to deliver what it
    // promises is worse than no seed at all.
    //
    // (vsearch 2.32.0 is expected to make sintax reproducible under
    // multithreading. When the pin is bumped, drop this warning and raise
    // MIN_VSEARCH_VERSION in bin/assign_with_sintax.sh — see the
    // "Upstream-blocked" section of docs/plans/TBD_20260729_hardening.md.)
    if ("${params.randseed}" != '0' && sintax_threads > 1) {
        log.warn "randseed = ${params.randseed} is set, but SINTAX runs on ${sintax_threads} threads and vsearch sintax is not exactly reproducible above one thread, even with a fixed seed. For a replayable run, cap the threads (--max_cpus 1); otherwise expect small run-to-run differences in the assignments."
    }

    // .first() turns the reference into a value channel so it is reused
    // across every barcode SINTAX task (a queue channel would be consumed
    // by the first barcode only).
    references_ch = Channel.fromPath(sintax_references, type: 'file', checkIfExists: true).first()

    if (coerce_bool(params.skip_basecall)) {
        // fastq_dir must already exist on disk and hold a fastq_pass tree.
        fastq_pass_ch = Channel.fromPath("${params.fastq_dir}/fastq_pass", type: 'dir', checkIfExists: true)
        // No dorado ran, so there is no dorado version to record. An
        // empty list (not an empty channel) so DUMP_VERSIONS still runs.
        dorado_versions_ch = Channel.value([])
    } else {
        pod5_dir_ch = Channel.fromPath(params.pod5_dir, type: 'dir', checkIfExists: true)
        BASECALL(pod5_dir_ch)
        // the sentinel sits beside the freshly written fastq_pass
        fastq_pass_ch = BASECALL.out.done.map { file("${it.parent}/fastq_pass") }
        dorado_versions_ch = BASECALL.out.versions.collect()
    }

    // Enumerate the run's fastq files here, in the workflow, and hand the
    // sorted list to DISCOVER_BARCODES alongside the directory.
    //
    // The directory itself is passed as an *unstaged* `val` (the tree can
    // hold thousands of files; staging them into the discovery task would
    // be pure waste). But Nextflow then has nothing content-derived to
    // hash, so its cache key ignored what the tree actually contained:
    // adding a fastq to an EXISTING barcode directory and re-running with
    // -resume was a cache hit, and the run reported SUCCESS with the
    // previous table — silently dropping the new reads (a topped-up
    // library, a second flow cell for one barcode). Adding a *new*
    // barcode directory happened to invalidate the key via the parent's
    // mtime, which made the failure mode worse by looking like it worked.
    //
    // The file list makes the key reflect the input set, so any added or
    // removed fastq re-runs discovery. Content changes to an existing
    // file are caught downstream instead: SINTAX stages its fastq as real
    // `path` inputs, so they are content-hashed there.
    // `files()` rather than `file()`: the latter warns when a glob matches
    // a collection ("use `files()` instead") and is on its way out.
    fastq_files_ch = fastq_pass_ch.map { dir ->
        fastq_extensions()
            .collect { ext -> files("${dir}/**.${ext}") }
            .flatten()
            .collect { it.toString() }
            .sort()
    }

    // Discover fastq files and group them by barcode (handles both the
    // demultiplexed-into-folders and flat/embedded-name layouts; a sibling
    // fastq_fail is never seen since discovery is rooted at fastq_pass).
    DISCOVER_BARCODES(fastq_pass_ch, fastq_files_ch)
    barcodes_ch = DISCOVER_BARCODES.out.barcodes
        .splitCsv(header: true, sep: '\t')
        .map { row -> tuple(row.barcode, file(row.path)) }
        .groupTuple()

    // One SINTAX task per barcode (one reference load each), then gather
    // every per-barcode .sintax into a single BUILD_TABLE invocation.
    SINTAX(barcodes_ch, references_ch)
    BUILD_TABLE(SINTAX.out.assigned.map { barcode, sintax, log -> sintax }.collect())

    // Optional Krona charts: one HTML per occurrence table (filtered +
    // optimistic), each with a per-barcode dataset. Both tables are fed to
    // a single KRONA task, which renders one HTML each. coerce_bool
    // handles both the config boolean and the CLI-flag string, so
    // `--krona false` disables it as expected.
    if (coerce_bool(params.krona)) {
        KRONA(BUILD_TABLE.out.filtered.mix(BUILD_TABLE.out.optimistic).collect())
    }

    // Provenance, published into pipeline_info/ beside the tables: what
    // software ran (software_versions.yml, including dorado's version when
    // basecalling happened) and with what effective parameters
    // (params.json). Independent of the analysis channels on purpose — a
    // run that fails part-way still records what it was attempting.
    DUMP_VERSIONS(dorado_versions_ch)
    DUMP_PARAMS(paramsJson(sintax_references))
}
