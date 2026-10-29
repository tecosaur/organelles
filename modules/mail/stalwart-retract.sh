# Usage: stalwart-retract PREVIOUS CURRENT
#
# Retracts the Stalwart settings PREVIOUS declared and CURRENT no longer does: an upserted or
# reconciled object whose key has gone is destroyed, though never an Account, which holds mail,
# and a singleton's dropped property returns to its default. Reaches Stalwart as stalwart-cli
# does, through STALWART_URL, STALWART_USER and STALWART_PASSWORD. Exits non-zero if anything
# remains.

previous="$1" current="$2"
plan=$(jq -nc --slurpfile was "$previous" --slurpfile now "$current" '
  # Upserted or reconciled entries, by the properties that identify them
  def entries: [.[] | select(."@type" == "upsert" or ."@type" == "reconcile") | .object as $object | .matchOn as $on
    | .value | to_entries[] | {$object, ref: .key, match: (.value | if $on == "*" then . else with_entries(select(.key | IN($on[]))) end)}];
  # The properties updated on each singleton
  def updated: [.[] | select(."@type" == "update" and .id == null)] | group_by(.object)
    | map({key: .[0].object, value: (map(.value | keys) | add | unique)}) | from_entries;
  ($now | [.[] | select(."@type" == "reconcile") | .object]) as $reconciled
  | ($now | entries) as $kept | ($now | updated) as $after
  | {
      earlier: ($was | entries),
      # Later entries link to earlier ones, so last first; a reconcile drops what it no longer names itself
      stale: [$was | entries | reverse[] | select(.object != "Account" and (.object | IN($reconciled[]) | not))
        | select(. as $e | $kept | any(.object == $e.object and .match == $e.match) | not)],
      resets: [$was | updated | to_entries[] | {object: .key, properties: (.value - ($after[.key] // []))}
        | select(.properties != [])]
    }')
# The ids of an object's instances with these properties; a "#name" value is the earlier entry it names
locate() {
  local object="$1" match="$2" name entry id
  while read -r name; do
    entry=$(jq -c --arg ref "$name" 'first(.earlier[] | select(.ref == $ref))' <<<"$plan")
    id=$([ -z "$entry" ] || locate "$(jq -r .object <<<"$entry")" "$(jq -c .match <<<"$entry")") || return 1
    # Unless it names exactly one, nothing can link to it
    [ -n "$id" ] && [ "$(wc -l <<<"$id")" -eq 1 ] || return 0
    match=$(jq -c --arg ref "#$name" --arg id "$id" 'map_values(if . == $ref then $id else . end)' <<<"$match")
  done < <(jq -r '.[] | strings | select(startswith("#")) | ltrimstr("#")' <<<"$match")
  stalwart-cli query "$object" --fields "$(jq -r 'keys | join(",")' <<<"$match")" --json |
    jq -r --argjson match "$match" 'select(. as $found | $match | to_entries | all(.value == $found[.key])) | .id'
}
failed=0
while read -r entry; do
  object=$(jq -r .object <<<"$entry")
  ids=$(locate "$object" "$(jq -c .match <<<"$entry")" | paste -sd,) || { failed=1; continue; }
  [ -n "$ids" ] || continue
  echo "stalwart: retracting $object $(jq -c .match <<<"$entry")"
  stalwart-cli delete "$object" --ids "$ids" >/dev/null || failed=1
done < <(jq -c '.stale[]' <<<"$plan")
if jq -e '.resets != []' >/dev/null <<<"$plan"; then
  # The password goes in a header read from a pipe, never in argv
  schema=$(curl -sSfL --compressed -H @<(printf 'Authorization: Basic %s' "$(printf '%s:%s' "$STALWART_USER" "$STALWART_PASSWORD" | base64 -w0)") \
    "$STALWART_URL/api/schema")
  while read -r reset; do
    object=$(jq -r .object <<<"$reset")
    singleton=$(stalwart-cli get "$object" --json) || { failed=1; continue; }
    # A property of a variant takes the default of the variant the singleton now is
    op=$(jq -c --slurpfile schema <(printf '%s' "$schema") --argjson singleton "$singleton" '
      $schema[0] as $schema | $schema.schemas["x:" + .object] as $kind
      | $schema.fields[if $kind.type == "single" then $kind.schemaName
          else first($kind.variants[] | select(.name == $singleton["@type"]) | .schemaName) end].defaults as $defaults
      | {"@type": "update", object,
         value: (.properties | map(. as $property | select($defaults | has($property)) | {key: ., value: $defaults[.]}) | from_entries),
         lacking: (.properties | map(. as $property | select($defaults | has($property) | not)))}' <<<"$reset") ||
      { failed=1; continue; }
    if jq -e '.lacking != []' >/dev/null <<<"$op"; then
      echo "stalwart: $object's $(jq -r '.lacking | join(", ")' <<<"$op") has no default to return to; declare it in the settings" >&2
      failed=1
    fi
    jq -e '.value != {}' >/dev/null <<<"$op" || continue
    echo "stalwart: returning $object's $(jq -r '.value | keys | join(", ")' <<<"$op") to the default"
    stalwart-cli apply --quiet --stdin < <(jq -c 'del(.lacking)' <<<"$op") || failed=1
  done < <(jq -c '.resets[]' <<<"$plan")
fi
exit "$failed"
