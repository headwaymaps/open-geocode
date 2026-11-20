#!/usr/bin/env bash
# Usage: bench/before-after.sh BEFORE_REF AFTER_REF
# Builds og and the Netherlands Pack at each ref from one extract, then runs
# `bench measure` and `bench ceiling` on each, og only, with this branch's
# 10-core layout. Results go to bench/results/<ref>-<mode>/. A rerun keeps
# the Packs already built and redoes only the benches.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 BEFORE_REF AFTER_REF" >&2; exit 2; }
bench=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$bench")
work=$HOME/og-bench
export OG_HOME=$work/og-home
build_cpus=2-11
mkdir -p "$work" "$OG_HOME"

fail() { echo "before-after: $*" >&2; exit 1; }

missing=()
[ -x /usr/bin/time ] || missing+=(time)
command -v fio >/dev/null || missing+=(fio)
[ ${#missing[@]} -eq 0 ] || fail "first run: sudo apt install ${missing[*]}"
for tool in taskset systemd-run systemctl lscpu sha256sum curl cargo docker ss; do
  command -v "$tool" >/dev/null || fail "$tool is not on the PATH"
done
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail "the harness needs cgroup v2"
[ -r /proc/pressure/cpu ] || fail "the harness needs /proc/pressure (PSI)"
docker info >/dev/null 2>&1 || fail "docker must work without sudo: add yourself to the docker group"
docker compose version >/dev/null 2>&1 || fail "docker compose is missing"
for port in 7100 7999; do
  [ -z "$(ss -Htln "sport = :$port")" ] || fail "port $port is in use; the harness serves on it"
done
for ref in "$@"; do
  git -C "$repo" rev-parse --verify -q "$ref^{commit}" >/dev/null || fail "no commit $ref; git fetch first"
done

# The harness runs `sudo -n` throughout. Ask for the password once, then keep
# sudo's cached credential fresh until this script exits.
sudo -v
while sudo -n -v; do sleep 60; done &
keepalive=$!
trap 'kill $keepalive 2>/dev/null' EXIT

sudo -n mkdir -p /srv/og-bench
sudo -n chown "$(id -u):$(id -g)" /srv/og-bench

[ -x "$work/bin/oha" ] || cargo install oha --locked --root "$work"

# The extract the query set was drawn from (bench/data/queries/meta.json), where
# the harness hashes it and, linked, where og builds from it.
pbf_name=netherlands-261101.osm.pbf
pbf=$work/data/pbf/$pbf_name
og_pbf=$OG_HOME/pbf/netherlands.osm.pbf
pbf_sha256=$(sed -n 's/.*"pbf_sha256": "\(.*\)".*/\1/p' "$bench/data/queries/meta.json")
verified() { echo "$pbf_sha256  $1" | sha256sum -c --quiet >/dev/null 2>&1; }
mkdir -p "$(dirname "$pbf")" "$(dirname "$og_pbf")"
if ! verified "$pbf"; then
  if verified "$og_pbf"; then
    ln -f "$og_pbf" "$pbf"
  else
    rm -f "$pbf.part"
    curl -fL -o "$pbf.part" "https://download.geofabrik.de/europe/netherlands/$pbf_name"
    verified "$pbf.part" || fail "the downloaded $pbf_name does not match meta.json's sha256"
    mv "$pbf.part" "$pbf"
  fi
fi
rm -f "$og_pbf.part"
[ "$pbf" -ef "$og_pbf" ] || ln -f "$pbf" "$og_pbf"

(cd "$bench" && cargo build --release)

for ref in "$@"; do
  [ -d "$work/pack-$ref" ] && [ -s "$work/build-time-$ref.txt" ] && continue
  src=$work/src-$ref
  [ -d "$src" ] || git -C "$repo" worktree add --detach "$src" "$ref"
  git -C "$src" checkout -q --detach "$ref"
  (cd "$src" && cargo build --release --bin og --features tui)
  rm -rf "$OG_HOME/packs/netherlands" "$work/build-time-$ref.txt"
  /usr/bin/time -v -o "$work/build-time-$ref.txt.part" \
    taskset -c "$build_cpus" "$src/target/release/og" build --region netherlands --fresh
  rm -rf "$work/pack-$ref"
  mv "$OG_HOME/packs/netherlands" "$work/pack-$ref"
  mv "$work/build-time-$ref.txt.part" "$work/build-time-$ref.txt"
done

for ref in "$@"; do
  mkdir -p "$repo/target/release"
  cp "$work/src-$ref/target/release/og" "$repo/target/release/og"
  (cd "$bench/engines/og" && docker compose build og)
  docker run --rm og-bench/og:under-test --version >/dev/null \
    || fail "the og image will not run; its base may have an older glibc than this host built against"
  rm -rf /srv/og-bench/pack
  cp -a "$work/pack-$ref" /srv/og-bench/pack
  for mode in measure ceiling; do
    out=$bench/results/$ref-$mode
    rm -rf "$out"
    "$bench/target/release/bench" "$mode" --engine og --profile quick \
      --oha "$work/bin/oha" --out "$out"
  done
done
echo "results: $bench/results/; build timings: $work/build-time-*.txt"
