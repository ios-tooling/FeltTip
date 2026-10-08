#!/bin/bash
#
# Runs wall-clock performance gates separately from the ordinary correctness
# suite. Shared-machine load can make absolute budgets fail without a code
# regression; invoke this on an otherwise idle machine when measuring them.

set -o pipefail

# Each timing gate also needs to run without competing benchmark suites.
FELTTIP_RUN_BENCHMARKS=1 swift test --no-parallel --filter 'PerformanceTests|BenchmarkTests'
