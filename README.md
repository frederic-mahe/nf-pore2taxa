# nf-pore2taxa

quick taxonomic assignment of Nanopore metabarding data

## road map

- [X] eliminate variability due to sintax? not currently possible
- [ ] add a module that checks parameters, do we need to pass
      parameters that are not used? for instance, if we skip
      basecalling, do we need to pass the path to pod5 files?
- [ ] refactor `assign_with_sintax.sh`. Use `nextflow` to find and
      loop over the `fastq.gz` files. Operate on each file
      independently, publish back the results in the same directory
