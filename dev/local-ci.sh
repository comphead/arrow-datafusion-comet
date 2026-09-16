#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Run the Spark SQL or Iceberg CI workflow locally.
#
#   dev/local-ci.sh spark                      everything the Spark job runs
#   dev/local-ci.sh spark sql_core-1           one matrix row (or all/core/hive)
#   dev/local-ci.sh iceberg                    everything the Iceberg job runs
#   dev/local-ci.sh iceberg shard-2            one target
#
# The version defaults to the one the merge queue gates on, which is the newest
# Comet fully supports: Spark 4.1 and Iceberg 1.11 today. Older versions only
# run in the nightly tier, so pass one explicitly when reproducing a nightly
# failure:
#
#   dev/local-ci.sh spark 3.5 sql_core-1
#   dev/local-ci.sh iceberg 1.9
#
# Prepares the sandbox first (native build, Comet install, patched Spark or
# Iceberg clone), then runs the tests. SKIP_PREPARE=1 skips straight to the
# tests when the sandbox is already current.
#
# Mirrors .github/workflows/spark_sql_test_reusable.yml and
# .github/workflows/iceberg_spark_test_reusable.yml. The default version, the
# matrix rows and the shard count are read from those files and from dev/ci/,
# so a version bump needs no change here.
#
# COMET_LOCAL_CI_HOME  where the clones live (default ~/comet-local-ci)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_YML="$REPO/.github/workflows/ci.yml"
SPARK_YML="$REPO/.github/workflows/spark_sql_test_reusable.yml"
ICEBERG_YML="$REPO/.github/workflows/iceberg_spark_test_reusable.yml"
SANDBOX="${COMET_LOCAL_CI_HOME:-$HOME/comet-local-ci}"
case "$(uname -s)" in Darwin) LIB=libcomet.dylib ;; *) LIB=libcomet.so ;; esac

say() { printf '\n\033[1;32m[local-ci] %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[1;31m[local-ci] %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: dev/local-ci.sh <spark|iceberg> [version] [target...]

  dev/local-ci.sh spark                    everything the Spark job runs
  dev/local-ci.sh spark sql_core-1         one matrix row (or all/core/hive)
  dev/local-ci.sh iceberg                  everything the Iceberg job runs
  dev/local-ci.sh iceberg shard-2          one target (shard-N/extensions/runtime)

The version defaults to the one the merge queue gates on, the newest Comet
fully supports. Pass an older one to reproduce a nightly failure:

  dev/local-ci.sh spark 3.5 sql_core-1
  dev/local-ci.sh iceberg 1.9

  SKIP_PREPARE=1        skip the build and clone, run the tests only
  COMET_LOCAL_CI_HOME   where the clones live (default ~/comet-local-ci)
EOF
  exit 2
}

# The version the merge queue gates on, which is the newest one Comet fully
# supports. Every other version is nightly-tier or label-only. POLICY in
# compute-changes.py is where that is decided, so read it from there.
default_version() {
  sed -n "s/^    \"$1_\([0-9_]*\)\": \[\"queue\".*/\1/p" "$REPO/dev/ci/compute-changes.py" |
    tr _ . | sort -V | tail -1 | grep . || die "no queue-tier $1 version in compute-changes.py"
}

# A `with:` input of a ci.yml job, e.g. `input spark_4_1 spark-full` -> 4.1.3.
input() {
  awk -v job="$1" -v key="$2" '
    /^  [A-Za-z0-9_-]+:[ \t]*$/ { j = $1; sub(/:$/, "", j); w = 0; next }
    j == job && /^    with:[ \t]*$/ { w = 1; next }
    w && /^      [a-z][a-z0-9-]*:/ {
      k = $1; sub(/:$/, "", k)
      if (k != key) next
      v = $2; gsub(/\047/, "", v); print v; exit
    }
    w && /^    [a-z]/ { w = 0 }
  ' "$CI_YML" | grep . || die "no '$2' input for job '$1' in ci.yml"
}

setup_jdk() {
  if [ -x /usr/libexec/java_home ]; then
    JAVA_HOME="$(/usr/libexec/java_home -v "$1")" || die "JDK $1 not installed"
    export JAVA_HOME
  fi
  [ -n "${JAVA_HOME:-}" ] || die "export JAVA_HOME pointing at a JDK $1"
  say "JDK $1: $JAVA_HOME"
}

# cargo build --profile ci, then stage where the release Maven profile looks.
build_native() {
  say "cargo build --profile ci"
  (cd "$REPO/native" && cargo build --profile ci)
  mkdir -p "$REPO/native/target/release"
  cp "$REPO/native/target/ci/$LIB" "$REPO/native/target/release/$LIB"
}

