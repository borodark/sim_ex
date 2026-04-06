#!/bin/bash
# sim_ex vs SimPy — Head-to-Head Race
#
# Sequential execution: Python first, then Elixir.
# Each gets full CPU. Fair fight.
#
# Requirements:
#   pip install simpy
#   mix deps.get (in sim_ex/)
#
# Usage: bash benchmark/simpy_race/run_race.sh

set -e

PYTHON=${PYTHON:-python3}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo ""
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║  sim_ex vs SimPy — Head-to-Head Race                 ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  Machine: $(uname -m)"
echo "  Cores: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
echo "  Load avg: $(cat /proc/loadavg 2>/dev/null | cut -d' ' -f1-3 || uptime | grep -oE 'load average[s]?: [0-9., ]+' || echo 'unknown')"
echo "  Python: $($PYTHON --version 2>&1)"
echo "  SimPy: $($PYTHON -c 'import simpy; print(simpy.__version__)' 2>/dev/null || echo 'not installed')"
echo ""

echo "  ════════════════════════════════════════════════════════"
echo "  SimPy Results (Python)"
echo "  ════════════════════════════════════════════════════════"
echo ""

echo "  ── Barbershop M/M/1 ──"
$PYTHON "$SCRIPT_DIR/barbershop.py"
echo ""

echo "  ── Job Shop (5 stages) ──"
$PYTHON "$SCRIPT_DIR/job_shop.py"
echo ""

echo "  ── Rework Loop (15%) ──"
$PYTHON "$SCRIPT_DIR/rework.py"
echo ""

echo "  ── Batch Replications ──"
$PYTHON "$SCRIPT_DIR/batch_reps.py"
echo ""

echo "  ════════════════════════════════════════════════════════"
echo "  sim_ex Results (Elixir + Rust NIF)"
echo "  ════════════════════════════════════════════════════════"
echo ""

cd "$PROJECT_DIR"
mix run benchmark/simpy_race/race.exs
