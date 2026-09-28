#!/bin/bash
#
# Runs wall-clock performance gates separately from the ordinary correctness
# suite. Shared-machine load can make absolute budgets fail without a code
# regression; invoke this on an otherwise idle machine when measuring them.

set -o pipefail

FELTTIP_RUN_BENCHMARKS=1 swift test --filter 'PerformanceTests|BenchmarkTests'
