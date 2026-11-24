# Where macOS CI minutes go in open-source iOS projects

Collected on 22–23 November 2026 from the GitHub API, read-only.

- **Repositories:** 81 active, non-fork Swift or Objective-C repositories with at least 300 stars,
  pushed since 1 October 2026, whose workflows run `xcodebuild` on Xcode 26 (`swift.txt`; the
  workflow files are in `hits.txt`).
- **Runs:** the last 15 completed runs of each such workflow, macOS jobs only: 1172 runs, 3824
  jobs, 399 runner hours (`steps.jsonl.gz`, step names and timings only).
- **Categories:** steps are sorted by name with the regular expressions in `analyze.py`. They are
  crude: a step named after a scheme counts as "other", and a test step includes the compiling
  that `xcodebuild test` does first.

`results.txt` is the output of `python3 analyze.py`; `steps.py` collects the data again (needs
`gh`).
