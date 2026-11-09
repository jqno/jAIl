#!/usr/bin/env python3
# jAIl end-to-end tests. Needs the image (`just build`), krun and network access.
# Runs against a throwaway config with profiles t-hobby and t-work, so your own config,
# proxies and home volumes are left alone.
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
TMP = tempfile.mkdtemp()
JAIL = f"{TMP}/jail"
EGRESS = 'for h in api.greenpt.ai api.githubcopilot.com; do curl -s -o /dev/null -w "%{http_code} $h\\n" "https://$h/"; done'


def style(code):
    if sys.stdout.isatty():
        return f"\033[{code}m"
    return ""


BOLD, DIM, GREEN, RED, RESET = style(1), style(2), style(32), style(31), style(0)
counts = {"passed": 0, "failed": 0}

# ─── Helpers ─────────────────────────────────────────────────────────────────


class Result:
    """The output and exit status of a command, with assertions on them."""

    def __init__(self, out, status):
        self.out = out
        self.status = status

    def has(self, text):
        return text in self.out

    def lacks(self, text):
        return not self.has(text)

    def matches(self, pattern):
        return re.search(pattern, self.out, re.MULTILINE) is not None

    def exited(self, status):
        return self.status == status

    def booted(self):
        return self.has("✅") and self.lacks("❌")


def section(title):
    print()
    print(f"{BOLD}{title}{RESET}")


def check(description, ok, result):
    """Pass if ok; on failure, show the output being checked."""
    if ok:
        print(f"  {GREEN}✓{RESET} {description}")
        counts["passed"] += 1
    else:
        print(f"  {RED}✗ {description}{RESET}")
        for line in result.out.split("\n"):
            print(f"      {DIM}{line}{RESET}")
        counts["failed"] += 1


def sh(*args, **kwargs):
    """Run a command, with stdout and stderr together."""
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       encoding="utf-8", errors="replace", **kwargs)
    return Result(p.stdout.rstrip("\n"), p.returncode)


def quiet(*args):
    subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def tidy(out):
    """Drop podman's TTY warning and the terminal title escape from output."""
    out = re.sub(r"\033\]2;[^\a]*\a", "", out)
    return "\n".join(line for line in out.split("\n") if "not a TTY" not in line)


def jail_in(folder, *args):
    """Run the test copy of jail from a fixture folder."""
    r = sh("timeout", "-k", "10", "170", JAIL, *args, cwd=f"{TMP}/{folder}", stdin=subprocess.DEVNULL)
    return Result(tidy(r.out), r.status)


def sandbox(folder, command):
    """Run a bash command in the sandbox from a fixture folder, after the boot checks."""
    return jail_in(folder, "shell", "-c", 'exec boot.sh bash -c "$1"', "-", command)


def boot_with(*options):
    """Run boot.sh in a hand-made container on the hobby network, to break one protection at a time."""
    return sh("timeout", "-k", "10", "170", "podman", "run", "--rm", "--runtime", "krun", "--userns=keep-id",
              "--env-host=false", "--http-proxy=false", "--network", "jail-t-hobby", "-e", "HOME=/tmp",
              "-e", "https_proxy=http://jail-proxy:8888", "-e", "JAIL_HOST_KERNEL=none", *options, "jail", "true")


def new_in(home, *args):
    """Run jail new with a fake home."""
    return sh(JAIL, "new", *args, env={**os.environ, "HOME": home})


def patch_jail(text, replacement):
    """Replace a piece of text in the test copy of jail; stop if it isn't there."""
    with open(JAIL) as f:
        src = f.read()
    if text not in src:
        print(f"{RED}Can't patch jail, text not found: {text}{RESET}")
        sys.exit(1)
    with open(JAIL, "w") as f:
        f.write(src.replace(text, replacement, 1))


def write(path, *lines, mode="w"):
    with open(path, mode) as f:
        f.writelines(f"{line}\n" for line in lines)


def has_line(path, line):
    with open(path) as f:
        return line in f.read().splitlines()


def no_entries(path):
    with open(path) as f:
        return all(not re.sub(r"#.*", "", line).strip() for line in f)


def empty_dir(path):
    return not os.listdir(path)


def repo(folder):
    """A git repo with one commit."""
    subprocess.run(["git", "init", "-q", folder], check=True)
    write(f"{folder}/README")
    subprocess.run(["git", "-C", folder, "add", "."], check=True)
    subprocess.run(["git", "-C", folder, "-c", "user.name=test", "-c", "user.email=test@example.com",
                    "commit", "-qm", "init"], check=True)


def remove_test_profiles():
    quiet("podman", "rm", "-f", "jail-t-hobby-proxy", "jail-t-work-proxy")
    quiet("podman", "network", "rm", "jail-t-hobby", "jail-t-work")
    quiet("podman", "volume", "rm", "jail-t-hobby-home", "jail-t-work-home")


