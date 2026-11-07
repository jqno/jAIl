# Spec: jAIl, a minimal sandbox for OpenCode on Fedora
## 1. Goal
A handful of small scripts that start OpenCode in a rootless Podman container, running in a microVM (krun), for the project in the current directory. The developer keeps working natively, with their own editor, LSPs and toolchain, **in the same folder**, and sees the agent's edits live.

**Simplicity is a requirement.** Prefer a short script plus documentation over automation. Anything not in this spec doesn't get built. When in doubt, choose less. The launcher contains no tool-specific code beyond the `opencode` command itself; tools are added in the Containerfile.

## 2. Threat model
In order of priority:
1. **Accidental tool use by the LLM (primary).** Examples: `git push`, `git reset --hard`, rewriting history, touching credentials or things outside the project.
2. **Compliance.** Work code may only go to GitHub Copilot, and hobby code never to Copilot. The developer isn't the threat; the goal is to rule out mistakes. Enforced by the network: each profile's container can only reach the hosts in that profile's allowlist.
3. **Prompt injection from unknown projects (secondary).** Basic measures: an egress allowlist, no host credentials, a VM.

Section 10 has the full overview of what is and isn't covered. The README includes it.

## 3. Deliverables
```
jail/
├── jail                  launcher (bash, ≈ 80 lines)
├── image/
│   ├── Containerfile
│   ├── boot.sh           entrypoint: a few checks, then exec opencode
│   └── tinyproxy.conf    the per-profile proxies run tinyproxy from the same image
└── README.md             setup, workflow, host configuration, threat coverage
```
User configuration, outside the repo and outside every project:
```
~/.config/jail/
├── masks                 file names to mask (see 6.2)
└── profiles/<name>/
    ├── paths             path patterns for this profile, one per line
    ├── allowlist         hosts this profile's proxy allows, one per line
    ├── home/             optional: files copied into the home at every start (e.g. .m2/settings.xml)
    └── mounts            optional: paths outside the project to mount read-only, one per line
```

## 4. Profiles
- Each profile has a `paths` file with one or more path globs, for example `~/work/*` for work and `~/src/*`, `~/projects/*` for hobby.
- **Exactly one profile must match** the project path. If none or more than one matches, the project doesn't start, with a message naming the paths involved. There's no default, so a work project in an unexpected place can't end up in the hobby profile by accident.
- **Compliance comes from the allowlists.** Each profile has its own proxy and internal network. A provider's API host goes only in the allowlists of profiles whose code may go to that provider. Then a wrong login is harmless: the provider is unreachable.
- Each profile has one home volume, `jail-<profile>-home`, shared by its projects. It holds OpenCode's login, sessions, config and caches (e.g. `~/.m2/repository`). It survives image rebuilds.
- `.env` files are masked (see 6.2): OpenCode reads API keys from a project's `.env` too.
- The launcher prints the profile name at the start, and sets it in the terminal title.
- Any number of profiles is supported; profiles are a network and compliance boundary, not a toolchain setting.

## 5. Image and login
- `Containerfile`: Fedora (same version as the host), OpenCode (`npm i -g opencode-ai`), Node.js, git, ripgrep, fd, curl, util-linux (for `setpriv`), tinyproxy. Setuid/setgid bits are stripped. Compilers, build tools and LSPs are added here by the developer; JVM tools need `JAVA_TOOL_OPTIONS` with the proxy (see README).
- `ENV OPENCODE_DISABLE_AUTOUPDATE=1`. Updating means rebuilding the image.
- No built-in instructions or OpenCode config: they go in the profile's `home/.config/opencode/` (`AGENTS.md`, and `opencode.json` without `model`, so `/models` choices persist). Reset at every start.
- **Login:** `jail login` runs `opencode auth login` for the current project's profile in a container from the same image: no project, normal internet, the profile's home volume. Works for Copilot's device flow, OAuth and API keys.