# clone_patch <url> <tag> <dest> <diff>
clone_patch() {
  [ -d "$3/.git" ] || {
    say "cloning $1 at $2"
    git clone --depth 1 --branch "$2" "$1" "$3"
  }
  (cd "$3" && git apply --check --reverse "$4") 2>/dev/null || {
    say "applying $(basename "$4")"
    (cd "$3" && git apply "$4")
  }
}

install_comet() {
  say "mvnw install -Prelease -DskipTests $*"
  (cd "$REPO" && ./mvnw -B install -Prelease -DskipTests "$@")
}

# Comet's install leaves Parquet POMs in the local repository without their
# test-classifier JARs, and Coursier then calls the artifact found-locally
# instead of falling back to Maven Central. Both workflows drop the tree for
# that reason. Only the install poisons it, so this runs only after one.
purge_parquet() {
  dir="${MAVEN_REPO_LOCAL:-$HOME/.m2/repository}/org/apache/parquet"
  [ -d "$dir" ] || return 0
  say "removing $dir so sbt/gradle refetch it (this is what the workflows do)"
  rm -rf "$dir"
}

# The matrix rows of spark_sql_test_reusable.yml, from the definition the
# workflow builds its matrix from. Unit-separated, because a tab is IFS
# whitespace and `read` would collapse the empty args1 of an sql_core row.
spark_rows() {
  python3 - "$REPO/dev/ci/spark-sql-modules.py" "$@" <<'PY'
import json, subprocess, sys
path, want = sys.argv[1], sys.argv[2:] or ["all"]
rows = json.loads(subprocess.check_output([sys.executable, path, "--modules", "all"]))["module"]
names = [r["name"] for r in rows]
picked = []
for w in want:
    if w in ("all", "core", "hive"):
        picked += [r for r in rows if w == "all" or r["group"] == w]
    elif w in names:
        picked += [r for r in rows if r["name"] == w]
    else:
        sys.exit("unknown module %r; try: %s" % (w, ", ".join(names + ["all", "core", "hive"])))
for r in picked:
    print("\x1f".join([r["name"], r["args1"], r["args2"], r["heap"], r["metaspace"]]))
PY
}

