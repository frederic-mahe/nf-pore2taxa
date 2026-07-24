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
