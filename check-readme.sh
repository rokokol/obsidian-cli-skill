#!/usr/bin/env bash
# The mechanical half of the rules in SKILL.md, checked on a readme.
#
# Only the rules a script can decide are here: whether a paragraph ends bare,
# whether it occupies one line, whether an admonition is shaped the way GitHub
# wants it, and whether a section duplicates a file that already exists. Tone,
# structure and honesty about versions stay a reading job — this catches the
# four things that would otherwise be re-caught by eye on every readme.
set -euo pipefail

fail=0
file=''
n=0
report() { # report MESSAGE — about $file, at line $n
  printf '%s:%s: %s\n' "$file" "$n" "$1" >&2
  fail=1
}

for file in "$@"; do
  [ -f "$file" ] || {
    printf 'readme: %s: no such file\n' "$file" >&2
    fail=1
    continue
  }
  inside=0
  prev_prose=0
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    case $line in
      '```'*)
        inside=$((1 - inside))
        prev_prose=0
        continue
        ;;
    esac
    [ "$inside" -eq 1 ] && continue

    # Rule 4: sections that have their own file at the root of a repository
    case $line in
      '#'*[Ll]icense* | '#'*[Cc]ontributing* | '#'*[Cc]hangelog*)
        report "a heading for something that has its own file: ${line}"
        ;;
    esac

    # Rule 5: the admonition keyword takes its line alone, or GitHub renders a
    # plain quote instead of the box
    case $line in
      '> [!'*']'?*)
        report "text on the admonition keyword's line — it belongs below"
        ;;
    esac

    # Rule 7: a paragraph, a list item and a table cell all end bare
    case $line in
      *..) ;;
      *[!.].)
        report "ends with a full stop"
        ;;
    esac

    # Rule 6: one paragraph is one line. Badge rows, tables, lists, headings and
    # html are not paragraphs; two prose lines in a row are a hard wrap
    case $line in
      '' | '#'* | '-'* | '*'* | '|'* | '>'* | '<'* | '!['* | '['* | ' '*)
        prev_prose=0
        ;;
      *)
        [ "$prev_prose" -eq 1 ] && report "a hard-wrapped paragraph — one paragraph is one line"
        prev_prose=1
        ;;
    esac
  done <"$file"
done

exit "$fail"
