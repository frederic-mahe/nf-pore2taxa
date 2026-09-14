include { effective_outdir     } from './local/functions'
include { effective_table_name } from './local/functions'
include { krona_name           } from './local/functions'
include { optimistic_name      } from './local/functions'


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
    // The names must be the ones a real run publishes, so krona_name()
    // derives them from the table name exactly as build_krona.sh does from
    // the table itself (KR-42/FN-11) — a stub that touched different
    // filenames would check a topology nobody ships.
    stub:
    def table = effective_table_name(params.table_name, params.results_table) as String
    """
    touch ${krona_name(table)} ${krona_name(optimistic_name(table) as String)}
    """
}
