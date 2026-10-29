---
name: unit-test-writer
description: Write unit tests for a function or module the user points to. Use when the user asks for tests.
---

# Unit test writer

1. Read the target file and identify its public functions.
2. Detect the test framework already used in the project (pytest, jest, go test). Use it.
3. For each function, cover the normal case, an edge case and an error case.
4. Put the tests next to the existing tests, following the project's naming.
5. Run the tests and report the results.
