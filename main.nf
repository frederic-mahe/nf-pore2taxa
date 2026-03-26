#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

include { BASECALL    } from './modules/basecall'
include { SINTAX      } from './modules/sintax'
include { BUILD_TABLE } from './modules/build_table'


workflow {

    references_ch = Channel.fromPath(params.sintax_silva, type: 'file', checkIfExists: true)

    if (params.skip_basecall) {
        // fastq_dir must already exist on disk — point directly at it
        fastq_ch = Channel.fromPath(params.fastq_dir, type: 'dir', checkIfExists: true)
    } else {
        pod5_dir_ch = Channel.fromPath(params.pod5_dir, type: 'dir', checkIfExists: true)
        BASECALL(pod5_dir_ch)
        fastq_ch = BASECALL.out.done.map { "${params.fastq_dir}/fastq_pass" }
    }

    SINTAX(fastq_ch, references_ch)
    BUILD_TABLE(SINTAX.out.done.map { "${params.fastq_dir}" })

}