## 6. Launcher: `jail`
Runs from the project directory and does:
1. **Determine the project:** the git toplevel (for a worktree: the worktree itself), or else the current directory. Determine the profile via the `paths` files; if not exactly one matches, stop.
2. **Make sure the profile's proxy is running:** network `jail-<profile>` (`--internal`), network `jail-out` (normal, with DNS, shared), and container `jail-<profile>-proxy` on both, with alias `jail-proxy` on the internal one. Created if missing, then started.
3. **`podman run`:**
   - `--rm -it --runtime krun --annotation krun.cpus=4 --annotation krun.ram_mib=8192`
   - `--userns=keep-id --cap-drop ALL --security-opt no-new-privileges`
   - `--network jail-<profile>`, with `http_proxy`/`https_proxy` set to `http://jail-proxy:8888` and `no_proxy=localhost,127.0.0.1` (lowercase only; curl and OpenCode honour them)
   - `HOME` is **the same path as on the host**, backed by the profile's home volume
   - **Mounts, at the same absolute path as on the host:**

| What | How |
|---|---|
| project | read-write, `:z` |
| git common dir (`git rev-parse --git-common-dir`) | read-only (git projects only) |
| `.git` file in a worktree | read-only, if it is a file |
| entries in the profile's `mounts` | read-only, at their own absolute path, so symlinks into them resolve; the launcher stops if one doesn't exist |
| masked files (6.2) | `/dev/null`, read-only |
| profile's `home/` folder | read-only at `/jail/home`; `boot.sh` copies it into `~` before the checks |

   - **No host environment variables.** The launcher sets every variable explicitly with `-e` and passes `--env-host=false --http-proxy=false`. From the host, only the values of `TERM`, `COLORTERM` and `LANG` go in.
   - Never mount: the Podman/Docker socket, `SSH_AUTH_SOCK`, `~/.ssh`, `~/.gitconfig`, the host's `~/.m2/repository` or other host caches (the agent could poison them for native builds).
4. Arguments after `--` go to OpenCode.

Subcommands: only `jail login` and `jail shell` (bash instead of OpenCode, same mounts, no boot checks). Everything else is done with plain `podman` commands, described in the README.

### 6.1 Git worktrees
Running jAIl in a worktree must work, also when the main repo lives somewhere else entirely:
- Only the worktree is mounted read-write; the main repo's working tree is not mounted.
- The git common dir is mounted read-only at its own absolute path, so the `gitdir:` reference resolves.
- The worktree's `.git` file is mounted read-only.
- Result: `git log/diff/status` work, commits fail. Worktrees are managed on the host.

### 6.2 Masking secrets
- `~/.config/jail/masks` lists file names to hide in every project, one per line, globs allowed (`.env`, `.env.*`). No exceptions, no project-specific paths.
- At start, the launcher finds matching files in the project with a single `find` (skipping `.git` and `node_modules`) and mounts `/dev/null` read-only over each. It prints which files were masked.
- Not covered: files not on the list, files that appear after the start, secrets in git history.

## 7. Proxy
**Purpose:** the only way out of the container, and the compliance boundary between profiles.
- One tinyproxy container per profile, `jail-<profile>-proxy`, running from the jail image (`--entrypoint tinyproxy`), on the profile's internal network and on `jail-out`. (The default `podman` network has no DNS, so the proxy couldn't resolve hosts there.) Sharing the image is safe: containers don't share writable state, and the agent can't change or rebuild images.
- It allows HTTPS `CONNECT` (port 443 only) and plain HTTP only for hostnames in the profile's `allowlist` (`FilterType fnmatch`, `FilterDefaultDeny Yes`), and doesn't look inside the traffic. To reload, restart the container.
- Initial lists: Maven Central and the Scala repositories, `models.dev`, `models.opencode.ai`, plus the Copilot hosts and the work Artifactory for work, or the hobby vendor's API for hobby. Never GitHub (except what Copilot needs), npm, PyPI or paste sites.

## 8. Boot script (`boot.sh`)
First re-execs itself under `setpriv --no-new-privs`, because krun doesn't apply `no-new-privileges` inside the VM. Then one line per check, with ✅ or ❌, with the profile name in the header. On any ❌, OpenCode doesn't start.

| Check | How |
|---|---|
| Running in a microVM | kernel differs from the host's (passed in as `JAIL_HOST_KERNEL`) |
| Unprivileged | `CapEff` is 0 and `NoNewPrivs` is 1 |
| Egress only through the allowlist | `example.com` through the proxy fails, `curl --noproxy '*' https://1.1.1.1` fails, `getent hosts example.com` fails |
| `.git` read-only | writing in the git common dir fails (git projects only) |
| Secrets masked | every masked file is empty (list passed in by the launcher) |
| Environment clean | every variable name is on a fixed list in `boot.sh`; on ❌, print the unexpected names, never their values |
| No credentials or sockets | `~/.ssh` doesn't exist, `SSH_AUTH_SOCK` unset, no `docker.sock`/`podman.sock` |

