# Shared helpers for the secret generators. Sourced, not executed.
#
# Which secrets exist comes from secrets.nix's rules, derived from the declarations,
# and who they are encrypted to from recipients.nix.

: "${rules:?lib.sh: \$rules must name a secrets.nix}"
: "${tool_name:=secrets}"

readonly secrets_pid=$$
readonly recipients_file="$(dirname "$rules")/recipients.nix"
readonly manifest="$(dirname "$rules")/../site/manifest.nix"

declare -a recipients=() # the admin, then each host

readonly colour_present=$'\e[32m'
readonly colour_absent=$'\e[31m'
readonly colour_partial=$'\e[33m'
readonly colour_muted=$'\e[2m'
readonly colour_off=$'\e[0m'
readonly mark_present="${colour_present}✓${colour_off}"
readonly mark_absent="${colour_absent}✗${colour_off}"
readonly mark_partial="${colour_partial}~${colour_off}"
readonly mark_wrote=$'\e[35m→\e[0m'

function die() {
    echo "$tool_name: $*" >&2
    exit 1
}

# `nix run`, less the warnings it emits about the invoking environment rather
# than about the run itself: an unset locale, and nix.conf settings this
# version does not know. Anything else on stderr is passed through.
function nix_run() {
    local status
    { nix run "$@" 2>&1 1>&3 |
        grep -vE 'setlocale: LC_ALL|^warning: unknown setting' >&2
      status=${PIPESTATUS[0]}
    } 3>&1
    return "$status"
}

# Every `<path>.age` the declarations name, sorted.
function declared_secrets() {
    nix-instantiate --eval --strict --json -E "builtins.attrNames (import $(realpath "$rules"))" |
        jq -r '.[]'
}

# `<name>:<generator>` for every declared key the scripts generate.
function generated_keys() {
    nix-instantiate --eval --strict --json -E "
      let inherit (import $(realpath "$manifest")) site; in
      builtins.filter (s: s != null) (builtins.attrValues (builtins.mapAttrs (path: secret:
        if secret.kind == \"key\" && secret.generate != null
        then builtins.replaceStrings [ \"keys/\" \".age\" ] [ \"\" \"\" ] path + \":\" + secret.generate
        else null)
        site.secret-files))" | jq -r '.[]'
}

# `<path>\t<description>` for every secret that gives one. Evaluated rather than
# parsed: the rules are Nix, and agenix ignores the attribute either way.
function secret_descriptions() {
    nix eval --raw --impure --expr "
      let rules = import (/. + \"$(realpath "$rules")\");
      in builtins.concatStringsSep \"\n\" (builtins.filter (s: s != \"\")
        (builtins.attrValues (builtins.mapAttrs
          (name: v: if v ? description then name + \"\t\" + v.description else \"\")
          rules)))"
}

# A secret typed at the terminal, echoed as asterisks so its length is visible
# and a typo is correctable. The value goes to stdout, everything else to
# stderr, so callers can capture it. Empty when stdin is not a terminal, which
# leaves the caller's own default in play.
function read_secret() {
    local char prompt="" value="" count=0
    [ -t 0 ] || { IFS= read -r value; printf '%s' "$value"; return; }
    # Reading one character at a time means the terminal cannot turn ^C and ^D
    # into a signal and an end-of-file, so they arrive as bytes and are acted on
    # here: ^C abandons the whole run, ^D ends entry as an empty answer.
    while IFS= read -p "$prompt" -r -s -n 1 char; do
        case "$char" in
            $'\0'|$'\n') break ;;
            $'\3') printf '\n' >&2; kill -INT "$secrets_pid"; return 130 ;;
            $'\4') value=""; break ;;
            $'\177'|$'\b')
                if [ "$count" -gt 0 ]; then
                    count=$((count - 1)); prompt=$'\b \b'; value="${value%?}"
                else
                    prompt=""
                fi ;;
            *) count=$((count + 1)); prompt='*'; value+="$char" ;;
        esac
    done >&2
    printf '\n' >&2
    printf '%s' "$value"
}

# `name = "ssh-..."` in recipients.nix is a recipient's key.
function read_recipients() {
    mapfile -t recipients < <(sed -n 's/^[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_-]*\)[[:space:]]*=[[:space:]]*"ssh-.*/\1/p' "$recipients_file")
    [ ${#recipients[@]} -gt 0 ] || die "no recipient keys found in $recipients_file"
}

# Matched on the key body alone: the trailing comment is free text.
function local_binding() {
    local pub body binding
    for pub in "$HOME"/.ssh/id_*.pub; do
        [ -e "$pub" ] || continue
        body="$(cut -d' ' -f1,2 <"$pub")"
        binding="$(grep -F "$body" "$recipients_file" | sed -n 's/^\s*\([a-z][a-zA-Z0-9_-]*\)\s*=.*/\1/p')"
        [ -n "$binding" ] || continue
        printf '%s' "$binding"
        return
    done
}

# A secret must be declared before agenix can encrypt it: secrets.nix finds its
# recipients from the declaration.
function register_secret() {
    local file="$1"
    declared_secrets | grep -qxF "$file" ||
        die "$file is not declared; declare it in the site.nix of the app or module" \
            "that uses it (site.secrets), so secrets.nix knows whom to encrypt it to"
}

# Every recipient key but this machine's, which is the workstation these are
# run from. Generators encrypt to a node plus the workstation, so mistaking one
# for the other would put node keys where they do not belong.
function node_names() {
    local self recipient
    self="$(local_binding)"
    [ -n "$self" ] ||
        die "no ~/.ssh/id_*.pub is a recipient in $recipients_file, so the machines" \
            "cannot be told apart from the workstation running this"
    for recipient in "${recipients[@]}"; do
        [ "$recipient" = "$self" ] || printf '%s\n' "$recipient"
    done
}
