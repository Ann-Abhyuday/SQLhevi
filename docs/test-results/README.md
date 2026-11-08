# Test evidence

The project and executable names in historical reports, log copies, CSV labels, and sample
configurations were normalized to **SQLhevi** during the rename. Absolute checkout paths in
those copies were made relative. These edits do not represent new test runs or changed results.

Historical executable and source digests still identify the artifacts from their original runs;
they are not checksums of the current renamed build or sources. Result-file manifests cover
the normalized log copies. An unchanged archive of the
pre-rename project and evidence is retained locally in
`.tooling/rename-history/project-before.tar.gz`.

The `rename/` directory contains fresh validation of the SQLhevi executables. Other directories
retain their original workload, memory-limit, and platform qualifications as described in their
associated reports.
