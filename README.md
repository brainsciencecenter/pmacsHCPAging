# pmacsHCPAging

Scripts for processing HCP-A data on the PMACS cluster.

## Getting the data

Scripts were testing using data from the HCP-A 2.0 release. The preprocessed
structural data were downloaded, diffusion was run locally.

## HCP Pipelines container

The container is built from BIDS-Apps/HCPPipelines v4.3.0-3. This is a BIDS app,
but the HCP does not release data in BIDS format, so the scripts expect the
default HCP organization.

Beware the container is very large (27Gb uncompressed).


## Running the Diffusion processing

The script in `diffusion/DiffusionPreprocessingBatch.sh` is configured to expect
HCP-A diffusion data under `$StudyFolder/$SubjectID/unprocessed/3T/Diffusion`.
It requires T1w processed output.

