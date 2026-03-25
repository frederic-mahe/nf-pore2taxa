# nf-pore2taxa

quick taxonomic assignment of Nanopore metabarding data

## road map

- [ ] eliminate variability due to sintax
- [ ] refactor `assign_with_sintax.sh`. Use `nextflow` to find and
      loop over the `fastq.gz` files. Operate on each file
      independently, publish back the results in the same directory
