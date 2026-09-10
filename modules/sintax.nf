include { coerce_bool      } from './local/functions'
include { effective_outdir } from './local/functions'

process SINTAX {
    tag "${barcode}"

    // The conda profile (environment.yml) pins vsearch/cutadapt; the
    // in-script version check in assign_with_sintax.sh stays as the safety
    // net for bare-PATH runs (the default `standard` profile).
    //
    // Per-barcode results go under outdir, so the raw-data tree stays
    // read-only and a run has one directory to archive.
    publishDir { "${effective_outdir(params.outdir, params.results_table)}/per_barcode" },
               mode: params.publish_mode, overwrite: true

    // DEPRECATED (removal at v2.0.0): additionally publish back beside the
    // reads, as every release before v1.12.0 did. A second publishDir, so
    // enabling it adds the old location rather than replacing the new one —
    // a config that sets it keeps working without losing the consolidated
    // layout. main.nf warns when it is on.
    //
    // Gated with `enabled:` rather than by resolving the path to null, which
    // Nextflow rejects outright ("Target path for directive publishDir
    // cannot be null") — and only at task-finalisation time, so the run
    // fails after the work is done rather than at startup.
    //
    // `enabled:` takes the coercion inline rather than calling coerce_bool():
    // the strict DSL2 parser reads a function call in a directive argument as
    // a directive name of its own ("Unknown process directive:
    // `coerce_bool`"). Same `"${v}" == 'true'` spelling the config uses for
    // `cleanup`, and for the same reason — a CLI override arrives as a string.
    publishDir { "${params.fastq_dir}/fastq_pass/${barcode}" },
               mode: params.publish_mode, overwrite: true,
               enabled: "${params.publish_beside_reads}" == 'true'

    input:
    tuple val(barcode), path(fastqs)
    path  references

    output:
    tuple val(barcode), path("${barcode}.sintax"), path("${barcode}.log"), emit: assigned

    script:
    // Strict amplicon filtering (drop reads with no primer) is the default;
    // discard_untrimmed = false keeps every read. coerce_bool normalises a
    // config boolean and a CLI `--discard_untrimmed false` (string) alike.
    def primer_filter = coerce_bool(params.discard_untrimmed) ? '--discard-untrimmed' : '--keep-untrimmed'
    // The staged names go into a list file rather than onto the command
    // line. Interpolating them as arguments made the argv of an execve,
    // which is capped: ~32,000 names of 56 characters exhaust ARG_MAX
    // (2 MiB under a default 8 MB stack) and the task dies with exit 126
    // and `Argument list too long` — reachable for one scattered barcode
    // of a large run. A heredoc is read from this script file, which has
    // no such ceiling. Quoted delimiter, so nothing in a file name is
    // expanded (SX-19).
    """
    cat > fastq_list.txt << 'FASTQ_LIST'
${fastqs.join('\n')}
FASTQ_LIST

    bash \\
    assign_with_sintax.sh \\
        --barcode "${barcode}" \\
        --references "${references}" \\
        --forward-primer "${params.primer_f}" \\
        --reverse-primer "${params.primer_r}" \\
        --threads "${task.cpus}" \\
        --randseed "${params.randseed}" \\
        --subsample "${params.subsample}" \\
        ${primer_filter} \\
        --fastq-list fastq_list.txt
    """

    // Under -stub-run: one plausible 4-field sintax row, so BUILD_TABLE (which
    // is stdlib Python and runs for real) has something to count and the
    // published table has the shape a real one has. An empty file would let a
    // broken table-builder pass.
    stub:
    """
    printf 'stub_read;length=4\\td:Synthetica(1.00)\\t+\\td:Synthetica\\n' \\
        > "${barcode}.sintax"
    touch "${barcode}.log"
    """
}
