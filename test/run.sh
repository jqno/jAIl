#!/usr/bin/env bash
# jAIl end-to-end tests. Needs the image (`just build`), krun and network access.
# Runs against a throwaway config with profiles t-hobby and t-work, so your own config,
# proxies and home volumes are left alone.
# shellcheck disable=SC2016 # single-quoted code is for jail or the sandbox to expand
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
jail=$tmp/jail
passed=0
failed=0

if [[ -t 1 ]]; then
  bold=$'\e[1m' dim=$'\e[2m' green=$'\e[32m' red=$'\e[31m' reset=$'\e[0m'
else
  bold='' dim='' green='' red='' reset=''
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

section() {
  echo
  echo "${bold}$1${reset}"
}

# Pass if the command succeeds; on failure, show the output being checked.
check() { # description, command...
  if "${@:2}"; then
    echo "  ${green}✓${reset} $1"
    passed=$((passed + 1))
  else
    echo "  ${red}✗ $1${reset}"
    sed "s/^/      ${dim}/; s/\$/${reset}/" <<<"$out"
    failed=$((failed + 1))
  fi
}

# Assertions on $out and $status, the result of the last run.
has() { grep -qF -- "$1" <<<"$out"; }
lacks() { ! has "$1"; }
matches() { grep -qE -- "$1" <<<"$out"; }
exited() { [[ $status == "$1" ]]; }
booted() {
  if ! has "✅"; then return 1; fi
  lacks "❌"
}

# Drop podman's TTY warning and the terminal title escape from output.
tidy() { sed -e $'s/\e]2;[^\a]*\a//' -e '/not a TTY/d'; }

# Run the test copy of jail from a fixture folder.
jail_in() { # folder, jail arguments...
  out=$(cd "$tmp/$1" && timeout -k 10 170 "$jail" "${@:2}" </dev/null 2>&1)
  status=$?
  out=$(tidy <<<"$out")
}

# Run a bash command in the sandbox from a fixture folder, after the boot checks.
sandbox() { # folder, command
  jail_in "$1" shell -c 'exec boot.sh bash -c "$1"' - "$2"
}

# Run boot.sh in a hand-made container on the hobby network, to break one protection at a time.
boot_with() { # podman run options...
  out=$(timeout -k 10 170 podman run --rm --runtime krun --userns=keep-id --env-host=false --http-proxy=false \
    --network jail-t-hobby -e HOME=/tmp -e https_proxy=http://jail-proxy:8888 -e JAIL_HOST_KERNEL=none \
    "$@" jail true 2>&1)
  status=$?
}

# Replace a piece of text in the test copy of jail; stop if it isn't there.
patch_jail() { # text, replacement
  local src
  src=$(<"$jail")
  if [[ $src != *"$1"* ]]; then
    echo "${red}Can't patch jail, text not found: $1${reset}"
    exit 1
  fi
  printf '%s\n' "${src/"$1"/"$2"}" >"$jail"
}

repo() { # folder: a git repo with one commit
  git init -q "$1"
  touch "$1/README"
  git -C "$1" add .
  git -C "$1" -c user.name=test -c user.email=test@example.com commit -qm init
}

remove_test_profiles() {
  podman rm -f jail-t-hobby-proxy jail-t-work-proxy >/dev/null 2>&1
  podman network rm jail-t-hobby jail-t-work >/dev/null 2>&1
  podman volume rm jail-t-hobby-home jail-t-work-home >/dev/null 2>&1
}

cleanup() {
  remove_test_profiles
  rm -rf "$tmp"
}

# ─── Setup ───────────────────────────────────────────────────────────────────

if ! podman image exists jail; then
  echo "${red}No jail image; run \`just build\` first.${reset}"
  exit 1
fi
trap cleanup EXIT
remove_test_profiles # leftovers from an interrupted run

# Config
mkdir -p "$tmp/conf/profiles/t-hobby" "$tmp/conf/profiles/t-work"
printf '%s\n' .env '.env.*' >"$tmp/conf/masks"
echo "$tmp/hobby/*" >"$tmp/conf/profiles/t-hobby/paths"
echo "$tmp/work/*" >"$tmp/conf/profiles/t-work/paths"
printf '%s\n' models.dev models.opencode.ai repo1.maven.org api.greenpt.ai >"$tmp/conf/profiles/t-hobby/allowlist"
printf '%s\n' models.dev models.opencode.ai api.githubcopilot.com >"$tmp/conf/profiles/t-work/allowlist"

# Projects
repo "$tmp/hobby/plain"
echo SECRET=1 >"$tmp/hobby/plain/.env"
mkdir -p "$tmp/hobby/plain/deep" "$tmp/hobby/nogit" "$tmp/rwgit"
repo "$tmp/work/proj"
mkdir "$tmp/work/proj/sub"
repo "$tmp/elsewhere/main"
git -C "$tmp/elsewhere/main" worktree add -q "$tmp/hobby/wt" -b fix

# Test copy of jail: own config, `shell` passes its arguments to bash, login skips the provider menu.
cp "$root/jail" "$jail"
patch_jail 'conf="$HOME/.config/jail"' "conf=\"$tmp/conf\""
patch_jail 'shell) run --entrypoint bash jail ;;' 'shell) run --entrypoint bash jail "${@:2}" ;;'
patch_jail '--entrypoint opencode jail auth login' '--entrypoint opencode jail auth login -p greenpt'
chmod +x "$jail"

# The host environment must not leak into the sandbox.
export GITHUB_TOKEN=leak FOO=leak

# ─── Tests ───────────────────────────────────────────────────────────────────

section "Profile selection"
jail_in .
check "refuses a project outside every profile" exited 1
check "says why" has "must match exactly one profile; matches: none"