# ─── Setup ───────────────────────────────────────────────────────────────────


def setup():
    remove_test_profiles()  # leftovers from an interrupted run

    # Config
    os.makedirs(f"{TMP}/conf/profiles/t-hobby")
    os.makedirs(f"{TMP}/conf/profiles/t-work")
    write(f"{TMP}/conf/masks", ".env", ".env.*")
    write(f"{TMP}/conf/profiles/t-hobby/paths", f"{TMP}/hobby/*")
    write(f"{TMP}/conf/profiles/t-work/paths", f"{TMP}/work/*")
    write(f"{TMP}/conf/profiles/t-hobby/allowlist", "models.dev", "models.opencode.ai", "repo1.maven.org", "api.greenpt.ai")
    write(f"{TMP}/conf/profiles/t-work/allowlist", "models.dev", "models.opencode.ai", "api.githubcopilot.com")

    # Projects
    repo(f"{TMP}/hobby/plain")
    write(f"{TMP}/hobby/plain/.env", "SECRET=1")
    os.makedirs(f"{TMP}/hobby/plain/deep")
    os.makedirs(f"{TMP}/hobby/nogit")
    os.makedirs(f"{TMP}/rwgit")
    repo(f"{TMP}/work/proj")
    os.makedirs(f"{TMP}/work/proj/sub")
    repo(f"{TMP}/elsewhere/main")
    subprocess.run(["git", "-C", f"{TMP}/elsewhere/main", "worktree", "add", "-q", f"{TMP}/hobby/wt", "-b", "fix"],
                   check=True)

    # Test copy of jail: own config, `shell` passes its arguments to bash, login skips the provider menu.
    shutil.copy(f"{ROOT}/jail", JAIL)
    patch_jail('CONF = os.path.join(HOME, ".config/jail")', f'CONF = "{TMP}/conf"')
    patch_jail('run("--entrypoint", "bash", "jail")', 'run("--entrypoint", "bash", "jail", *args[1:])')
    patch_jail('"jail", "auth", "login")', '"jail", "auth", "login", "-p", "greenpt")')

    # The host environment must not leak into the sandbox.
    os.environ["GITHUB_TOKEN"] = "leak"
    os.environ["FOO"] = "leak"


# ─── Tests ───────────────────────────────────────────────────────────────────


