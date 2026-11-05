#!/usr/bin/env bash
#
# Assembles tree-sitter grammars into the layout Sextant loads at runtime.
#
# Writes this layout to $out:
#   $out/<language>/parser          grammar library (symlink)
#   $out/<language>/highlights.scm  highlight query, composed as the grammar's tree-sitter.json says
#   $out/<language>/tags.scm        tags query (definitions/references), when the grammar has one
#   $out/languages.json             [{name, symbol, fileTypes}]
#
# Reads $grammarsFile, which lists one grammar per line as
# <attr> <package> <source> [<file-types>]. The optional comma-separated <file-types> adds to
# what the grammar's tree-sitter.json lists.

set -euo pipefail
mkdir -p "$out"
index=()

declare -A sources
while read -r attr pkg src types; do sources[$attr]=$src; done < "$grammarsFile"

#######################################
# Resolves a query path listed in a grammar's tree-sitter.json to an absolute path.
# Paths under node_modules/tree-sitter-<name>/ resolve into that grammar's source tree.
# Globals:
#   sources
# Arguments:
#   Directory holding the tree-sitter.json.
#   Query path as listed in tree-sitter.json.
# Outputs:
#   Writes the absolute query path to stdout, or nothing if the referenced grammar is unknown.
#######################################
resolve() {
  local dir=$1 path=$2
  if [[ $path =~ ^node_modules/tree-sitter-([^/]+)/(.*)$ ]]; then
    local dep=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
    [[ -n ${sources[$dep]:-} ]] && echo "${sources[$dep]}/$rest"
  else
    echo "$dir/$path"
  fi
}

#######################################
# Concatenates a grammar's query files into one query file.
# Arguments:
#   Directory holding the tree-sitter.json.
#   JSON array of query paths as listed in tree-sitter.json.
#   Fallback query file, used when none of the listed paths exist.
#   Destination file.
# Outputs:
#   Writes the destination file, or removes it if no query was found.
#######################################
compose() {
  local dir=$1 list=$2 fallback=$3 dest=$4 found=0
  for p in $(jq -r '.[]' <<<"$list"); do
    local f; f=$(resolve "$dir" "$p")
    if [[ -n $f && -f $f ]]; then cat "$f" >> "$dest"; echo >> "$dest"; found=1; fi
  done
  if [[ $found == 0 && -f $fallback ]]; then cat "$fallback" > "$dest"; found=1; fi
  [[ $found == 1 ]] || rm -f "$dest"
}

as_list='if . == null then [] elif type == "string" then [.] else . end'

while read -r attr pkg src types; do
  json=""
  for candidate in "$src/tree-sitter.json" "$pkg/tree-sitter.json"; do
    [[ -f $candidate ]] && { json=$candidate; break; }
  done
  entry='{}'
  if [[ -n $json ]]; then
    entry=$(jq -c --arg name "${attr//-/_}" '
      [.grammars[] | select((.name | gsub("-"; "_")) == $name)] as $byName
      | ($byName | first) // (.grammars | if length == 1 then first else {} end)' "$json")
  fi
  name=$(jq -r --arg d "$attr" '(.name // $d) | gsub("-"; "_")' <<<"$entry")
  path=$(jq -r '.path // "."' <<<"$entry")
  dir=$(dirname "${json:-$src/x}")
  qdir="$pkg/queries"
  for d in "$src/$path/queries" "$src/queries/$attr" "$src/queries"; do
    [[ -f $qdir/highlights.scm ]] && break
    qdir=$d
  done

  mkdir -p "$out/$attr"
  ln -s "$pkg/parser" "$out/$attr/parser"
  compose "$dir" "$(jq -c ".highlights | $as_list" <<<"$entry")" "$qdir/highlights.scm" "$out/$attr/highlights.scm"
  compose "$dir" "$(jq -c ".tags | $as_list" <<<"$entry")" "$qdir/tags.scm" "$out/$attr/tags.scm"

  fileTypes=$(jq -c --arg extra "${types:-}" '(.["file-types"] // []) + ($extra | split(",") | map(select(. != ""))) | unique' <<<"$entry")
  index+=("$(jq -nc --arg n "$attr" --arg s "tree_sitter_$name" --argjson t "$fileTypes" '{name: $n, symbol: $s, fileTypes: $t}')")
done < "$grammarsFile"

printf '%s\n' "${index[@]}" | jq -s '.' > "$out/languages.json"
