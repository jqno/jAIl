#!/usr/bin/env bash
# Entrypoint: verify the sandbox, then run the given command (OpenCode).
set -uo pipefail

# krun doesn't apply no-new-privileges inside the VM, so set it here.
if ! grep -Eq '^NoNewPrivs:\s+1$' /proc/self/status; then
  exec setpriv --no-new-privs "$0" "$@"
fi

allowed_env=(
  HOME TERM COLORTERM LANG PATH
  http_proxy https_proxy no_proxy
  OPENCODE_DISABLE_AUTOUPDATE
  JAIL_PROFILE JAIL_HOST_KERNEL JAIL_GIT_DIR JAIL_MASKED
  HOSTNAME PWD SHLVL _ container
)
failed=0
check() { # description, command...
  if "${@:2}" >/dev/null 2>&1; then
    echo "  ✅ $1"
  else
    echo "  ❌ $1"
    failed=1
  fi
}

in_microvm() {
  [[ $(uname -r) != "${JAIL_HOST_KERNEL:-}" ]]
}

unprivileged() {
  if ! grep -Eq '^CapEff:\s+0+$' /proc/self/status; then return 1; fi
  grep -Eq '^NoNewPrivs:\s+1$' /proc/self/status
}

no_free_egress() {
  if curl -s --max-time 5 https://example.com; then return 1; fi
  if curl -s --max-time 5 --noproxy '*' https://1.1.1.1; then return 1; fi
  ! getent hosts example.com
}

git_readonly() {
  local probe="$JAIL_GIT_DIR/jail-probe"
  if touch "$probe"; then
    rm -f "$probe"
    return 1
  fi
}

masked_empty() {
  local f
  while read -r f; do
    if [[ -s $f ]]; then return 1; fi
  done <<<"${JAIL_MASKED:-}"
}

no_credentials() {
  local s
  if [[ -e $HOME/.ssh || -n ${SSH_AUTH_SOCK:-} ]]; then return 1; fi
  for s in /run/docker.sock /var/run/docker.sock /run/podman/podman.sock \
    /run/user/*/docker.sock /run/user/*/podman/podman.sock; do
    if [[ -e $s ]]; then return 1; fi
  done
}

# Files from the profile's home/ folder, e.g. OpenCode's config and .m2/settings.xml.
# Copied before the checks run, so they're checked too.
if [[ -d /jail/home ]]; then cp -rT /jail/home ~; fi

echo "jAIl ▸ booting profile ${JAIL_PROFILE:-?}"
check "running in a microVM" in_microvm
check "unprivileged" unprivileged
check "egress only through the allowlist" no_free_egress
if [[ -n ${JAIL_GIT_DIR:-} ]]; then check ".git read-only" git_readonly; fi
check "secrets masked" masked_empty
unexpected=$(compgen -e | grep -vxF -f <(printf '%s\n' "${allowed_env[@]}"))
check "environment clean" test -z "$unexpected"
if [[ -n $unexpected ]]; then echo "     unexpected: ${unexpected//$'\n'/ }"; fi
check "no credentials or sockets" no_credentials
if ((failed)); then
  echo "jAIl ▸ sandbox incomplete, not starting"
  exit 1
fi

exec "$@"
