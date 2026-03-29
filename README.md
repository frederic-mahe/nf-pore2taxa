# nf-pore2taxa

quick taxonomic assignment of Nanopore metabarcoding data


## Introduction

**nf-pore2taxa** is a [netxflow](https://nextflow.io/) bioinformatics
analysis pipeline used for Nanopore amplicon sequencing. Its goal is
to provide _quick & dirty_ taxonomic profiles. To do so, it supports
taxonomic assignment with the [sintax](https://doi.org/10.1101/074161)
method, as implemented in
[vsearch](https://github.com/torognes/vsearch), and produces an
occurrence table (identified taxa vs. barcode ID). Read processing is
minimal: a simple primer trimming and conversion to fasta. Read are
then grouped based on their taxonomic assignments (sintax cutoff:
0.90). Any taxonomic reference dataset can be used (16S/18S SSU rRNA,
ITS, COI, etc.), as long as it is properly formated (fasta file, with
headers in sintax format).

> [!NOTE] **sintax format**: the reference database (fasta) must
> contain taxonomic information in the header of each sequence in the
> form of a string starting with ";tax=" and followed by a
> comma-separated list of up to nine taxonomic identifiers. Each
> taxonomic identifier must start with an indication of the rank by
> one of the letters d (for domain) k (kingdom), p (phylum), c
> (class), o (order), f (family), g (genus), s (species), or t
> (strain). The letter is followed by a colon (:) and the name of that
> rank. Commas and semicolons are not allowed in the name of the
> rank. Non-ascii characters should be avoided in the names.


## Pipeline summary

By default, the pipeline currently performs the following:

- basecalling and demultiplexing of pod5 ('super accurate') with
  [dorado](https://github.com/nanoporetech/dorado)
- trimming of reads with
  [cutadapt](https://cutadapt.readthedocs.io/en/stable/)
- taxonomic assignment with
  [vsearch](https://github.com/torognes/vsearch) (sintax)
- build an occurrence table (using [R](https://cran.r-project.org/)
  and the [tidyverse](https://tidyverse.org/) package)

The basecalling step can be skipped if `fastq` files are already
available.


## Usage

First, you need to prepare a `config` file, with the parameters for
your project.

```
// nf-pore2taxa workflow

workDir = "/big/drive/projects/project_ID/work"

params {
    pod5_dir      = "/big/drive/runs/run_ID/pod5"
    fastq_dir     = "/big/drive/projects/project_ID/data/run_ID"
    sintax_silva  = "/safe/data/references.fasta.gz"
    results_table = "/big/drive/projects/project_ID/results/sintax.tsv"
    primer_f = "GTACACACCGCCCGTCG"
    primer_r = "CGCCTSCSCTTANTDATATGC"

    // Set to true if basecalling was already done
    // and fastq_dir already exists
    skip_basecall = false
}
```

> [!NOTE] Intermediate files are linked (hardlinks), so it is
> important for workDir and fastq_dir to be on the same filesystem.

Now, you can run the pipeline using:

```bash
nextflow \
    run main.nf \
    -config /path/to/myproject.config
```

Parameters can also be passed via the command-line, if need be.


## Pipeline output

A tab-separated table with identified taxa as rows, and barcode IDs
(i.e, samples) as columns. The first line is the header line (column
names). An additional column with the total number of reads for each
taxa is also provided (column number 2). Barcodes without any
assignments are grouped at the far-right of the table.

Here is a tiny output table example with only two barcodes, and two
identified taxa:

| taxonomy        | total | barcode03 | barcode01 |
|-----------------|------:|----------:|----------:|
| d:Fungi ...     |  1234 |      1234 |         0 |
| d:Viridiplantae |    42 |        42 |         0 |

`barcode01` is empty (no assigned reads), so it appears last.

## Road-map

- [X] eliminate variability due to sintax? not currently possible
- [ ] refactor `assign_with_sintax.sh`. Use `nextflow` to find and
      loop over the `fastq.gz` files. Operate on each file
      independently, publish back the results in the same directory
- [ ] add a module that checks if binaries (cutadapt, vsearch, dorado)
      are in PATH? already done by the different scripts
- [X] `assign_with_sintax.sh` eliminate fastq to fasta conversion,
      cutadapt can read `fastq.gz` directly
- [ ] add a module that checks parameters? do we need to pass
      parameters that are not used? for instance, if we skip
      basecalling, do we need to pass the path to `pod5` files?
- [ ] eliminate dependency to `R` and the `tidyverse` package, rewrite
      script in python?

## See also

- [NanoASV](https://github.com/ImagoXV/NanoASV): a snakemake-based
  workflow for Nanopore amplicon sequencing (16S/18S SSU rRNA)
