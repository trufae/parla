#!/bin/bash
# Run parla under gdb. When it crashes, the backtrace lands in
# /tmp/dc-crash.log. Share that file when reporting the crash.
#
# Usage: pkill parla ; ./run-debug.sh
#
# (apport eats core dumps for non-package binaries on Ubuntu, so gdb is the
#  most reliable way to capture a stack trace from a real crash.)

LOG=/tmp/dc-crash.log
BIN=${1:-./builddir/parla}

: > "$LOG"
exec gdb -q -batch \
  -ex "set pagination off" \
  -ex "set logging redirect on" \
  -ex "set logging file $LOG" \
  -ex "set logging enabled on" \
  -ex "handle SIGPIPE nostop noprint pass" \
  -ex "run" \
  -ex "bt full" \
  -ex "thread apply all bt" \
  -ex "quit" \
  --args "$BIN"
