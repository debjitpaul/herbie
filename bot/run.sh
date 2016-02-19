#!/usr/bin/env bash

# this is where herbie lives on warfa for nightlies
# you may change HERBROOT to test locally,
#   but do not push any changes to HERBROOT!
HERBROOT="$HOME/herbie"

# example crontab entry for nightlies
# 30 2 * * * $HOME/herbie/bot/run.sh

cd "$HERBROOT"
git pull --quiet

make --quiet --directory=randTest
java -classpath randTest/ RandomTest \
  --size   5 \
  --nvars  3 \
  --ntests 5 \
  > "$HERBROOT/bench/random.rkt"

function run {
  time xvfb-run --auto-servernum \
    racket herbie/reports/run.rkt \
      --note "$2" \
      --profile \
      --threads 4 \
      "$1"
  make publish
}

for b in $HERBROOT/bench/*; do
  name=$(basename "$b" .rkt)
  # skip some massive or misbehaving benchmarks
  case $name in
    haskell|mathematics|numerics|regression)
      continue
      ;;
  esac
  LOG="$HERBROOT/bot/$name-$(date +%y%m%d%H%M%S).log"
  ln -sf "$LOG" "$HERBROOT/bot/latest.log"
  run "$b" "$name" &> "$LOG"
done
