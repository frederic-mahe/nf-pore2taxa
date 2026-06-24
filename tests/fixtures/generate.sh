#!/bin/bash
# Regenerate the synthetic test fixtures.
#
# This script is run by hand whenever the fixture design changes.  The
# files it writes are committed to the repo so tests do not depend on
# this script at run time.
#
# Layout produced:
#   references.fasta              -- sintax-formatted reference DB (2 taxa)
#   fastq_dir/fastq_pass/
#     barcode01/reads.fastq.gz    -- reads matching ref1 (primers attached)
#     barcode02/reads.fastq.gz    -- reads matching ref2 (primers attached)
#     barcode03/reads.fastq.gz    -- reads without primers (will be dropped)

set -euo pipefail

cd "$(dirname "$0")"

PRIMER_F="GTACACACCGCCCGTCG"
# Reverse-complement of the reverse primer (one IUPAC realisation:
# H->A, N->A, S->C). cutadapt's error-rate of 0.2 tolerates the
# remaining ambiguity-vs-actual mismatches.
RC_PRIMER_R="GCATATAATAAGCGCAGGCG"

# Two short, distinct, GC-balanced "reference" sequences. Generated
# once with python (seed 42) and pasted here so the fixture is
# reproducible and does not require Python at fixture-generation time.
# They are synthetic; we only need vsearch sintax to make a confident
# assignment when a read matches them exactly.
REF1="GACAGGTACAAGAAGGAGTATGCATCAATGTGGTCGTGTGGAACAAACGCCACTGGAGACTGGGTTAACCATTCGCTCCAGCGTCATGAAAGTCACTGTTAGGGCGACCTTCGATTCGGATGTGACATTTCATTACATTACGCTCAGGACTGCGAACGAA"
REF2="AGATTAAGAATGCTTAACCCGGTACCTAACCCATCTGATTTTTACACACTCTCCTTGGACTGGGAGGTATAAGGAATAGGCGGTAGACGCCTACTTAACTTTCATGGTGATCGTAAAGCGGAGCCTTACCATGCGGCAATTGTGAACTTTTAAATTCGAT"

# --- reference database (sintax format) ---------------------------------------
cat > references.fasta <<EOF
>ref1;tax=d:Synthetica,k:Alphakingdom,p:Alphaphylum,c:Alphaclass,o:Alphaorder,f:Alphafamily,g:Alphagenus,s:Alpha_one
${REF1}
>ref2;tax=d:Synthetica,k:Betakingdom,p:Betaphylum,c:Betaclass,o:Betaorder,f:Betafamily,g:Betagenus,s:Beta_two
${REF2}
EOF

# --- fastq writer -------------------------------------------------------------

# Write a fastq read to stdout.  Quality string is all "I" (Phred 40).
write_read() {
    local -r id="${1}"
    local -r seq="${2}"
    local qual=""
    local i
    for ((i = 0 ; i < ${#seq} ; i++)) ; do qual+="I" ; done
    printf '@%s\n%s\n+\n%s\n' "${id}" "${seq}" "${qual}"
}

mkdir -p fastq_dir/fastq_pass/barcode01 \
         fastq_dir/fastq_pass/barcode02 \
         fastq_dir/fastq_pass/barcode03

# 5 reads matching ref1, each carrying primers.
{
    for i in 1 2 3 4 5 ; do
        write_read "read${i}_b01" "${PRIMER_F}${REF1}${RC_PRIMER_R}"
    done
} | gzip > fastq_dir/fastq_pass/barcode01/reads.fastq.gz

# 5 reads matching ref2, each carrying primers.
{
    for i in 1 2 3 4 5 ; do
        write_read "read${i}_b02" "${PRIMER_F}${REF2}${RC_PRIMER_R}"
    done
} | gzip > fastq_dir/fastq_pass/barcode02/reads.fastq.gz

# 5 reads with NO primers — cutadapt --discard-untrimmed will drop
# them all, producing an empty .sintax file for this barcode.
{
    for i in 1 2 3 4 5 ; do
        write_read "read${i}_b03" "AAAAAAAAAA${REF1}AAAAAAAAAA"
    done
} | gzip > fastq_dir/fastq_pass/barcode03/reads.fastq.gz

# --- flat layout fixture (barcode embedded in the filename) ------------------
# No barcode subfolders: the barcode token lives in the filename, as can
# happen when basecalling did not demultiplex into folders. barcode01 is
# split across two files (a multi-file barcode), and a sibling fastq_fail/
# directory must be IGNORED by discovery (rooted at fastq_pass/).
mkdir -p flat_dir/fastq_pass flat_dir/fastq_fail

# barcode01: 3 + 2 = 5 reads (ref1, primers), across two files.
{
    for i in 1 2 3 ; do write_read "read${i}_b01a" "${PRIMER_F}${REF1}${RC_PRIMER_R}" ; done
} | gzip > flat_dir/fastq_pass/run1_barcode01_0.fastq.gz
{
    for i in 4 5 ; do   write_read "read${i}_b01b" "${PRIMER_F}${REF1}${RC_PRIMER_R}" ; done
} | gzip > flat_dir/fastq_pass/run1_barcode01_1.fastq.gz

# barcode02: 5 reads (ref2, primers), single file.
{
    for i in 1 2 3 4 5 ; do write_read "read${i}_b02" "${PRIMER_F}${REF2}${RC_PRIMER_R}" ; done
} | gzip > flat_dir/fastq_pass/run1_barcode02_0.fastq.gz

# fastq_fail: reads that must never be counted (discovery ignores it).
{
    for i in 1 2 3 4 5 ; do write_read "read${i}_fail" "${PRIMER_F}${REF1}${RC_PRIMER_R}" ; done
} | gzip > flat_dir/fastq_fail/run1_barcode01_0.fastq.gz

echo "Wrote:"
find references.fasta fastq_dir flat_dir -type f | sort
