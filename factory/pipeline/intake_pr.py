"""intake_pr.py — land an approved intake: a corpus here, a pull request there.

Two repositories change, and they change for different people:

  - This repo gets the bean set (benchmark/<repo>/bean-sets/v1) and the whole
    intake session (transcript, questions, answers, every draft round, the judge's
    review, the developer's session logs), because the approval is only worth
    what the record of how it was reached is worth.
  - The target repo gets the scaffold (control surface plus approved beans) on an
    intake branch, and a pull request the OWNER merges. Merging it is the moment
    the beans become queueable, so it is the owner's act, not the line's.
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import intake


def git(repo: Path, *args: str, capture: bool = True) -> str:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=capture, text=True)
    if r.returncode != 0:
        intake.die(f"git {' '.join(args)} in {repo} failed: {(r.stderr or '').strip()}")
    return (r.stdout or "").strip()


def write_corpus(s: "intake.Session") -> Path:
    name = s.meta["repo"].split("/")[-1]
    set_dir = intake.ROOT / "benchmark" / name / "bean-sets" / "v1"
    beans_dir = set_dir / "beans"
    if beans_dir.exists():
        shutil.rmtree(beans_dir)
    beans_dir.mkdir(parents=True)
    approved = s.meta["approved"]
    for bid in approved["beans"]:
        shutil.copy(s.drafts / f"{bid}.yaml", beans_dir / f"{bid}.yaml")
    dev = [x for x in s.meta.get("developer_sessions", []) if x["mode"] == "draft"]
    manifest = {
        "bean_set": "v1",
        "corpus": name,
        "requirements_sha256": s.meta["source_sha256"],
        "requirements_path": str((s.dir / "source.md").relative_to(intake.ROOT)),
        "intake_session": str(s.dir.relative_to(intake.ROOT)),
        "drafted_by": f"{dev[-1]['model'] if dev else 'developer'} (factory intake, developer role)",
        "reviewed_by": "judge role, advisory; the owner in joint review",
        "approved_by": approved["by"],
        "approved_at": approved["at"],
        "rejected_at_intake": approved.get("rejected", []),
    }
    (set_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return set_dir


def open_intake_pr(s: "intake.Session", dry_run: bool = False) -> None:
    target = Path(s.meta["repo_dir"])
    set_dir = write_corpus(s)
    print(f"corpus: {set_dir.relative_to(intake.ROOT)} ({len(s.meta['approved']['beans'])} beans)")
    if git(target, "status", "--porcelain"):
        intake.die(f"{target} has uncommitted changes; the intake branch starts from a clean main")
    branch = f"intake/{s.meta['id']}"
    scaffold = [str(intake.FACTORY / "scaffold.sh"), str(target), "--bean-set", str(set_dir)]
    if dry_run:
        subprocess.run([*scaffold, "--dry-run"], check=True)
        print(f"(dry run) would commit on {branch} in {target} and open a pull request")
        return
    git(target, "fetch", "-q", "origin")
    git(target, "checkout", "-q", "-B", branch, "origin/main")
    subprocess.run(scaffold, check=True)
    git(target, "add", "-A")
    order = s.meta["approved"]["beans"]
    titles = {b: intake.load_yaml(s.drafts / f"{b}.yaml")["title"] for b in order}
    msg = (f"Intake {s.meta['id']}: {len(order)} approved beans from the owner's transcript\n\n"
           + "".join(f"- {b}: {titles[b]}\n" for b in order)
           + "\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n")
    git(target, "commit", "-q", "-m", msg)
    git(target, "push", "-q", "-u", "origin", branch)
    body = ("Beans approved at intake, with the factory control surface that lets the line run them.\n\n"
            "**Merging this is the approval that queues them.** The line never merges this PR.\n\n"
            "| # | Bean | Title |\n|---|---|---|\n"
            + "".join(f"| {i} | {b} | {titles[b]} |\n" for i, b in enumerate(order, 1))
            + f"\nIntake record: `Local_Dark_Factory/{s.dir.relative_to(intake.ROOT)}` "
              "(transcript, questions and answers, every draft round, the judge's review).\n\n"
              "🤖 Generated with [Claude Code](https://claude.com/claude-code)\n")
    r = subprocess.run(["gh", "pr", "create", "--repo", s.meta["repo"], "--head", branch,
                        "--base", "main", "--title", f"Intake {s.meta['id']}: {len(order)} beans",
                        "--body", body], capture_output=True, text=True)
    git(target, "checkout", "-q", "main")
    if r.returncode != 0:
        intake.die(f"gh pr create failed: {r.stderr.strip()}")
    url = r.stdout.strip().splitlines()[-1]
    s.meta["pr"] = {"url": url, "branch": branch}
    s.save()
    s.log("pr", url=url)
    print(url)
