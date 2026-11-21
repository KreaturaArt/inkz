# Differential checker fixtures

Hand-made cases for the test of `src/testing/differential.zig`'s `check_directory`. The test
copies them to a temporary directory, because the checker writes `<name>.inkz.json` files.

| Case | What it is |
|---|---|
| `match` | ink's JSON and transcript, as `ink_harness batch` wrote them |
| `transcript` | the same, with one line of the transcript changed |
| `acceptance` | ink "rejects" it (a made-up `.compile_errors`); inkz compiles it |
| `structure` | ink's JSON with an unused list added: it plays the same |
| `timeout` | ink didn't finish: nothing is compared |
