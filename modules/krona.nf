include { effective_outdir } from './local/functions'


process KRONA {
    tag "krona"

    // The conda profile (environment.yml) pins KronaTools; the in-script
    // presence check in build_krona.sh stays as the safety net for
    // bare-PATH runs (the default `standard` profile).
    //
    // Publish the Krona HTML(s) beside the occurrence tables.
    publishDir { effective_outdir(params.outdir, params.results_table) },
               mode: params.publish_mode, overwrite: true

    input:
    path tsv_files  // the occurrence TSVs (filtered + optimistic), staged flat

    output:
    path "*.html", emit: html

    script:
    """
    bash \\
    build_krona.sh \\
        ${tsv_files}
    """

    // Under -stub-run: KronaTools is absent, so stand in for both charts.
    stub:
    """
    touch krona.html krona_optimistic.html
    """
}