echo "$tmp/hobby/*" >>"$tmp/conf/profiles/t-work/paths"
jail_in hobby/plain
check "refuses a project in two profiles" exited 1
check "names both" has "matches: t-hobby"
echo "$tmp/work/*" >"$tmp/conf/profiles/t-work/paths"

jail_in . login
check "refuses login outside every profile" exited 1

egress='for h in api.greenpt.ai api.githubcopilot.com; do curl -s -o /dev/null -w "%{http_code} $h\n" "https://$h/"; done'

section "New profile"
new_in() { # fake home, jail arguments...
  out=$(HOME=$1 "$jail" new "${@:2}" 2>&1)
  status=$?
}
mkdir -p "$tmp/bare-home" "$tmp/oc-home/.config/opencode"
echo hi >"$tmp/oc-home/.config/opencode/AGENTS.md"
mv "$tmp/conf/masks" "$tmp/masks"
new_in "$tmp/bare-home" t-new
check "works without ~/.config/opencode" exited 0
check "...with an allowlist" grep -qx models.dev "$tmp/conf/profiles/t-new/allowlist"
check "...and paths that match no projects yet" test -z "$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$tmp/conf/profiles/t-new/paths")"
check "...and an empty OpenCode config" test -z "$(ls -A "$tmp/conf/profiles/t-new/home/.config/opencode")"
check "...and default masks" grep -qx '.env.*' "$tmp/conf/masks"
check "...and points to the README" has "README"
echo custom >"$tmp/conf/masks"
new_in "$tmp/oc-home" t-new2
check "doesn't copy the host's OpenCode config" test -z "$(ls -A "$tmp/conf/profiles/t-new2/home/.config/opencode")"
check "keeps existing masks" grep -qx custom "$tmp/conf/masks"
new_in "$tmp/bare-home" t-new
check "refuses an existing profile" has "already exists"
new_in "$tmp/bare-home" ../x
check "refuses a bad name" exited 1
mv "$tmp/masks" "$tmp/conf/masks"
rm -rf "$tmp/conf/profiles/t-new" "$tmp/conf/profiles/t-new2"

section "Hobby project"
sandbox hobby/plain "$egress; pwd; cat .env"
check "boot checks pass" booted
check "checks .git" has "✅ .git read-only"
check "reaches its own vendor" matches '^[1-5][0-9]{2} api.greenpt.ai'
check "doesn't reach the other vendor" has "000 api.githubcopilot.com"
check "masks .env" has "jAIl: masked $tmp/hobby/plain/.env"
check ".env is empty inside" lacks "SECRET"
check ".env is unchanged on the host" grep -qx SECRET=1 "$tmp/hobby/plain/.env"

section "Work project, from a subfolder"
sandbox work/proj/sub "$egress; pwd; git --no-pager log --oneline --no-color; touch ../.git/x"
check "boot checks pass" booted
check "uses the work profile" has "booting profile t-work"
check "reaches its own vendor" matches '^[1-5][0-9]{2} api.githubcopilot.com'
check "doesn't reach the other vendor" has "000 api.greenpt.ai"
check "starts in the subfolder" has "$tmp/work/proj/sub"
check "git works" has "init"
check ".git is read-only" has "Read-only file system"

section "Starting OpenCode"
jail_in hobby/plain -- --version
check "boot checks pass, with GITHUB_TOKEN and FOO set on the host" booted
check "runs opencode with arguments after --" matches '^[0-9]+\.[0-9]+\.[0-9]+'
jail_in hobby/plain --version
check "runs opencode with arguments without --" matches '^[0-9]+\.[0-9]+\.[0-9]+'

section "Other project layouts"
sandbox hobby/nogit pwd
check "project without git boots" booted
check "...and skips the .git check" lacks ".git read-only"
sandbox hobby/wt "git --no-pager log --oneline --no-color; git -c user.name=x -c user.email=x commit --allow-empty -qm x"
check "worktree with its main repo elsewhere boots" booted
check "...git works" has "init"
check "...the main repo's .git is read-only" has "Read-only file system"

section "Boot checks catch a broken sandbox"
boot_with -e FOO=1 -e BAR=2 -v "$tmp/hobby/plain/.env:/s:ro,z" -e JAIL_MASKED=/s
check "unmasked secret" has "❌ secrets masked"
check "extra environment variables" has "unexpected: BAR FOO"
check "doesn't start" has "not starting"
boot_with -v "$tmp/rwgit:/g:z" -e JAIL_GIT_DIR=/g
check "writable .git" has "❌ .git read-only"
check "...and cleans up its probe" test -z "$(ls -A "$tmp/rwgit")"

section "Login, with a fake key"
out=$(cd "$tmp/hobby/plain/deep" && (sleep 15; printf 'k\r'; sleep 10) |
  timeout -k 10 90 script -qc "$jail login" /dev/null 2>&1 | tr -d '\033')
check "logs in for the project's profile" has "logging in for profile t-hobby"
check "finishes" has "Done"
sandbox hobby/plain "opencode auth list"
check "hobby profile has the login" has "1 credentials"
sandbox work/proj "opencode auth list"
check "work profile doesn't" has "0 credentials"

section "Proxy"
out=$(podman run --rm --network jail-t-hobby --entrypoint curl jail -s -o /dev/null -w '%{http_code}\n' \
  -x http://jail-proxy:8888 http://repo1.maven.org/maven2/ http://example.com/ 2>&1)
check "passes plain HTTP to an allowed host" matches '^301$'
check "refuses plain HTTP to other hosts" matches '^403$'

# ─── Summary ─────────────────────────────────────────────────────────────────

echo
if ((failed > 0)); then
  echo "${red}${bold}$failed failed${reset}, $passed passed"
  exit 1
fi
echo "${green}${bold}All $passed passed${reset}"