def tests():
    section("Profile selection")
    r = jail_in(".")
    check("refuses a project outside every profile", r.exited(1), r)
    check("says why", r.has("must match exactly one profile; matches: none"), r)

    write(f"{TMP}/conf/profiles/t-work/paths", f"{TMP}/hobby/*", mode="a")
    r = jail_in("hobby/plain")
    check("refuses a project in two profiles", r.exited(1), r)
    check("names both", r.has("matches: t-hobby"), r)
    write(f"{TMP}/conf/profiles/t-work/paths", f"{TMP}/work/*")

    r = jail_in(".", "login")
    check("refuses login outside every profile", r.exited(1), r)

    section("New profile")
    os.makedirs(f"{TMP}/bare-home")
    os.makedirs(f"{TMP}/oc-home/.config/opencode")
    write(f"{TMP}/oc-home/.config/opencode/AGENTS.md", "hi")
    os.rename(f"{TMP}/conf/masks", f"{TMP}/masks")
    r = new_in(f"{TMP}/bare-home", "t-new")
    check("works without ~/.config/opencode", r.exited(0), r)
    check("...with an allowlist", has_line(f"{TMP}/conf/profiles/t-new/allowlist", "models.dev"), r)
    check("...and paths that match no projects yet", no_entries(f"{TMP}/conf/profiles/t-new/paths"), r)
    check("...and an empty OpenCode config", empty_dir(f"{TMP}/conf/profiles/t-new/home/.config/opencode"), r)
    check("...and default masks", has_line(f"{TMP}/conf/masks", ".env.*"), r)
    check("...and points to the README", r.has("README"), r)
    write(f"{TMP}/conf/masks", "custom")
    r = new_in(f"{TMP}/oc-home", "t-new2")
    check("doesn't copy the host's OpenCode config", empty_dir(f"{TMP}/conf/profiles/t-new2/home/.config/opencode"), r)
    check("keeps existing masks", has_line(f"{TMP}/conf/masks", "custom"), r)
    r = new_in(f"{TMP}/bare-home", "t-new")
    check("refuses an existing profile", r.has("already exists"), r)
    r = new_in(f"{TMP}/bare-home", "../x")
    check("refuses a bad name", r.exited(1), r)
    os.replace(f"{TMP}/masks", f"{TMP}/conf/masks")
    shutil.rmtree(f"{TMP}/conf/profiles/t-new")
    shutil.rmtree(f"{TMP}/conf/profiles/t-new2")

    section("Hobby project")
    r = sandbox("hobby/plain", f"{EGRESS}; pwd; cat .env")
    check("boot checks pass", r.booted(), r)
    check("checks .git", r.has("✅ .git read-only"), r)
    check("reaches its own vendor", r.matches(r"^[1-5][0-9]{2} api.greenpt.ai"), r)
    check("doesn't reach the other vendor", r.has("000 api.githubcopilot.com"), r)
    check("masks .env", r.has(f"jAIl: masked {TMP}/hobby/plain/.env"), r)
    check(".env is empty inside", r.lacks("SECRET"), r)
    check(".env is unchanged on the host", has_line(f"{TMP}/hobby/plain/.env", "SECRET=1"), r)

    section("Work project, from a subfolder")
    r = sandbox("work/proj/sub", f"{EGRESS}; pwd; git --no-pager log --oneline --no-color; touch ../.git/x")
    check("boot checks pass", r.booted(), r)
    check("uses the work profile", r.has("booting profile t-work"), r)
    check("reaches its own vendor", r.matches(r"^[1-5][0-9]{2} api.githubcopilot.com"), r)
    check("doesn't reach the other vendor", r.has("000 api.greenpt.ai"), r)
    check("starts in the subfolder", r.has(f"{TMP}/work/proj/sub"), r)
    check("git works", r.has("init"), r)
    check(".git is read-only", r.has("Read-only file system"), r)

    section("Starting OpenCode")
    r = jail_in("hobby/plain", "--", "--version")
    check("boot checks pass, with GITHUB_TOKEN and FOO set on the host", r.booted(), r)
    check("runs opencode with arguments after --", r.matches(r"^[0-9]+\.[0-9]+\.[0-9]+"), r)
    r = jail_in("hobby/plain", "--version")
    check("runs opencode with arguments without --", r.matches(r"^[0-9]+\.[0-9]+\.[0-9]+"), r)

    section("Other project layouts")
    r = sandbox("hobby/nogit", "pwd")
    check("project without git boots", r.booted(), r)
    check("...and skips the .git check", r.lacks(".git read-only"), r)
    r = sandbox("hobby/wt", "git --no-pager log --oneline --no-color; "
                "git -c user.name=x -c user.email=x commit --allow-empty -qm x")
    check("worktree with its main repo elsewhere boots", r.booted(), r)
    check("...git works", r.has("init"), r)
    check("...the main repo's .git is read-only", r.has("Read-only file system"), r)

    section("Boot checks catch a broken sandbox")
    r = boot_with("-e", "FOO=1", "-e", "BAR=2", "-v", f"{TMP}/hobby/plain/.env:/s:ro,z", "-e", "JAIL_MASKED=/s")
    check("unmasked secret", r.has("❌ secrets masked"), r)
    check("extra environment variables", r.has("unexpected: BAR FOO"), r)
    check("doesn't start", r.has("not starting"), r)
    r = boot_with("-v", f"{TMP}/rwgit:/g:z", "-e", "JAIL_GIT_DIR=/g")
    check("writable .git", r.has("❌ .git read-only"), r)
    check("...and cleans up its probe", empty_dir(f"{TMP}/rwgit"), r)

    section("Login, with a fake key")
    r = sh("bash", "-c", '(sleep 15; printf "k\\r"; sleep 10) | timeout -k 10 90 script -qc "$1 login" /dev/null 2>&1',
           "-", JAIL, cwd=f"{TMP}/hobby/plain/deep")
    r = Result(r.out.replace("\033", ""), r.status)
    check("logs in for the project's profile", r.has("logging in for profile t-hobby"), r)
    check("finishes", r.has("Done"), r)
    r = sandbox("hobby/plain", "opencode auth list")
    check("hobby profile has the login", r.has("1 credentials"), r)
    r = sandbox("work/proj", "opencode auth list")
    check("work profile doesn't", r.has("0 credentials"), r)

    section("Proxy")
    r = sh("podman", "run", "--rm", "--network", "jail-t-hobby", "--entrypoint", "curl", "jail", "-s",
           "-o", "/dev/null", "-w", "%{http_code}\\n", "-x", "http://jail-proxy:8888",
           "http://repo1.maven.org/maven2/", "http://example.com/")
    check("passes plain HTTP to an allowed host", r.matches(r"^301$"), r)
    check("refuses plain HTTP to other hosts", r.matches(r"^403$"), r)


# ─── Main ────────────────────────────────────────────────────────────────────


def main():
    if subprocess.run(["podman", "image", "exists", "jail"]).returncode != 0:
        print(f"{RED}No jail image; run `just build` first.{RESET}")
        return 1
    setup()
    tests()
    print()
    if counts["failed"] > 0:
        print(f"{RED}{BOLD}{counts['failed']} failed{RESET}, {counts['passed']} passed")
        return 1
    print(f"{GREEN}{BOLD}All {counts['passed']} passed{RESET}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        remove_test_profiles()
        shutil.rmtree(TMP)
