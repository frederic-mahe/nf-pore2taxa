// Shared helper functions for nf-pore2taxa.
//
// Nextflow scopes `include` per file, so every consumer imports what it
// needs: main.nf uses these at the workflow level, and process modules
// (e.g. modules/sintax.nf) import them for use inside a `script:` block.

// Coerce a parameter to a real Boolean.
//
// A value set in a -config file is already a Boolean, but a command-line
// `--flag` / `--flag false` override arrives as the *string* 'true' /
// 'false'. `"${v}" == 'true'` normalises both forms (Boolean true and
// String 'true' -> true; everything else -> false). Pair with valid_bool()
// in startup validation so a stray value such as 'yes' is rejected rather
// than silently coerced to false.
def coerce_bool(v) {
    "${v}" == 'true'
}

// True when v is a valid boolean parameter: a real Boolean, or the CLI
// string form 'true'/'false'. Used by startup validation to reject
// anything else before coerce_bool() flattens it.
def valid_bool(v) {
    "${v}" in ['true', 'false']
}

// How many threads a process will actually get: its configured request,
// reduced by the resource ceiling (process.resourceLimits clamps it).
//
// Used to decide whether the `randseed` reproducibility warning applies —
// vsearch sintax is only exactly reproducible single-threaded, so the
// warning must fire on the EFFECTIVE thread count, not the configured
// one: `--max_cpus 1` genuinely makes a seeded run replayable and must not
// be warned about.
//
// Defensive because both inputs come from resolved config: a request that
// cannot be read as a number (e.g. someone set `cpus = { ... }` as a
// closure) is assumed to want the whole ceiling, which is the
// conservative reading for a warning — better to mention reproducibility
// when it may not hold than to stay silent when it does not.
def effective_threads(configured, ceiling) {
    int limit = 1
    try { limit = "${ceiling}" as int } catch (Exception ignored) { limit = 1 }
    int want = limit
    try { want = "${configured}" as int } catch (Exception ignored) { }
    Math.max(1, Math.min(want, limit))
}

// Every parameter this pipeline declares.
//
// Nextflow accepts any `--foo bar` silently and puts it in `params`, so a
// typo — `--subsampl 100` — leaves the real parameter at its default while
// the user believes they set it. That is the same silent-wrong-result class
// the v1.7.1 release was about, so startup validation compares the params it
// was given against this list.
//
// MUST stay in lock-step with the `params { }` block in nextflow.config and
// the `params.x` assignments in conf/slurm.config — PRM-02 asserts both
// directions, so a parameter added to the config without a line here (or the
// reverse) fails the suite rather than becoming quietly unrejectable.
//
// Kept here rather than derived from the config at runtime because `params`
// cannot distinguish "declared with a default" from "arrived on the command
// line": by the time the workflow sees it, both are just keys.
def known_params() {
    [
        // inputs
        'pod5_dir', 'fastq_dir', 'sintax_references',
        // output
        'outdir', 'table_name',
        // amplicon
        'primer_f', 'primer_r', 'discard_untrimmed', 'subsample', 'randseed',
        'reference_size_gb',
        // behaviour
        'skip_basecall', 'krona', 'publish_mode', 'cleanup', 'help',
        // basecalling
        'basecall_model', 'basecall_kit', 'basecall_device',
        'basecall_model_dir',
        // resources
        'max_cpus', 'max_memory', 'max_time',
        // slurm (injected by conf/slurm.config; accepted always, so passing
        // one without a cluster profile is inert rather than an error)
        'slurm_queue', 'slurm_account', 'slurm_clusterOptions',
        'slurm_queue_size', 'slurm_array_size', 'require_slurm_account',
        // deprecated, still honoured (removal at v2.0.0)
        'sintax_silva', 'results_table', 'publish_beside_reads',
    ]
}

// Edit distance between two strings, for "did you mean ...?".
//
// A rejection that only says "unknown parameter" makes the user re-read the
// help to spot a one-character difference; naming the intended parameter is
// the difference between a two-second fix and a puzzled five minutes.
def levenshtein(String a, String b) {
    def previous = (0..b.length()).collect { it }
    a.each { ch ->
        def current = [previous[0] + 1]
        b.eachWithIndex { other, j ->
            current << [ previous[j] + (ch == other ? 0 : 1),  // substitute
                         current[j] + 1,                       // insert
                         previous[j + 1] + 1                   // delete
                       ].min()
        }
        previous = current
    }
    previous[-1]
}

