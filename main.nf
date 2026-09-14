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
include { DOWNLOAD_MODEL     } from './modules/basecall'
include { full_model_name   } from './modules/local/functions'
include { effective_outdir  } from './modules/local/functions'
include { effective_table_name } from './modules/local/functions'
include { known_params      } from './modules/local/functions'
include { nearest_param     } from './modules/local/functions'


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
    A name this pipeline does not declare is rejected at startup, with the
    nearest match suggested — so a typo cannot silently leave a default in
    place.

    Required parameters:
      --sintax_references  Path to the sintax-formatted reference FASTA.
                           Taxonomy is encoded in each header (README "sintax format").
      --primer_f           Forward primer sequence.
      --primer_r           Reverse primer sequence.
      --pod5_dir           Directory of pod5 files to basecall.
                           Required unless --skip_basecall is set.
      --fastq_dir          Directory holding a fastq_pass/ tree.
                           Required when --skip_basecall is set.

    Output:
      --outdir             Single directory for everything the run produces:
                           both tables, per_barcode/, the Krona charts and
                           pipeline_info/ (default: results).
      --table_name         Filename of the filtered table inside --outdir
                           (default: ${params.table_name}).

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
      --krona              Render an interactive Krona HTML chart per occurrence
                           table, beside the tables in --outdir and named after
                           them: sintax.tsv -> sintax.krona.html
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
      --reference_size_gb  Approximate size of the reference database, in GB.
                           The assignment step sizes its memory request from
                           this instead of a fixed fallback (default: unset).
      --help               Show this message and exit.

    Deprecated (still honoured; removal at v2.0.0):
      --results_table      The filtered table's full path. Its parent is used
                           as --outdir and its basename as --table_name.
      --publish_beside_reads
                           Also publish each barcode's .sintax/.log back into
                           fastq_dir/fastq_pass/<barcode>/, as before v1.12.0.
      --sintax_silva       Alias for --sintax_references.

    Cluster parameters (with -profile slurm or a site profile):
      --slurm_queue        Partition to submit to.
      --slurm_account      Account for sbatch. Required at some sites.
      --slurm_array_size   Batch up to N ready tasks into one sbatch --array
                           submission instead of one job each.
      --slurm_queue_size   Max concurrent jobs the driver keeps in flight.
      --max_time           Walltime ceiling clamped onto every request.
                           See conf/site.config.example for the full set.

    Profiles (-profile):
      standard             Local executor (default).
      slurm                SLURM executor (generic; set --slurm_queue /
                           --slurm_account, or use a site profile below).
                           'cluster' is an alias, kept for compatibility.
      abims, genotoul,     Institutional clusters. Each implies slurm, so do
      ifb_core, meso,      not also pass 'slurm'.
      saga
      conda                Resolve cutadapt/vsearch/krona/python from
                           environment.yml (native conda, no container).
      apptainer,           Run those same tools in a container built from
      singularity,         environment.yml by Seqera Wave. Preferred on a
      docker, podman       cluster. Compose with an executor, e.g.
                           -profile abims,apptainer.

    Basecalling is local-only: dorado is a GPU binary outside the packaged
    environment, so a run that requests it under a scheduler is refused at
    startup. Basecall on the workstation, then use --skip_basecall.

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
            outdir           : effective_outdir(params.outdir, params.results_table),
            table_name       : effective_table_name(params.table_name, params.results_table),
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
    // Only meaningful when basecalling ran: recording a model and kit for a
    // run that reused existing fastq would claim they shaped the result.
    if (!coerce_bool(params.skip_basecall)) {
        record['params'] += [
            basecall_model    : params.basecall_model,
            basecall_kit      : params.basecall_kit,
            basecall_device   : params.basecall_device,
            basecall_model_dir: params.basecall_model_dir,
        ]
    }
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
    if (!coerce_bool(params.skip_basecall)) {
        rows['pod5_dir']        = params.pod5_dir
        rows['basecall_model']  = params.basecall_model
        rows['basecall_kit']    = params.basecall_kit
        rows['basecall_device'] = params.basecall_device
    }
    rows += [
        'sintax_references': references,
        'outdir'           : effective_outdir(params.outdir, params.results_table),
        'table_name'       : effective_table_name(params.table_name, params.results_table),
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

    // Resolve the deprecated `results_table` into outdir + table_name.
    if (params.results_table != null)
        log.warn "Parameter 'results_table' is deprecated; please use 'outdir' (the run's single output directory) and 'table_name'. Its parent and basename are being used for now; it will be removed in v2.0.0."
    if (coerce_bool(params.publish_beside_reads))
        log.warn "Parameter 'publish_beside_reads' is deprecated; the per-barcode .sintax/.log files are published under outdir/per_barcode/ and the extra copy beside the reads will be removed in v2.0.0."
    outdir     = effective_outdir(params.outdir, params.results_table)
    table_name = effective_table_name(params.table_name, params.results_table)

    // Validate parameters up front so a misconfigured run aborts with a
    // single, readable report instead of a deep Groovy/tool error mid-run.
    // Path *existence* is still enforced by `checkIfExists` below; this
    // catches missing/invalid values before any channel or process.
    def errors = []

    // Reject parameters this pipeline does not declare. Nextflow accepts any
    // `--foo bar` silently and puts it in `params`, so until now a typo left
    // the real parameter at its default while the user believed they had set
    // it — `--subsampl 100` ran with subsample = 0 and said nothing. That is
    // the same silent-wrong-result class as the v1.7.1 defects, and the only
    // one of them the pipeline could not previously see.
    //
    // Listed before everything else in the report: if a name is wrong, the
    // complaints that follow are about values the user did not actually set.
    // `.toString()`, for the same reason as in valid_bool(): `in` on a List
    // compares with equals(), which no GString satisfies against a String,
    // and only Nextflow >= 26.04 folds `"${name}"` to a java.lang.String
    // for us. Without it every declared parameter is reported unknown on
    // 25.10.x — with a "Did you mean 'fastq_dir'?" naming the parameter
    // itself, since nearest_param() coerces on method dispatch and so was
    // the only half of this that kept working.
    params.keySet().sort().each { name ->
        if (!("${name}".toString() in known_params())) {
            def suggestion = nearest_param("${name}", known_params())
            errors << "  - unknown parameter '${name}'." +
                      (suggestion ? " Did you mean '${suggestion}'?" : '') +
                      " Run with --help for the full list."
        }
    }

    if (!sintax_references)
        errors << "  - 'sintax_references' is required (path to the sintax-formatted reference fasta)."
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
    if (!table_name || table_name.contains('/'))
        errors << "  - 'table_name' must be a filename, not a path (got: '${table_name}'). Use 'outdir' for the directory."
    if (params.outdir != null && params.results_table != null &&
        effective_outdir(null, params.results_table) != "${params.outdir}")
        log.warn "Both 'outdir' (${params.outdir}) and the deprecated 'results_table' (${params.results_table}) are set, and they disagree about the directory. 'outdir' wins; the table will be named '${table_name}' inside it."
    ['publish_beside_reads'].each { name ->
        if (!valid_bool(params[name]))
            errors << "  - '${name}' must be true or false (got: '${params[name]}')."
    }
    def valid_modes = ['link', 'copy', 'copyNoFollow', 'symlink', 'rellink']
    if (!(params.publish_mode in valid_modes))
        errors << "  - 'publish_mode' must be one of ${valid_modes} (got: '${params.publish_mode}')."
    // The link modes publish pointers *into* the work directory, so
    // deleting it on success leaves every output dangling — an
    // unreadable results table under a run that reported SUCCESS.
    def link_modes = ['symlink', 'rellink']
    if (coerce_bool(params.cleanup) && params.publish_mode in link_modes)
        errors << "  - 'publish_mode = ${params.publish_mode}' cannot be combined with 'cleanup = true': the published outputs are links into the work directory, which cleanup deletes. Use 'copy' (or leave cleanup off)."
    if (params.reference_size_gb != null && !("${params.reference_size_gb}" ==~ /\d+(\.\d+)?/))
        errors << "  - 'reference_size_gb' must be a positive number of GB (got: '${params.reference_size_gb}')."

    // Basecalling parameters, checked only when basecalling will run — the
    // common case reuses existing fastq and should not be held to the
    // format of settings it never applies. The patterns mirror the ones
    // bin/basecall_pod5_files.sh enforces, so the failure arrives at
    // startup instead of inside the first (GPU-bound) task.
    if (!coerce_bool(params.skip_basecall)) {
        if (!("${params.basecall_model}" ==~ /(fast|hac|sup)@v\d+\.\d+\.\d+/) &&
            !("${params.basecall_model}" ==~ /[a-z]+_[a-z0-9._]+_(fast|hac|sup)@v\d+\.\d+\.\d+/))
            errors << "  - 'basecall_model' must be fast|hac|sup@vX.Y.Z (e.g. 'sup@v5.2.0'), or a full dorado model name for other chemistry (e.g. 'dna_r9.4.1_e8_hac@v3.3.0'); got: '${params.basecall_model}'."
        if (!("${params.basecall_kit}" ==~ /[A-Z]{3}-[A-Z]{3}\d{3}/))
            errors << "  - 'basecall_kit' must look like XXX-XXX000 (e.g. 'EXP-PBC096', 'SQK-LSK114'); got: '${params.basecall_kit}'."
        if (!("${params.basecall_device}" ==~ /cpu|auto|metal|cuda:(all|\d+(,\d+)*)/))
            errors << "  - 'basecall_device' must be cpu, auto, metal, cuda:all, cuda:0 or cuda:0,1 (got: '${params.basecall_device}')."
        if (!params.basecall_model_dir)
            errors << "  - 'basecall_model_dir' is required when basecalling (the model cache location)."
    }

    // Basecalling is local-only. dorado is an ONT GPU binary that is not on
    // bioconda — so it is in neither the conda environment nor any
    // container built from it — and the shipped cluster profiles route
    // partitions by memory and time, which would put BASECALL on a CPU
    // node with no GPU. Refuse here rather than submit a job that cannot
    // work: the alternative is a queue wait followed by a failure whose
    // cause ("dorado: command not found", on a node the user never chose)
    // is far from its reason.
    def scheduler = workflow.session?.config?.navigate('process.executor')
    if (scheduler && "${scheduler}" != 'local' && !coerce_bool(params.skip_basecall))
        errors << "  - basecalling is not supported under the '${scheduler}' executor (dorado is a GPU binary outside the packaged environment, and the cluster profiles route by memory/time, not to GPU partitions). Basecall on a GPU workstation, then run here with 'skip_basecall = true' and 'fastq_dir' pointing at the result."

    // Some sites reject a submission with no account. A cluster profile
    // that knows this sets require_slurm_account, so the run stops here
    // with a specific message instead of every sbatch bouncing.
    if (coerce_bool(params.require_slurm_account ?: false) && !params.slurm_account)
        errors << "  - 'slurm_account' is required on this cluster (the profile sets require_slurm_account). Pass --slurm_account <account>, or set it in a -c site.config (see conf/site.config.example)."
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
        // storeDir cache: fetched once, then reused by every later run
        // without the process executing at all.
        DOWNLOAD_MODEL(full_model_name(params.basecall_model as String))
        BASECALL(pod5_dir_ch, DOWNLOAD_MODEL.out.model)
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
