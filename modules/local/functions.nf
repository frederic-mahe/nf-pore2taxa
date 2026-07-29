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
