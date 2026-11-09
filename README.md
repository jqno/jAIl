# jAIl

jAIl runs the [OpenCode](https://opencode.ai) coding agent in a sandbox: a rootless Podman container inside a small virtual machine (krun). It works on the project in your current directory. You keep working natively in the same folder, with your own editor, LSPs and tools, and see the agent's edits as they happen.

It's a few short scripts for Linux, not a product. Read them; they're meant to be understood.

## What it's for

Coding agents run shell commands. Most of the time that's fine, but sometimes an agent does something you didn't want, and sometimes a project contains text that tries to steer it. jAIl limits the damage:

- **Mistakes.** The agent can't `git push`, rewrite history or `git reset --hard`, and can't touch anything outside the project. It can edit the project itself; you review and commit.
- **Leaks.** The agent can only reach the hosts on an allowlist: your AI provider and package repositories. A prompt injection can't send your code or tokens to an arbitrary server.
- **Compliance.** Each *profile* (say, *work* and *hobby*) has its own allowlist. A work project can only reach the work provider, and a hobby project only the hobby provider, whatever OpenCode happens to be logged into.

It's not a guarantee. See [Threat coverage](#threat-coverage) for what it does and doesn't cover.

## Setup

You need Linux with KVM, Bash 4+, rootless Podman 4+ with the krun runtime, and git. (Using a Mac? See [macOS](#macos).)

1. Install the krun runtime. On Fedora:
   ```
   sudo dnf install crun-krun
   ```
2. Build the image. The agent and the proxies both use it.
   ```
   ./jail build
   ```
3. Put the launcher on your `PATH`:
   ```
   ln -s "$PWD/jail" ~/bin/
   ```
4. Create the configuration in `~/.config/jail/`. A minimal setup with two profiles:
   ```
   ~/.config/jail/
   ├── masks
   └── profiles/
       ├── work/
       │   ├── paths
       │   ├── allowlist
       │   └── home/.config/opencode/AGENTS.md
       └── hobby/
           ├── paths
           ├── allowlist
           └── home/.config/opencode/AGENTS.md
   ```
   For example:
   ```
   # masks
   .env
   .env.*

   # profiles/work/paths
   ~/work/*

   # profiles/work/allowlist
   api.githubcopilot.com
   *.githubcopilot.com
   artifactory.example.com
   repo1.maven.org
   models.dev
   models.opencode.ai

   # profiles/hobby/paths
   ~/src/*
   ~/projects/*

   # profiles/hobby/allowlist
   api.example-vendor.com
   repo1.maven.org
   models.dev
   models.opencode.ai
   ```
   And in each profile's `home/.config/opencode/AGENTS.md`:
   ```
   .git is read-only; the developer commits. Internet only reaches the AI providers
   and the package repositories; report what's missing instead of working around it.
   ```
   See [Configuration](#configuration) for every file.
5. Log in once per profile, from any project in that profile:
   ```
   cd ~/work/some-project && jail login
   cd ~/src/some-project && jail login
   ```

## Usage

Go to a project and start the agent:

```
cd ~/work/billing
jail
```

jAIl finds the profile for the project, starts that profile's proxy if needed, and boots the VM. A short boot sequence checks that the sandbox is intact. If any check fails, OpenCode doesn't start.

```
jAIl ▸ booting profile work
  ✅ running in a microVM
  ✅ unprivileged
  ✅ egress only through the allowlist
  ✅ .git read-only
  ✅ secrets masked
  ✅ environment clean
  ✅ no credentials or sockets
```

| Command | What it does |
|---|---|
| `jail` | Start OpenCode for the current project. |
| `jail -- <args>` | Same, passing `<args>` to OpenCode. |
| `jail shell` | Bash instead of OpenCode, with the same mounts. Skips the boot checks; run `boot.sh true` to see them. |
| `jail login` | Log in to a provider (`opencode auth login`) for the current project's profile. The login is shared by all projects in that profile. Runs with normal internet and no project mounted. |

The project is the git root, or the current directory outside git. Git worktrees work too, also when the main repository is somewhere else.

### Your workflow

- Let the agent edit. Its changes appear in your editor right away, owned by you.
- The agent can't commit. Review its work and commit natively:
  - `git status` and `git diff` for what changed;
  - `git status --ignored` for files that git ignores;
  - pay extra attention to build files and CI configuration, because those run code on your machine.
- Switch models any time with `/models` in OpenCode.

## Configuration

Everything lives in `~/.config/jail/`, outside your projects, where the agent can't change it.

| File | Contents |
|---|---|
| `masks` | File names to hide in every project, one per line, globs allowed (`.env`, `.env.*`). The agent sees these files as empty and can't change them. `.git` and `node_modules` aren't searched. |
| `profiles/<name>/paths` | Project paths for this profile, one glob per line. Each glob must match the project's complete path, which is the git toplevel (or the current folder outside git). So `~/work` matches only the folder `~/work` itself. For everything under it, write `~/work/*`: here `*` also matches `/`, so this covers projects at any depth. Leave out the `/` (`~/work*`) and it would also match `~/workshop`. Each project must match exactly one profile, or jAIl refuses to start. There's no default, so a work project in an unexpected place can't end up in the wrong profile. |
| `profiles/<name>/allowlist` | Hosts this profile can reach, one per line. `*` is allowed (`*.githubcopilot.com`). Applies to HTTPS and plain HTTP. |
| `profiles/<name>/home/` | Optional. Copied into the agent's home folder at every start, so changes the agent makes there don't last. |
| `profiles/<name>/mounts` | Optional. Folders or files outside the project that the agent may read, one per line (`~/ai-config`). Mounted read-only at the same path, so symlinks into them work, such as an `AGENTS.md` kept outside the project. The agent sees everything in them, and masks don't apply. |

All files allow `#` comments and blank lines; `~` expands to your home folder.

### Allowlists and compliance

Put a provider's API host only in the allowlists of profiles whose code may go to that provider. That's what keeps work code away from the hobby provider and the other way round.

Never allow GitHub (except what Copilot needs), npm, PyPI or paste sites: those are easy places to send data to.

To add a host, edit the allowlist and restart the profile's proxy:
```
podman restart jail-work-proxy
```
To find out which host is missing, watch the proxy's log while you reproduce the problem:
```
podman logs -f jail-work-proxy
```

### OpenCode settings

Each profile has one home volume, `jail-<profile>-home`, shared by all its projects. It holds OpenCode's login, sessions and caches, and survives rebuilding the image.

Put OpenCode's settings in the profile's `home/.config/opencode/`:
- `opencode.json`: permissions and other settings. Leave out `model`, so OpenCode resumes the model you last picked.
- `AGENTS.md`: instructions for the agent.

### Credentials for package repositories

A file like `~/.m2/settings.xml` goes in the profile's `home/`, as `home/.m2/settings.xml`. Keep in mind:
- It's a copy. Update it when the credentials change.
- Use a read-only token if you can. Otherwise a prompt injection could publish artifacts to your repository.
- Maven doesn't use `https_proxy`. Add a `<proxy>` for `jail-proxy`, port `8888`, to that copy.

Don't share the host's `~/.m2/repository` (or similar caches) with the agent. It could plant an artifact that your native builds then run. The profile's home volume keeps its own cache, so downloads happen only once per profile.

### Compilers and build tools

The image contains OpenCode, git and a few basic tools, but no compilers or build tools. Add what the agent needs to `image/Containerfile` and run `jail build`. Run it now and then anyway, to get updates.

JVM tools don't use `https_proxy` either. Add this to the Containerfile, and add `JAVA_TOOL_OPTIONS` to `allowed_env` in `image/boot.sh`:
```
ENV JAVA_TOOL_OPTIONS="-Dhttps.proxyHost=jail-proxy -Dhttps.proxyPort=8888"
```

## How it works

- **The VM.** Each session runs in a rootless Podman container with the krun runtime, so it gets its own small virtual machine and kernel. It runs as your user, without capabilities or setuid programs.
- **The network.** The container sits on an internal network with no route to the internet and no outside DNS. The only way out is the profile's proxy (tinyproxy), which only lets connections through to the hosts in the profile's allowlist.
- **The mounts.**

  | What | How |
  |---|---|
  | The project | Read-write, at the same path as on your host |
  | `.git` | Read-only; in a worktree, the main repository's `.git` too |
  | The profile's `mounts` | Read-only, at the same path as on your host |
  | Masked files | Replaced by an empty, read-only file |
  | Your home folder | Not mounted: the profile's home volume takes its place |
  | SSH keys, git config, tokens, the Podman socket | Never |

- **The environment.** No variables come from your host, except `TERM`, `COLORTERM` and `LANG`.
- **The boot checks.** Before OpenCode starts, `image/boot.sh` verifies the items above from the inside.

## Threat coverage

An agent becomes dangerous when it combines private data, untrusted content and a way to communicate externally (Simon Willison's "lethal trifecta"). A coding agent always has the first two. jAIl limits the third, keeps credentials out of reach, and restricts what can break. Categories follow the OWASP Top 10 for LLM Applications (2025).

| Threat | Status | How, or why not |
|---|---|---|
| Destructive git actions (LLM06 Excessive Agency) | ✅ | No git credentials; `.git` read-only |
| Lost uncommitted work | ❌ | The project is writable. Commit often |
| Changes outside the project | ✅ | Everything else is read-only or absent |
| Credential theft (LLM02) | ✅ | No SSH keys, tokens or host environment in the container |
| Secrets in project files | 🟡 | Files on the `masks` list are hidden; others, and git history, aren't |
| Provider token in the home volume | 🟡 | Readable, but only reaches the profile's allowlisted hosts |
| Prompt injection sends data out (LLM01) | ✅ | Only allowlisted hosts; no outside DNS |
| …through an allowlisted host with an attacker's key | ❌ | The proxy checks hostnames, not accounts |
| …through domain fronting (claim an allowlisted host, then talk to another site on the same CDN) | 🟡 | Most CDNs block it; the proxy can't see inside encrypted traffic |
| Hooks or config planted in `.git` | ✅ | `.git` is read-only |
| Other planted files (ignored files, nested `.git`, build or CI files) | ❌ | Only your review catches these |
| Malicious dependency (LLM03) | 🟡 | Downloaded only in the VM, but it runs on your host once you build |
| Sandbox escape | 🟡 | microVM, rootless, no capabilities, no setuid, no Podman socket |
| Terminal escape sequences | 🟡 | Safe with the kitty settings below |
| Contamination between projects | 🟡 | Separate home per profile; projects within a profile share one |
| Work code to the hobby provider, or the other way round | ✅ | Profile by path; each profile's proxy only reaches its own provider; `.env` masked |
| Runaway cost (LLM10) | ❌ | Set a spend limit at the provider |
| Agent-written code running on the host | ❌ | Out of scope: review before you build |

## Recommendations

- **kitty:** set `allow_remote_control no`, and leave `read-clipboard` out of `clipboard_control`, so the agent's output can't control your terminal or read your clipboard.
- **Metals:** turn off `autoImportBuild`. Otherwise a build file the agent edited gets imported, and run, on your host without you looking at it first.
- **Testcontainers:** run those tests natively. Never give the agent the Podman socket; that would let it escape the sandbox.
- **Cost:** set a spend limit with your provider.

## Maintenance

| Task | Command |
|---|---|
| Update OpenCode | `podman build --pull --no-cache -t jail image/` |
| Reload an allowlist | `podman restart jail-<profile>-proxy` |
| Apply a changed `tinyproxy.conf` | Rebuild the image, then `podman rm -f jail-<profile>-proxy` for each profile; jail recreates it on the next start |
| List jail's volumes | `podman volume ls --filter name=jail-` |
| Reset a profile (removes its login, sessions and caches) | `podman volume rm jail-<profile>-home` |

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| "must match exactly one profile" | The project matches no profile, or several. Check the `paths` files. |
| A download or API call fails | The host isn't on the allowlist. Find it with `podman logs -f jail-<profile>-proxy`, add it, and restart the proxy. |
| A boot check fails | Something in the setup changed. Run `jail shell`, then `boot.sh true`, to investigate. |

## macOS

jAIl probably doesn't work on macOS. It hasn't been tried, but:
- On macOS, Podman already runs its containers in a Linux VM (`podman machine`). The krun runtime would have to start a second VM inside that one, which needs nested virtualization. Apple Silicon only offers that on M3 or newer with macOS 15+, and Podman's VM doesn't turn it on.
- The project folder reaches the containers through Podman's VM, over a shared filesystem. That changes how file ownership and the same-path mounts behave.
- macOS ships Bash 3.2, and the launcher needs Bash 4+.
