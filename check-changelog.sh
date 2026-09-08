#!/usr/bin/env bash
# Decide the machine-checkable half of a changelog. Takes ANY changelog, so it is worth
# more than a review comment: drop it into a repository's own gate and the rules stop
# depending on somebody remembering them.
#
#   check-changelog.sh [-v VERSION-FILE | -n] [CHANGELOG]
#
#   -v FILE   the repository's version file (default: VERSION beside the changelog)
#   -n        assert this repository has no version, whatever files are lying around
#
# A repository HAS a version when someone can install a particular one and report a bug
# against it. Then its headings are `## [x.y.z]` and an `## Unreleased` section is where
# work waits for the next release. A repository that is only ever read at whatever revision
# is checked out has no version to be wrong about: its headings are dates, and `Unreleased`
# is a state it can never be in, so the section would never close.
#
# Exit: 0 clean, 1 findings printed, 2 a usage error.
set -uo pipefail

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die() {
  printf 'check-changelog: %s\n' "$1" >&2
  exit 2
}

version_file=""
no_version=""
while (($#)); do
  case "$1" in
    -v)
      version_file="${2:?-v needs a file}"
      shift 2
      ;;
    -n)
      no_version=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

changelog="${1:-CHANGELOG.md}"
[[ -r "$changelog" ]] || die "cannot read $changelog"
[[ -z "$no_version" || -z "$version_file" ]] || die "-n and -v contradict each other"

if [[ -z "$no_version" && -z "$version_file" ]]; then
  default="$(dirname "$changelog")/VERSION"
  [[ -r "$default" ]] && version_file="$default"
fi

version=""
if [[ -n "$version_file" ]]; then
  [[ -r "$version_file" ]] || die "cannot read $version_file"
  version=$(tr -d '[:space:]' <"$version_file")
  [[ -n "$version" ]] || die "$version_file is empty"
fi

# Strictly-less-than on x.y.z, field by field. Not `sort -V`, which is a GNU extension the
# BSD sort on macOS may not have — the same reason there is no `mapfile` here. A
# prerelease suffix is ignored for ordering; it is not what this check is about.
version_lt() { # version_lt A B -> 0 when A < B
  local -a ia ib
  local i x y
  IFS=. read -r -a ia <<<"${1%%[-+]*}"
  IFS=. read -r -a ib <<<"${2%%[-+]*}"
  for i in 0 1 2; do
    x=${ia[$i]:-0}
    y=${ib[$i]:-0}
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 1
}

findings=0
report() { # report LINE MESSAGE
  printf '%s:%s: %s\n' "$changelog" "$1" "$2"
  findings=$((findings + 1))
}

# Headings, with their line numbers, in the order the file states them. A read loop rather
# than `mapfile`, which is bash 4.0+ — this checker is meant to be dropped into other
# repositories' gates, and macOS ships bash 3.2.
headings=()
while IFS= read -r heading_line; do
  headings+=("$heading_line")
done < <(grep -n '^## ' "$changelog")
# An extractor that finds nothing must say so rather than read as "all clear": a file with
# no headings at all is not a clean changelog, it is an unparsed one
((${#headings[@]} > 0)) || {
  report 1 "no '## ' headings at all — nothing here records anything"
  exit 1
}

seen_dated=""
prev_date=""
prev_version=""
found_current=""

for entry in "${headings[@]}"; do
  line="${entry%%:*}"
  text="${entry#*:}"
  text="${text#\#\# }"
  text="${text%"${text##*[![:space:]]}"}"

  case "$text" in
    Unreleased | '[Unreleased]')
      if [[ -z "$version" ]]; then
        report "$line" "an Unreleased section in a repository with no version — it holds work that has landed but not shipped, which cannot happen here, so it never closes"
      fi
      ;;

    '['*']'*)
      # `## [x.y.z]`, optionally followed by a date
      v="${text#\[}"
      v="${v%%]*}"
      if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
        report "$line" "'$text' is not a version heading — expected ## [x.y.z]"
        continue
      fi
      [[ "$v" == "$version" ]] && found_current=1
      if [[ -n "$seen_dated" ]]; then
        report "$line" "a numbered heading above a dated one — dated entries belong on top, where a repository that stopped shipping versions keeps its newer work"
      fi
      if [[ -n "$prev_version" ]]; then
        version_lt "$v" "$prev_version" ||
          report "$line" "[$v] is not older than the [$prev_version] above it — newest first"
      fi
      prev_version="$v"
      ;;

    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      seen_dated=1
      if [[ -n "$version" ]]; then
        report "$line" "a dated heading in a repository that ships version $version — a shipped artifact's changelog is numbered, so a reader can match an entry to what they installed"
      fi
      if [[ -n "$prev_date" && ! "$text" < "$prev_date" ]]; then
        report "$line" "$text is not older than the $prev_date above it — newest first"
      fi
      prev_date="$text"
      ;;

    *) report "$line" "'$text' is neither a version, a date, nor Unreleased" ;;
  esac
done

if [[ -n "$version" && -z "$found_current" ]]; then
  report 1 "VERSION says $version but no '## [$version]' heading records what is in it"
fi

((findings == 0)) || exit 1
