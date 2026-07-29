include { optimistic_name      } from './local/functions'
include { effective_outdir     } from './local/functions'
include { effective_table_name } from './local/functions'

process BUILD_TABLE {
    tag "build_table"

    // Closure (lazy): evaluated per task, not at process-definition time,
    // so a null params.results_table is reported by the workflow's
    // startup parameter validation rather than a raw file() error here.
    publishDir { effective_outdir(params.outdir, params.results_table) },
               mode: params.publish_mode, overwrite: true

    input:
    path sintax_files  // every per-barcode <barcode>.sintax, staged flat

    output:
    // Declared by exact name rather than a '*.tsv' glob. The glob only
    // matched when results_table happened to end in '.tsv': any other
    // extension (e.g. results/table.txt) produced a script that exited 0
    // and a task that then failed on "missing output file", after every
    // SINTAX task had already run. optimistic_name() mirrors
    // name_optimistic_output() in bin/build_occurrence_table.py.
    path { effective_table_name(params.table_name, params.results_table) },
         emit: filtered
    path { optimistic_name(effective_table_name(params.table_name, params.results_table) as String) },
         emit: optimistic

    script:
    def output_file = effective_table_name(params.table_name, params.results_table)
    """
    python3 \\
        ${projectDir}/bin/build_occurrence_table.py \\
        --input-dir . \\
        --output "${output_file}"
    """
}
