#!/usr/bin/env bash
# Usage: bench/before-after.sh BEFORE_REF AFTER_REF
# Builds og and the Netherlands Pack at each ref from one extract, then runs
# `bench measure` and `bench ceiling` on each, og only, with this branch's
# 10-core layout. Results go to bench/results/<ref>/.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 BEFORE_REF AFTER_REF" >&2; exit 2; }
bench=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$bench")
work=${OG_BENCH_WORK:-$HOME/og-bench}
export OG_HOME=$work/og-home
build_cpus=2-11
mkdir -p "$work" "$OG_HOME"
sudo -n mkdir -p /srv/og-bench
sudo -n chown "$(id -u):$(id -g)" /srv/og-bench

[ -x "$work/bin/oha" ] || cargo install oha --locked --root "$work"
(cd "$bench" && cargo build --release)

for ref in "$@"; do
  src=$work/src-$ref
  [ -d "$src" ] || git -C "$repo" worktree add --detach "$src" "$ref"
  git -C "$src" checkout -q --detach "$ref"
  (cd "$src" && cargo build --release --bin og)
  rm -rf "$OG_HOME/packs/netherlands"
  /usr/bin/time -v -o "$work/build-time-$ref.txt" \
    taskset -c "$build_cpus" "$src/target/release/og" build --region netherlands --fresh
  rm -rf "$work/pack-$ref"
  mv "$OG_HOME/packs/netherlands" "$work/pack-$ref"
done

for ref in "$@"; do
  mkdir -p "$repo/target/release"
  cp "$work/src-$ref/target/release/og" "$repo/target/release/og"
  (cd "$bench/engines/og" && docker compose build og)
  rm -rf /srv/og-bench/pack
  cp -a "$work/pack-$ref" /srv/og-bench/pack
  for mode in measure ceiling; do
    "$bench/target/release/bench" "$mode" --engine og --profile quick \
      --oha "$work/bin/oha" --out "$bench/results/$ref-$mode"
  done
done
echo "results: $bench/results/; build timings: $work/build-time-*.txt"