run_spark() {
  short="$1"
  shift
  full="$(input "spark_${short//./_}" spark-full)"
  java="$(input "spark_${short//./_}" java)"
  dest="$SANDBOX/apache-spark-$full"
  rows="$(spark_rows "$@")"
  setup_jdk "$java"

  if [ -z "${SKIP_PREPARE:-}" ]; then
    build_native
    clone_patch https://github.com/apache/spark.git "v$full" "$dest" "$REPO/dev/diffs/$full.diff"
    install_comet "-Pspark-$short"
    purge_parquet
    say "pre-compiling Spark test classes"
    (cd "$dest" && NOLINT_ON_COMPILE=true build/sbt -Dsbt.log.noformat=true -mem 3072 \
      catalyst/Test/compile sql/Test/compile hive/Test/compile)
  fi

  # The workflow process-isolates a few suites on one Spark version only.
  gated="$(sed -n "s/.*DEDICATED_JVM_SBT_TESTS: .*spark-short == '\([^']*\)' && '\([^']*\)'.*/\1 \2/p" "$SPARK_YML")"
  case "$gated" in "$short "*) export DEDICATED_JVM_SBT_TESTS="${gated#* }" ;; esac

  while IFS=$'\037' read -r name args1 args2 heap metaspace; do
    [ -n "$name" ] || continue
    say "spark-sql-$name / spark-$full-jdk$java"
    (
      cd "$dest"
      printf -- '-J-Xms1g\n-J-Xmx4g\n-J-XX:MaxMetaspaceSize=1g\n' > .sbtopts
      export LC_ALL=C.UTF-8 SERIAL_SBT_TESTS=1 NOLINT_ON_COMPILE=true
      # shellcheck disable=SC2030  # the subshell is the point: one row per JVM
      export ENABLE_COMET=true ENABLE_COMET_ONHEAP=true
      export SBT_OPTS="-Xss4m -XX:+UseG1GC -XX:+UseStringDeduplication -XX:MaxMetaspaceSize=384m -XX:G1HeapRegionSize=2m -XX:InitiatingHeapOccupancyPercent=35 -XX:+ParallelRefProcEnabled -XX:+ExitOnOutOfMemoryError"
      [ -n "$heap" ] && export HEAP_SIZE="$heap"
      [ -n "$metaspace" ] && export METASPACE_SIZE="$metaspace"
      set -- -Dsbt.log.noformat=true -mem 1024 \
        "set Global / concurrentRestrictions := Seq(Tags.limit(Tags.ForkedTestGroup, 1))"
      [ -n "$args1" ] && set -- "$@" "$args1"
      [ -n "$args2" ] && set -- "$@" "$args2"
      build/sbt "$@"
    )
  done <<< "$rows"
}

run_iceberg() {
  short="$1"
  shift
  job="iceberg_${short//./_}"
  full="$(input "$job" iceberg-full)"
  spark="$(input "$job" spark-short)"
  java="$(input "$job" java)"
  # ci.yml leaves `scala` unset, so the reusable workflow default applies.
  scala="$(awk '/^      scala:/ { f = 1 } f && /^        default:/ { gsub(/[^0-9.]/, "", $2); print $2; exit }' "$ICEBERG_YML")"
  shards="$(sed -n 's/^SHARD_COUNT = //p' "$REPO/dev/ci/check-iceberg-shards.py")"
  dest="$SANDBOX/apache-iceberg-$full"

  # Default to the whole workflow, and vet the list before anything is built.
  if [ $# -eq 0 ]; then
    i=1
    while [ "$i" -le "$shards" ]; do
      set -- "$@" "shard-$i"
      i=$((i + 1))
    done
    set -- "$@" extensions runtime
  fi
  for target in "$@"; do
    case "$target" in
      extensions | runtime) ;;
      shard-*)
        i="${target#shard-}"
        case "$i" in *[!0-9]* | "") die "bad shard '$target'; try shard-1..$shards" ;; esac
        [ "$i" -ge 1 ] && [ "$i" -le "$shards" ] || die "bad shard '$target'; try shard-1..$shards"
        ;;
      *) die "unknown target '$target'; try shard-1..$shards, extensions, runtime" ;;
    esac
  done

  setup_jdk "$java"
  if [ -z "${SKIP_PREPARE:-}" ]; then
    build_native
    clone_patch https://github.com/apache/iceberg.git "apache-iceberg-$full" "$dest" \
      "$REPO/dev/diffs/iceberg/$full.diff"
    install_comet "-Pspark-$spark" "-Pscala-$scala"
    purge_parquet
  fi

  core=":iceberg-spark:iceberg-spark-${spark}_${scala}:test"
  for target in "$@"; do
    say "iceberg-$full / spark-$spark / $target"
    case "$target" in
      shard-*)
        run_gradle "$dest" "$core" --init-script "$REPO/dev/ci/iceberg-test-shards.gradle" \
          "-PcometShardTask=$core" "-PcometShardIndex=${target#shard-}" \
          "-PcometShardCount=$shards"
        ;;
      extensions)
        run_gradle "$dest" ":iceberg-spark:iceberg-spark-extensions-${spark}_${scala}:test"
        ;;
      runtime)
        # The workflow runs the sharding fixture in this job before the test.
        python3 "$REPO/dev/ci/check-iceberg-shards.py" --gradle "$dest/gradlew"
        run_gradle "$dest" ":iceberg-spark:iceberg-spark-runtime-${spark}_${scala}:integrationTest"
        ;;
      *) die "unknown target '$target'; try shard-1..$shards, extensions, runtime" ;;
    esac
  done
}

# run_gradle <dest> <task> [args...]. Reads $spark and $scala from run_iceberg.
run_gradle() {
  dir="$1"
  shift
  (
    cd "$dir"
    # shellcheck disable=SC2031  # set fresh here, not inherited from run_spark
    export SPARK_LOCAL_IP=localhost ENABLE_COMET=true ENABLE_COMET_ONHEAP=true
    ./gradlew "-DsparkVersions=$spark" "-DscalaVersion=$scala" \
      -DflinkVersions= -DkafkaVersions= "$@" -Pquick=true -x javadoc
  )
}

[ $# -ge 1 ] || usage
what="$1"
shift
case "$what" in spark | iceberg) ;; *) usage ;; esac

# A version is the only argument shaped like N.N; anything else is a target.
case "${1:-}" in
  [0-9]*.[0-9]*)
    version="$1"
    shift
    ;;
  *)
    version="$(default_version "$what")"
    say "$what $version (the version the merge queue gates on)"
    ;;
esac

case "$what" in
  spark) run_spark "$version" "$@" ;;
  iceberg) run_iceberg "$version" "$@" ;;
esac
say "done"
