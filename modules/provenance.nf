include { effective_outdir } from './local/functions'


// Provenance artefacts: what software ran, and with what parameters.
//
// Both publish into a `pipeline_info/` subdirectory beside the occurrence
// tables — the layout `--outdir` will adopt, so that release re-roots the
// directory rather than moving files.

process DUMP_VERSIONS {
    tag "versions"

    publishDir { "${effective_outdir(params.outdir, params.results_table)}/pipeline_info" },
               mode: params.publish_mode, overwrite: true

    input:
    // Zero or more `<name><TAB><raw version>` fragments contributed by
    // processes that know a version this probe cannot see. Today that is
    // just dorado, from BASECALL: dorado is an ONT GPU binary, not in the
    // conda environment, and on a cluster it may not exist at all on the
    // node this probe lands on — so the task that actually ran it is the
    // only place its version can be read honestly. An empty list is
    // normal (skip_basecall = true).
    path fragments

    output:
    path 'software_versions.yml', emit: versions

    script:
    // ktImportText has no --version: it exits non-zero on one, and prints
    // its version in the banner it writes when called with no arguments
    // ("KronaTools 2.8.1 - ktImportText"). Every probe is `|| true` +
    // `2>&1` so a missing tool yields an empty string, which
    // collect_versions.py records as 'n/a' rather than dropping the line —
    // an absent line would read as "not used", a different claim.
    //
    // The fragment glob is deliberately literal-safe: with no fragments
    // staged, `versions_*.tsv` does not expand and `cat` fails, which the
    // `2>/dev/null || true` swallows. Passing `${fragments}` directly
    // would interpolate to an empty string, and a bare `cat` would then
    // read stdin and hang the task forever.
    """
    {
        printf 'nf-pore2taxa\\t%s\\n' "${workflow.manifest.version}"
        printf 'nextflow\\t%s\\n'     "${workflow.nextflow.version}"
        printf 'vsearch\\t%s\\n'      "\$(vsearch --version 2>&1 | head -n 1 || true)"
        printf 'cutadapt\\t%s\\n'     "\$(cutadapt --version 2>&1 | head -n 1 || true)"
        printf 'krona\\t%s\\n'        "\$(ktImportText 2>&1 | grep -o 'KronaTools [0-9.]*' | head -n 1 || true)"
        printf 'python\\t%s\\n'       "\$(python3 --version 2>&1 | head -n 1 || true)"
        cat versions_*.tsv 2>/dev/null || true
    } | python3 ${projectDir}/bin/collect_versions.py > software_versions.yml
    """

    // Under -stub-run: the tools are absent, so their versions are
    // unknowable. Recorded as 'n/a', which is the same thing the real probe
    // does for a tool it cannot reach — a stub that invented version numbers
    // would be worse than one that admits it does not know.
    stub:
    """
    {
        printf 'nf-pore2taxa\\t%s\\n' "${workflow.manifest.version}"
        printf 'nextflow\\t%s\\n'     "${workflow.nextflow.version}"
        printf 'vsearch\\tn/a\\n'
        printf 'cutadapt\\tn/a\\n'
        printf 'krona\\tn/a\\n'
        printf 'python\\tn/a\\n'
    } | python3 ${projectDir}/bin/collect_versions.py > software_versions.yml
    """
}


process DUMP_PARAMS {
    tag "params"

    publishDir { "${effective_outdir(params.outdir, params.results_table)}/pipeline_info" },
               mode: params.publish_mode, overwrite: true

    input:
    val params_json   // pre-rendered by main.nf, so the shape is testable there

    output:
    path 'params.json', emit: params_file

    script:
    // Quoted heredoc: Nextflow interpolates ${params_json} into the
    // script, and the quoting then stops the *shell* from expanding
    // anything inside it — a reference path containing '$' would
    // otherwise be mangled on its way to disk.
    """
    cat > params.json <<'PARAMS_JSON_EOF'
${params_json}
PARAMS_JSON_EOF
    """
}