// The declared parameter closest to `name`, or null when nothing is close
// enough to be worth suggesting.
//
// The threshold scales with the name's length: one edit is a plausible slip
// in a short name, three in a long one, but three edits away from `krona` is
// a different word entirely and guessing would mislead.
def nearest_param(String name, List candidates) {
    def limit = Math.max(1, Math.min(3, (name.length() / 3) as int))
    def scored = candidates.collect { [it, levenshtein(name.toLowerCase(), it.toLowerCase())] }
    def best = scored.min { it[1] }
    (best && best[1] <= limit) ? best[0] : null
}

// The single output directory for a run.
//
// `outdir` is the canonical parameter from v1.12.0. `results_table` is the
// deprecated one it replaces: it named the filtered table by full path, and
// everything else was published relative to its parent — so a run's outputs
// were spread across the results directory AND the raw-data tree. When only
// the old parameter is given, its parent stands in, which is what keeps
// existing project configs producing exactly what they did before.
//
// Falls back to 'results' so `nextflow run main.nf` with neither is still a
// valid invocation rather than an error about a path nobody set.
def effective_outdir(outdir, results_table) {
    if (outdir)
        return "${outdir}"
    if (results_table) {
        // A bare filename has no parent; the launch directory is then the
        // implied location, as it was before.
        def parent = new File("${results_table}").parent
        return parent ?: '.'
    }
    'results'
}

// The filename of the filtered occurrence table.
//
// Taken from the deprecated `results_table`'s basename when that is what the
// user supplied, so their table keeps the name they chose; otherwise
// `table_name`.
def effective_table_name(table_name, results_table) {
    results_table ? new File("${results_table}").name : "${table_name}"
}

// Flowcell/chemistry prefix dorado's model names carry. Must stay in
// lock-step with MODEL_PREFIX in bin/basecall_pod5_files.sh: the pipeline
// downloads the model under this name and the script checks for it under
// that same name, so a mismatch means a model fetched to one path and
// looked for at another (BC-11 pins that they agree).
def model_prefix() {
    'dna_r10.4.1_e8.2_400bps_'
}

// The full dorado model directory name for a `basecall_model` value.
//
// A short name (`sup@v5.2.0`) names a speed and a version and gets the
// prefix; anything else is already a full dorado model name and is passed
// through, which is how a different flowcell or chemistry is targeted
// (`dna_r9.4.1_e8_hac@v3.3.0`). Mirrors full_model_name() in
// bin/basecall_pod5_files.sh.
def full_model_name(String model) {
    model ==~ /^(fast|hac|sup)@.*/ ? "${model_prefix()}${model}" : model
}

// True when v is usable as a memory ceiling: something Nextflow can read
// as a memory size, and strictly greater than zero.
//
// params.max_memory arrives either as a real MemoryUnit (the auto-detected
// default, or `128.GB` written in a config) or as a String (a CLI
// `--max_memory '32.GB'`). Both must be accepted; a value Nextflow cannot
// parse must be rejected at startup, because otherwise it surfaces much
// later as "Not a valid FileSize value" on the first task submission. A
// zero ceiling parses fine and would clamp every request to nothing, so
// it is rejected too.
def valid_memory(v) {
    try {
        new nextflow.util.MemoryUnit("${v}").toBytes() > 0
    }
    catch (Exception ignored) {
        false
    }
}

// The fastq extensions the pipeline supports.
//
// MUST stay in lock-step with FASTQ_SUFFIXES in
// bin/discover_barcodes.py: main.nf enumerates a run's reads with these
// to build DISCOVER_BARCODES' cache key, and the script then re-walks the
// tree with its own list. An extension listed in one and not the other
// means a file that is discovered but does not invalidate the cache (or
// the reverse). A function rather than a top-level constant because
// Nextflow's strict DSL2 parser allows declarations, not statements, at
// the top level of a script.
def fastq_extensions() {
    ['fastq', 'fastq.gz', 'fastq.bz2', 'fastq.xz']
}

// Derive the *optimistic* table's filename from the filtered one, by
// inserting '_optimistic' before the final extension.
//
//   'sintax.tsv' -> 'sintax_optimistic.tsv'
//   'table.txt'  -> 'table_optimistic.txt'
//   'table'      -> 'table_optimistic'
//
// This MUST stay byte-identical to name_optimistic_output() in
// bin/build_occurrence_table.py: BUILD_TABLE declares its two output
// files by name, so a disagreement between the two implementations shows
// up as a "missing output file" at the end of a run (the failure mode
// that the '*.tsv' output glob used to produce for any non-.tsv name).
// A leading dot is not an extension, matching pathlib's Path.suffix.
def optimistic_name(String name) {
    int dot = name.lastIndexOf('.')
    dot > 0 ? "${name[0..<dot]}_optimistic${name[dot..-1]}"
            : "${name}_optimistic"
}
