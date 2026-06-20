#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { BASECALL    } from './modules/basecall'
include { SINTAX      } from './modules/sintax'
include { BUILD_TABLE } from './modules/build_table'


workflow {

    // Resolve the deprecated `sintax_silva` alias for `sintax_references`
    if (params.sintax_silva != null) {
        log.warn "Parameter 'sintax_silva' is deprecated; please use 'sintax_references' instead."
    }
    sintax_references = params.sintax_references ?: params.sintax_silva

    references_ch = Channel.fromPath(sintax_references, type: 'file', checkIfExists: true)

    if (params.skip_basecall) {
        // fastq_dir must already exist on disk — point directly at it
        fastq_ch = Channel.fromPath(params.fastq_dir, type: 'dir', checkIfExists: true)
    } else {
        pod5_dir_ch = Channel.fromPath(params.pod5_dir, type: 'dir', checkIfExists: true)
        BASECALL(pod5_dir_ch)
        fastq_ch = BASECALL.out.done.map { it.parent.toString() }
    }

    SINTAX(fastq_ch, references_ch)
    BUILD_TABLE(SINTAX.out.done.map { it.parent.toString() })  // it.parent = module's work directory
}