## 9. README
**Style: very concise.** Short sentences, tables and lists. Contents: setup, threat coverage (section 10), why the proxy, host settings (kitty, Metals `autoImportBuild` off), workflow (review with `git status`, `--ignored`, `git diff`; commit natively), don'ts (never mount the Podman socket), cost (spend limit), maintenance (`podman` commands for volumes, rebuilding, restarting proxies).

## 10. Threat coverage (for the README)
An agent becomes dangerous when it combines private data, untrusted content and a way to communicate externally (Simon Willison's "lethal trifecta"). A coding agent always has the first two. jAIl limits the third, keeps credentials out of reach, and restricts what can break. Categories follow the OWASP Top 10 for LLM Applications (2025).

| Threat | Status | How, or why not |
|---|---|---|
| Destructive git actions (LLM06 Excessive Agency) | ✅ | No git credentials; `.git` read-only |
| Lost uncommitted work | ❌ | Project is writable. Commit often |
| Changes outside the project | ✅ | Everything else read-only or absent |
| Credential theft (LLM02) | ✅ | No SSH, tokens or host environment in the container |
| Secrets in project files | 🟡 | Files on the `masks` list are hidden; others and git history aren't |
| Provider token in the home volume | 🟡 | Readable, but only reaches the profile's allowlisted hosts |
| Prompt injection sends data out (LLM01) | ✅ | Only allowlisted hosts; no external DNS |
| …through an allowlisted host with an attacker's key | ❌ | The proxy checks hostnames, not accounts |
| …through domain fronting | 🟡 | Most CDNs block it; the proxy can't see inside encrypted traffic |
| Hooks or config planted in `.git` | ✅ | `.git` read-only |
| Other planted files (ignored files, nested `.git`, build/CI files) | ❌ | Your review only |
| Malicious dependency (LLM03) | 🟡 | Downloaded only in the VM; runs on the host once you build |
| Sandbox escape | 🟡 | microVM, rootless, no capabilities, no setuid, no Podman socket |
| Terminal escape sequences | 🟡 | Safe with the kitty settings |
| Contamination between projects | 🟡 | Separate home per profile; projects within a profile share one |
| Work code to the hobby vendor, or the reverse | ✅ | Profile by path; each profile's proxy only reaches its own provider; `.env` masked |
| Runaway cost (LLM10) | ❌ | Spend limit at the provider |
| Agent-written code running on the host | ❌ | Out of scope: review before you build |

## 11. Acceptance criteria
1. In the container, `git commit`, `git push` and `git reset --hard` fail. On the host, the repository is unchanged.
2. Edits by the agent appear immediately in the native editor, owned by the developer.
3. A project that matches no profile, or more than one, doesn't start.
4. `curl https://github.com` fails in the container. A work container can't reach the hobby vendor's API, and a hobby container can't reach Copilot.
5. With `export GITHUB_TOKEN=x FOO=y` on the host, neither variable is visible in the container.
6. A `.env` in the project is empty in the container and can't be changed; on the host it's untouched.
7. Each boot check fails demonstrably when its protection is removed.
8. Works in a plain repo, a project without git, and a git worktree whose main repo is outside the worktree's directory.
9. ShellCheck reports no warnings.

## 12. Still to verify
- Which hosts Copilot needs at runtime (watch `podman logs jail-work-proxy`), in particular whether it needs `api.github.com`; and whether the proxy reaches the work Artifactory over VPN.
- Whether OpenCode resumes the last `/models` choice when `opencode.json` has no `model` (expected, untested).
- Whether OpenCode writes the Copilot login at runtime (token refresh); it can, since the home volume is writable.
- Whether Maven needs a `<proxy>` entry in the container's `settings.xml` (likely), once Maven is in the image.

## 13. Deliberately left out
Explicit project binding and remote checks; `jail check`; read-only `.jvmopts` and similar files; submodule handling; per-profile env files and tool choice; JVM or other toolchain support in the launcher; sharing host caches like `~/.m2/repository`; Claude Code and Copilot CLI; a TLS-intercepting proxy; microsandbox (for now).
