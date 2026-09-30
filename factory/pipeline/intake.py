#!/usr/bin/env python3
"""intake.py — the intake refinery: a transcript becomes approved beans.

The only stage of the line where the input is a person talking rather than a
bean. So it is the one stage where a model's invention is hardest to see later:
a criterion nobody asked for looks exactly like one somebody did. Everything
here is shaped by that.

  - The developer model drafts inside the worker sandbox, over a SNAPSHOT of the
    target repo that it cannot write. What it may write is /work/intake, and the
    controller checks afterwards that nothing else moved.
  - Every excerpt it cites must be found in the transcript. A work item that
    cannot point at what the person said is a work item the person did not say.
  - Ambiguities come out as questions, each with a recommendation. The owner
    answers them; nothing is drafted until they have.
  - Drafts are checked on save against bean.schema.json and the intake rules the
    schema cannot express. A rejected draft goes back with the findings.
  - The judge reviews, advisory only: it has not qualified as a gate.
  - Only a person approves. `approve` is the one command that writes
    `status: approved`, and the model is told never to.

usage:
  intake.py start   --repo <owner/name> --source <transcript.md> [--repo-dir <dir>]
  intake.py extract <session>
  intake.py answer  <session> [--accept-all] [--set q-1=TEXT ...]
  intake.py draft   <session> [--fix]
  intake.py check   <session>
  intake.py judge   <session>
  intake.py review  <session>
  intake.py reject  <session> <bean-id> --why TEXT
  intake.py restore <session> <bean-id>
  intake.py order   <session> <bean-id>...
  intake.py deps    <session> <bean-id> [<dep-id>...]
  intake.py revise  <session> (--split ID | --merge ID ID | --fix ID) --note TEXT [...]
  intake.py approve <session> --by NAME
  intake.py pr      <session> [--dry-run]
  intake.py status  <session>

<session> is a directory under intake/<repo-name>/, or its id.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

PIPELINE = Path(__file__).resolve().parent
FACTORY = PIPELINE.parent
ROOT = FACTORY.parent
sys.path.insert(0, str(ROOT / "bench"))
import validate as schema_tools  # noqa: E402  (bench/validate.py: registry + loader)

import jsonschema  # noqa: E402
import yaml  # noqa: E402

INTAKE_ROOT = Path(os.environ.get("FACTORY_INTAKE_ROOT", ROOT / "intake"))
SCHEMA = ROOT / "schemas" / "bean.schema.json"
EXAMPLE_BEAN = ROOT / "benchmark" / "seating-planner" / "bean-sets" / "v1" / "beans" / "bean-001.yaml"
ROLES = Path(os.environ.get("ROLES_FILE", PIPELINE / "roles.json"))
OLLAMA = os.environ.get("OLLAMA_HOST_URL", "http://127.0.0.1:11434")

# The plan's no-progress rule: if the developer cannot produce a schema-valid
# bean in this many sessions on the real transcript, the answer is a model or
# role change brought to the owner, not one more prompt tweak.
SESSION_LIMIT = int(os.environ.get("INTAKE_SESSION_LIMIT", "3"))

DOD = ["all AC verify pass", "gates green", "spec and impl-detail docs accepted"]


# -- small things ---------------------------------------------------------------

def die(msg: str, rc: int = 1) -> None:
    print(f"intake: {msg}", file=sys.stderr)
    sys.exit(rc)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_yaml(path: Path):
    return yaml.load(path.read_text(), Loader=schema_tools._StringDateLoader)


def dump_yaml(data, path: Path) -> None:
    path.write_text(yaml.safe_dump(data, sort_keys=False, width=100, allow_unicode=True))


def norm(text: str) -> str:
    """Whitespace-collapsed, case-folded, with typographic quotes made plain.

    An excerpt must be the person's words. It need not reproduce a line break
    the transcriber happened to put in, or a curly apostrophe the model typed
    straight."""
    text = text.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    return re.sub(r"\s+", " ", text).strip().casefold()


def excerpt_in_source(excerpt: str, source: str) -> bool:
    e = norm(excerpt).strip(" .,;:!?\"'")
    return bool(e) and e in norm(source)


def bean_sort_key(bean_id: str) -> int:
    m = re.fullmatch(r"bean-(\d+)", bean_id)
    return int(m.group(1)) if m else 10**9


# -- sessions -------------------------------------------------------------------

class Session:
    def __init__(self, path: Path):
        self.dir = path
        self.meta_path = path / "session.json"
        if not self.meta_path.is_file():
            die(f"not an intake session: {path}")
        self.meta = json.loads(self.meta_path.read_text())

    @classmethod
    def find(cls, ref: str) -> "Session":
        p = Path(ref)
        if (p / "session.json").is_file():
            return cls(p.resolve())
        hits = [d for d in INTAKE_ROOT.glob(f"*/{ref}") if (d / "session.json").is_file()]
        if len(hits) != 1:
            die(f"no single intake session named '{ref}' under {INTAKE_ROOT}")
        return cls(hits[0])

    def save(self) -> None:
        self.meta_path.write_text(json.dumps(self.meta, indent=2) + "\n")

    @property
    def source(self) -> str:
        return (self.dir / "source.md").read_text()

    @property
    def drafts(self) -> Path:
        return self.dir / "drafts"

    def draft_files(self) -> list[Path]:
        return sorted(self.drafts.glob("bean-*.yaml"), key=lambda p: bean_sort_key(p.stem))

    def review_state(self) -> dict:
        p = self.dir / "review.json"
        return json.loads(p.read_text()) if p.is_file() else {"order": [], "rejected": {}, "log": []}

    def save_review(self, state: dict) -> None:
        (self.dir / "review.json").write_text(json.dumps(state, indent=2) + "\n")

    def log(self, event: str, **fields) -> None:
        with (self.dir / "events.jsonl").open("a") as fh:
            fh.write(json.dumps({"at": now(), "event": event, **fields}) + "\n")


# -- the developer session --------------------------------------------------------

def role(name: str) -> dict:
    roles = json.loads(ROLES.read_text())
    cfg = roles["roles"][name]
    if cfg["provider"] not in roles["provider_allowlist"]:
        die(f"provider {cfg['provider']} is not allow-listed (runtime is local-only)")
    return cfg


def snapshot_repo(repo_dir: Path, dest: Path) -> str:
    """The target repo's committed HEAD, as files. Not the working tree: what a
    person has uncommitted is not what the beans will be built on."""
    head = subprocess.run(["git", "-C", str(repo_dir), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()
    dest.mkdir(parents=True)
    archive = subprocess.run(["git", "-C", str(repo_dir), "archive", "--format=tar", head],
                             check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(dest)], input=archive, check=True)
    return head


def tree_digest(path: Path) -> str:
    h = hashlib.sha256()
    for p in sorted(path.rglob("*")):
        rel = p.relative_to(path).as_posix()
        h.update(rel.encode() + b"\0")
        if p.is_file() and not p.is_symlink():
            h.update(hashlib.sha256(p.read_bytes()).digest())
    return h.hexdigest()


def make_readonly(path: Path) -> None:
    for p in [path, *path.rglob("*")]:
        if not p.is_symlink():
            p.chmod(p.stat().st_mode & ~0o222)


def make_writable(path: Path) -> None:
    # Best effort: the sandbox's .git mount point is owned by the container's
    # user namespace, and cleanup must not turn a finished session into a crash.
    for p in [path, *path.rglob("*")]:
        try:
            if not p.is_symlink():
                p.chmod(p.stat().st_mode | 0o200)
        except OSError:
            pass


INPUTS = ["session.json", "work-items.yaml", "questions.yaml", "answers.yaml",
          "instructions.md", "check-findings.md"]


def run_developer(s: Session, mode: str) -> int:
    used = [x for x in s.meta.get("developer_sessions", []) if x["mode"] == mode]
    if mode == "draft" and len(used) >= SESSION_LIMIT and not os.environ.get("INTAKE_OVER_LIMIT"):
        die(f"{len(used)} draft sessions already spent (limit {SESSION_LIMIT}). The plan says: stop and\n"
            "bring the owner a model or role change. Do not tune the prompt further.")
    dev = role("developer")
    repo_dir = Path(s.meta["repo_dir"])
    base = Path(tempfile.mkdtemp(prefix="fintake.", dir=os.environ.get("FACTORY_SANDBOX_ROOT")))
    work, agent = base / "work", base / "agent"
    try:
        head = snapshot_repo(repo_dir, work / "repo")
        shutil.copy(s.dir / "source.md", work / "source.md")
        (work / "reference").mkdir()
        shutil.copy(SCHEMA, work / "reference" / "bean.schema.json")
        shutil.copy(EXAMPLE_BEAN, work / "reference" / "example-bean.yaml")
        out = work / "intake"
        out.mkdir()
        for name in INPUTS:
            if (s.dir / name).is_file():
                shutil.copy(s.dir / name, out / name)
        if s.drafts.is_dir():
            shutil.copytree(s.drafts, out / "drafts")
        for ro in (work / "repo", work / "reference", work / "source.md"):
            make_readonly(ro)
        fixed = {n: tree_digest(work / n) if (work / n).is_dir() else sha256(work / n)
                 for n in ("repo", "reference", "source.md")}

        (agent / "sessions").mkdir(parents=True)
        models = json.loads((Path.home() / ".pi/agent/models.json").read_text())
        for prov in models.get("providers", {}).values():
            for m in prov.get("models") or []:
                if m.get("id") == dev["model"] and dev.get("num_ctx"):
                    m["contextWindow"] = dev["num_ctx"]
        (agent / "models.json").write_text(json.dumps(models))
        (agent / "settings.json").write_text(json.dumps({"httpIdleTimeoutMs": 0}))

        gw = subprocess.run([str(PIPELINE / "model-gateway.sh"), "start"],
                            capture_output=True, text=True)
        if gw.returncode != 0:
            die("could not open a model gateway; refusing to run the developer uncontained")
        gw_dir = gw.stdout.strip()
        subprocess.run([str(PIPELINE / "ensure-loaded.sh"), "developer"], stdout=sys.stderr)
        pi_args = ["--model", f"{dev['provider']}/{dev['model']}"]
        if dev.get("thinking"):
            pi_args += ["--thinking", dev["thinking"]]
        pi_args += ["--no-extensions", "--no-prompt-templates", "--no-context-files",
                    "--no-skills", "--tools", "read,write,edit,bash",
                    "--skill", "/factory/skills", "-p", f"/skill:factory-intake {mode}"]
        timeout = os.environ.get("INTAKE_WORKER_TIMEOUT", "3600")
        print(f"INTAKE {mode}: developer {dev['model']} in the worker sandbox (limit {timeout}s)",
              file=sys.stderr)
        t0 = time.time()
        started = now()
        try:
            rc = subprocess.run(
                [str(PIPELINE / "worker-sandbox.sh"), "--tree", str(work), "--agent-dir", str(agent),
                 "--socket-dir", gw_dir, "--skills", str(FACTORY / "skills"),
                 "--lock", str(FACTORY / "worker.lock.yaml"), "--timeout", timeout, "--", *pi_args],
                stdin=subprocess.DEVNULL).returncode
        finally:
            subprocess.run([str(PIPELINE / "model-gateway.sh"), "stop", "--dir", gw_dir],
                           capture_output=True)
        seconds = int(time.time() - t0)
        if rc == 5:
            die("the worker sandbox refused; the session did NOT run on the host instead")

        # Read-only is enforced by permissions and then verified, because a
        # container user that owns the files could chmod them back.
        moved = [n for n, d in fixed.items()
                 if (tree_digest(work / n) if (work / n).is_dir() else sha256(work / n)) != d]
        stray = sorted(p.name for p in work.iterdir()
                       if p.name not in ("repo", "reference", "source.md", "intake", ".git"))

        n = len(s.meta.get("developer_sessions", [])) + 1
        sess_files = sorted((agent / "sessions").rglob("*.jsonl"))
        (s.dir / "sessions").mkdir(exist_ok=True)
        for i, f in enumerate(sess_files):
            shutil.copy(f, s.dir / "sessions" / f"{n:02d}-{mode}{'-' + str(i) if i else ''}.jsonl")

        record = {"n": n, "mode": mode, "started_at": started, "seconds": seconds, "rc": rc,
                  "model": dev["model"], "repo_head": head, "contained": True,
                  "readonly_violations": moved, "stray_paths": stray}
        s.meta.setdefault("developer_sessions", []).append(record)
        s.save()
        s.log("developer-session", **record)
        if moved or stray:
            die(f"containment: the session changed {moved + stray}; its output is discarded")

        if mode == "extract":
            for name in ("work-items.yaml", "questions.yaml"):
                if (out / name).is_file():
                    shutil.copy(out / name, s.dir / name)
        else:
            if (out / "drafts").is_dir():
                if s.drafts.is_dir():
                    shutil.rmtree(s.drafts)
                shutil.copytree(out / "drafts", s.drafts)
        print(f"INTAKE {mode}: session {n} ended rc={rc} after {seconds}s", file=sys.stderr)
        return rc
    finally:
        if work.exists():
            make_writable(work)
        shutil.rmtree(base, ignore_errors=True)


# -- checks -------------------------------------------------------------------------

def check_extract(s: Session) -> list[str]:
    f: list[str] = []
    src = s.source
    wi_path, q_path = s.dir / "work-items.yaml", s.dir / "questions.yaml"
    if not wi_path.is_file():
        return ["work-items.yaml: missing"]
    try:
        items = (load_yaml(wi_path) or {}).get("items") or []
    except yaml.YAMLError as e:
        return [f"work-items.yaml: not YAML: {e}"]
    ids = set()
    for i, it in enumerate(items):
        where = f"work-items.yaml items[{i}]"
        if not isinstance(it, dict):
            f.append(f"{where}: not a mapping"); continue
        iid = str(it.get("id", ""))
        if not re.fullmatch(r"wi-\d+", iid):
            f.append(f"{where}: id '{iid}' is not wi-N")
        if iid in ids:
            f.append(f"{where}: duplicate id {iid}")
        ids.add(iid)
        for key in ("title", "summary"):
            if not str(it.get(key) or "").strip():
                f.append(f"{where} ({iid}): no {key}")
        ex = it.get("excerpts") or []
        if not ex:
            f.append(f"{where} ({iid}): no excerpts; every item must point at what the person said")
        for e in ex:
            if not excerpt_in_source(str(e), src):
                f.append(f"{where} ({iid}): excerpt not found in source.md: \"{e}\"")
    if not items:
        f.append("work-items.yaml: no items")
    if q_path.is_file():
        try:
            qs = (load_yaml(q_path) or {}).get("questions") or []
        except yaml.YAMLError as e:
            return f + [f"questions.yaml: not YAML: {e}"]
        qids = set()
        for i, q in enumerate(qs):
            where = f"questions.yaml questions[{i}]"
            if not isinstance(q, dict):
                f.append(f"{where}: not a mapping"); continue
            qid = str(q.get("id", ""))
            if not re.fullmatch(r"q-\d+", qid) or qid in qids:
                f.append(f"{where}: id '{qid}' is not a unique q-N")
            qids.add(qid)
            for key in ("question", "why", "recommendation"):
                if not str(q.get(key) or "").strip():
                    f.append(f"{where} ({qid}): no {key}")
            for a in q.get("about") or []:
                if a not in ids:
                    f.append(f"{where} ({qid}): about names unknown item {a}")
    return f


def _validator() -> jsonschema.Draft202012Validator:
    return jsonschema.Draft202012Validator(json.loads(SCHEMA.read_text()),
                                           registry=schema_tools.local_registry())


def check_bean(path: Path, s: Session, all_ids: set[str], stage: str = "draft") -> list[str]:
    """Everything a saved draft must satisfy. `stage` is draft or approved."""
    name = path.name
    try:
        b = load_yaml(path)
    except yaml.YAMLError as e:
        return [f"{name}: not YAML: {e}"]
    if not isinstance(b, dict):
        return [f"{name}: not a mapping"]
    f = []
    for err in sorted(_validator().iter_errors(b), key=lambda e: list(e.path)):
        where = "/".join(str(p) for p in err.path) or "<root>"
        f.append(f"{name}: schema: {where}: {err.message}")
    if b.get("schema_version") != "bean/2.0.0":
        f.append(f"{name}: schema_version must be bean/2.0.0")
    if b.get("id") != path.stem:
        f.append(f"{name}: id '{b.get('id')}' does not match the file name")
    if b.get("repo") != s.meta["repo"]:
        f.append(f"{name}: repo '{b.get('repo')}' is not {s.meta['repo']}")
    if stage == "draft":
        if b.get("status") not in ("draft", "rejected"):
            f.append(f"{name}: status '{b.get('status')}': drafts are `draft`; only the owner approves")
        if "approval" in b:
            f.append(f"{name}: has an approval block; only `intake approve` writes one")
    src = b.get("source") or {}
    if src.get("kind") != "transcript":
        f.append(f"{name}: source.kind must be transcript")
    if not src.get("excerpt") or not excerpt_in_source(str(src.get("excerpt")), s.source):
        f.append(f"{name}: source.excerpt is not found in source.md: \"{src.get('excerpt')}\"")
    sb = b.get("size_budget") or {}
    for k in ("max_tasks", "max_files", "max_diff_lines"):
        if not isinstance(sb.get(k), int):
            f.append(f"{name}: size_budget.{k} is not set")
    writable = [str(p) for p in b.get("allowed_write_paths") or []]
    for ac in b.get("acceptance_criteria") or []:
        if not isinstance(ac, dict):
            continue
        aid, v = ac.get("id"), ac.get("verify") or {}
        kind = v.get("kind")
        if kind == "command" and not v.get("run"):
            f.append(f"{name}: {aid}: verify kind command has no run argv")
        elif kind == "test":
            tid = str(v.get("test_id") or "")
            if "::" not in tid:
                f.append(f"{name}: {aid}: test_id '{tid}' is not a pytest node id (file::test)")
            elif not any(fnmatch.fnmatch(tid.split("::")[0], w) for w in writable):
                f.append(f"{name}: {aid}: test file {tid.split('::')[0]} is outside allowed_write_paths,"
                         " so the bean could not write the test that verifies it")
        elif kind == "manual" and not str(v.get("note") or "").strip():
            f.append(f"{name}: {aid}: a manual verify needs a note saying what the human checks")
        elif kind == "judge":
            f.append(f"{name}: {aid}: verify kind judge is not accepted; the judge has not qualified"
                     " (bench/results/judge-qualify-*). Use a test, a command, or manual")
        elif kind == "gate":
            f.append(f"{name}: {aid}: verify kind gate: this repo has no gates.lock.yaml yet; use a command")
    for d in b.get("dependencies") or []:
        if d not in all_ids:
            f.append(f"{name}: depends on {d}, which is not a bean in this intake")
        elif bean_sort_key(d) >= bean_sort_key(path.stem):
            f.append(f"{name}: depends on {d}, which does not come before it")
    return f


def check_drafts(s: Session, stage: str | None = None) -> dict[str, list[str]]:
    stage = stage or ("approved" if s.meta.get("approved") else "draft")
    files = s.draft_files()
    ids = {p.stem for p in files}
    out = {p.stem: check_bean(p, s, ids, stage) for p in files}
    stray = [p.name for p in s.drafts.iterdir() if p.suffix == ".yaml" and p not in files] \
        if s.drafts.is_dir() else []
    if stray:
        out["_stray"] = [f"{n}: not named bean-NNN.yaml" for n in stray]
    return out


def write_findings(s: Session, findings: list[str]) -> None:
    p = s.dir / "check-findings.md"
    if findings:
        p.write_text("# Check findings\n\nThe controller rejected these. Fix every one.\n\n"
                     + "".join(f"- {x}\n" for x in findings))
    elif p.exists():
        p.unlink()


# -- judge (advisory) ----------------------------------------------------------------

JUDGE_SCHEMA = {
    "type": "object", "required": ["beans", "missing"],
    "properties": {
        "beans": {"type": "array", "items": {
            "type": "object", "required": ["id", "findings"],
            "properties": {"id": {"type": "string"}, "findings": {"type": "array", "items": {
                "type": "object", "required": ["severity", "text"],
                "properties": {"severity": {"enum": ["blocker", "concern", "nit"]},
                               "text": {"type": "string"}}}}}}},
        "missing": {"type": "array", "items": {"type": "string"}}}}


def run_judge(s: Session) -> Path:
    j = role("judge")
    parts = [f"=== TRANSCRIPT (source.md) ===\n{s.source}"]
    for name in ("answers.yaml",):
        if (s.dir / name).is_file():
            parts.append(f"=== {name} ===\n{(s.dir / name).read_text()}")
    for p in s.draft_files():
        parts.append(f"=== {p.name} ===\n{p.read_text()}")
    system = ("You review draft work items (beans) written from a requirements transcript. You have "
              "no tools. Everything is in the message. Judge only from it. Answer with JSON only.")
    user = ("\n\n".join(parts) + "\n\n=== YOUR TASK ===\nFor each bean, list findings: a criterion the "
            "person did not ask for, something they asked for that no bean covers, an acceptance "
            "criterion whose verify would not prove its text, a dependency that is wrong, or a bean "
            "too large for about four tasks. severity is blocker, concern or nit. Put requests "
            "from the transcript that no bean covers in `missing`. An empty list is a valid answer.")
    body = {"model": j["model"], "stream": False, "think": j.get("thinking", "low"), "tools": [],
            "format": JUDGE_SCHEMA,
            "options": {"num_ctx": j.get("num_ctx", 32768), "temperature": 0,
                        "num_predict": int(os.environ.get("JUDGE_NUM_PREDICT", "16000")),
                        "repeat_penalty": 1.1},
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    (s.dir / "review").mkdir(exist_ok=True)
    n = len(list((s.dir / "review").glob("judge-*.json"))) + 1
    out = s.dir / "review" / f"judge-{n}.json"
    t0 = time.time()
    record: dict = {"model": j["model"], "at": now(), "advisory": True}
    try:
        req = urllib.request.Request(f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1800) as r:
            resp = json.loads(r.read())
        content = resp.get("message", {}).get("content", "")
        record["done_reason"] = resp.get("done_reason")
        record["eval_count"] = resp.get("eval_count")
        try:
            record["review"] = json.loads(content)
            jsonschema.validate(record["review"], JUDGE_SCHEMA)
            record["usable"] = True
        except (json.JSONDecodeError, jsonschema.ValidationError) as e:
            record.update(usable=False, why=f"unusable answer: {str(e)[:200]}", raw=content[:4000])
    except Exception as e:  # noqa: BLE001 - advisory: record and carry on
        record.update(usable=False, why=f"request failed: {e}")
    record["seconds"] = int(time.time() - t0)
    out.write_text(json.dumps(record, indent=2) + "\n")
    s.log("judge", file=out.name, usable=record["usable"], seconds=record["seconds"])
    return out


def latest_judge(s: Session) -> dict | None:
    files = sorted((s.dir / "review").glob("judge-*.json"),
                   key=lambda p: int(p.stem.split("-")[1])) if (s.dir / "review").is_dir() else []
    return json.loads(files[-1].read_text()) if files else None


# -- commands -------------------------------------------------------------------------

def cmd_start(a) -> None:
    src = Path(a.source)
    if not src.is_file():
        die(f"no transcript at {src}")
    name = a.repo.split("/")[-1]
    repo_dir = Path(a.repo_dir or Path.home() / "workspace" / name).resolve()
    if not (repo_dir / ".git").exists():
        die(f"no git repository at {repo_dir} (pass --repo-dir)")
    sid = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    d = INTAKE_ROOT / name / sid
    d.mkdir(parents=True)
    shutil.copy(src, d / "source.md")
    meta = {"schema": "intake-session/1", "id": sid, "repo": a.repo, "repo_dir": str(repo_dir),
            "source_ref": str(src), "source_sha256": sha256(d / "source.md"),
            "date": dt.date.today().isoformat(), "created_at": now(),
            "ai_side": {"drafts": "developer", "reviews": "judge (advisory)"},
            "developer_sessions": []}
    (d / "session.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(d)
    s = Session(d)
    s.log("start", repo=a.repo, source=str(src))
    cmd_extract(argparse.Namespace(session=str(d)))


def cmd_extract(a) -> None:
    s = Session.find(a.session)
    run_developer(s, "extract")
    f = check_extract(s)
    s.log("check-extract", findings=len(f))
    if f:
        print("\nextract: the work items did not pass their checks:")
        for x in f:
            print(f"  FAIL  {x}")
        sys.exit(1)
    print_questions(s)


def print_questions(s: Session) -> None:
    items = (load_yaml(s.dir / "work-items.yaml") or {}).get("items") or []
    print(f"\n{len(items)} work items:")
    for it in items:
        print(f"  {it['id']:<6} {it['title']}")
    qs = questions(s)
    ans = answers(s)
    print(f"\n{len(qs)} questions:")
    for q in qs:
        mark = "answered" if q["id"] in ans else "open"
        print(f"  {q['id']:<5} [{mark}] {q['question']}\n        why: {q['why']}\n"
              f"        recommendation: {q['recommendation']}")


def questions(s: Session) -> list[dict]:
    p = s.dir / "questions.yaml"
    return ((load_yaml(p) or {}).get("questions") or []) if p.is_file() else []


def answers(s: Session) -> dict:
    p = s.dir / "answers.yaml"
    return ((load_yaml(p) or {}).get("answers") or {}) if p.is_file() else {}


def cmd_answer(a) -> None:
    s = Session.find(a.session)
    qs = {q["id"]: q for q in questions(s)}
    ans = answers(s)
    by = a.by or os.environ.get("USER", "owner")
    for kv in a.set or []:
        qid, _, text = kv.partition("=")
        if qid not in qs:
            die(f"no question {qid}")
        ans[qid] = {"answer": text.strip(), "answered_by": by, "at": now()}
    if a.accept_all:
        for qid in qs:
            ans.setdefault(qid, {"answer": "accept", "answered_by": by, "at": now()})
    if not a.set and not a.accept_all:
        if not sys.stdin.isatty():
            die("no answers given: pass --set q-N=TEXT or --accept-all, or run in a terminal")
        for qid, q in qs.items():
            if qid in ans:
                continue
            print(f"\n{qid}: {q['question']}\n  why: {q['why']}\n  recommendation: {q['recommendation']}")
            text = input("  answer (Enter accepts the recommendation): ").strip()
            ans[qid] = {"answer": text or "accept", "answered_by": by, "at": now()}
    dump_yaml({"answers": ans}, s.dir / "answers.yaml")
    s.log("answers", ids=sorted(ans))
    missing = [q for q in qs if q not in ans]
    print(f"{len(ans)} answered, {len(missing)} open" + (f": {', '.join(missing)}" if missing else ""))


def cmd_draft(a) -> None:
    s = Session.find(a.session)
    open_q = [q["id"] for q in questions(s) if q["id"] not in answers(s)]
    if open_q:
        die(f"questions still open: {', '.join(open_q)}. Nothing is drafted over an unanswered question.")
    if not a.fix:
        write_findings(s, [])
    run_developer(s, "draft")
    if (s.dir / "instructions.md").exists():
        done = s.dir / "review" / f"instructions-{len(s.meta['developer_sessions']):02d}.md"
        done.parent.mkdir(exist_ok=True)
        shutil.move(s.dir / "instructions.md", done)
    sys.exit(report_check(s))


def report_check(s: Session) -> int:
    res = check_drafts(s)
    flat = [x for v in res.values() for x in v]
    write_findings(s, flat)
    s.log("check-drafts", beans=len(s.draft_files()), findings=len(flat))
    for bid, f in res.items():
        print(f"  {'ok   ' if not f else 'FAIL '} {bid}")
        for x in f:
            print(f"          {x}")
    print(f"\n{len(s.draft_files())} draft(s), {len(flat)} finding(s)")
    if flat:
        print("run `factory intake draft <session> --fix` to send them back to the developer")
    return 1 if flat else 0


def cmd_check(a) -> None:
    s = Session.find(a.session)
    sys.exit(report_check(s))


def cmd_judge(a) -> None:
    s = Session.find(a.session)
    out = run_judge(s)
    r = json.loads(out.read_text())
    if not r["usable"]:
        print(f"judge: no usable review ({r['why']}). It is advisory; review goes on without it.")
        return
    for b in r["review"]["beans"]:
        for x in b["findings"]:
            print(f"  {b['id']:<9} {x['severity']:<8} {x['text']}")
    for m in r["review"]["missing"]:
        print(f"  MISSING   {m}")
    print(f"\n(advisory, {r['seconds']}s) {out}")


def beans(s: Session) -> dict[str, dict]:
    return {p.stem: load_yaml(p) for p in s.draft_files()}


def run_order(s: Session) -> list[str]:
    st = s.review_state()
    ids = [i for i in beans(s) if i not in st["rejected"]]
    ordered = [i for i in st["order"] if i in ids]
    return ordered + sorted((i for i in ids if i not in ordered), key=bean_sort_key)


def cmd_review(a) -> None:
    s = Session.find(a.session)
    bs, st, res = beans(s), s.review_state(), check_drafts(s)
    judge = latest_judge(s)
    jf: dict[str, list] = {}
    if judge and judge.get("usable"):
        for b in judge["review"]["beans"]:
            jf[b["id"]] = b["findings"]
    order = run_order(s)
    print(f"{'#':>2}  {'bean':<9} {'ACs':>3} {'man':>3} {'deps':<18} {'budget':<14} {'check':<6} judge  title")
    for pos, bid in enumerate(order, 1):
        _row(pos, bid, bs[bid], res.get(bid, []), jf.get(bid, []))
    for bid, why in st["rejected"].items():
        print(f"    {bid:<9} REJECTED: {why}")
    manual = [(bid, ac["id"], ac["verify"].get("note", "")) for bid in order
              for ac in bs[bid].get("acceptance_criteria") or []
              if (ac.get("verify") or {}).get("kind") == "manual"]
    if manual:
        print("\nmanual criteria (a person checks these; each one forces a human review):")
        for bid, aid, note in manual:
            print(f"  {bid} {aid}: {note}")
    if judge and judge.get("usable") and judge["review"]["missing"]:
        print("\njudge says the transcript asks for, and no bean covers:")
        for m in judge["review"]["missing"]:
            print(f"  - {m}")
    elif judge and not judge.get("usable"):
        print(f"\njudge: no usable review ({judge.get('why')})")


def _row(pos, bid, b, findings, jfind) -> None:
    acs = b.get("acceptance_criteria") or []
    man = sum(1 for x in acs if (x.get("verify") or {}).get("kind") == "manual")
    sb = b.get("size_budget") or {}
    budget = f"{sb.get('max_tasks', '?')}t/{sb.get('max_files', '?')}f/{sb.get('max_diff_lines', '?')}l"
    deps = ",".join(d.replace("bean-", "") for d in b.get("dependencies") or []) or "-"
    blockers = sum(1 for x in jfind if x["severity"] == "blocker")
    j = f"{len(jfind)}" + (f"({blockers}!)" if blockers else "")
    print(f"{pos:>2}  {bid:<9} {len(acs):>3} {man:>3} {deps:<18} {budget:<14} "
          f"{'ok' if not findings else 'FAIL':<6} {j:<6} {b.get('title', '')}")


def cmd_reject(a) -> None:
    s = Session.find(a.session)
    if a.bean not in beans(s):
        die(f"no draft {a.bean}")
    st = s.review_state()
    st["rejected"][a.bean] = a.why
    st["log"].append({"at": now(), "op": "reject", "bean": a.bean, "why": a.why})
    s.save_review(st)
    p = s.drafts / f"{a.bean}.yaml"
    b = load_yaml(p)
    b["status"] = "rejected"
    dump_yaml(b, p)
    s.log("reject", bean=a.bean, why=a.why)
    dependents = [i for i, x in beans(s).items() if a.bean in (x.get("dependencies") or [])
                  and i not in st["rejected"]]
    if dependents:
        print(f"warning: {', '.join(dependents)} depend on {a.bean}; fix with `deps` or `revise`")


def cmd_restore(a) -> None:
    s = Session.find(a.session)
    st = s.review_state()
    if st["rejected"].pop(a.bean, None) is None:
        die(f"{a.bean} is not rejected")
    st["log"].append({"at": now(), "op": "restore", "bean": a.bean})
    s.save_review(st)
    p = s.drafts / f"{a.bean}.yaml"
    b = load_yaml(p)
    b["status"] = "draft"
    dump_yaml(b, p)


def cmd_order(a) -> None:
    s = Session.find(a.session)
    known = set(beans(s))
    bad = [b for b in a.beans if b not in known]
    if bad:
        die(f"unknown beans: {bad}")
    st = s.review_state()
    st["order"] = a.beans
    st["log"].append({"at": now(), "op": "order", "order": a.beans})
    s.save_review(st)
    pos = {b: i for i, b in enumerate(run_order(s))}
    for bid, b in beans(s).items():
        for d in b.get("dependencies") or []:
            if bid in pos and d in pos and pos[d] > pos[bid]:
                print(f"warning: {bid} depends on {d}, which now runs after it")


def cmd_deps(a) -> None:
    s = Session.find(a.session)
    p = s.drafts / f"{a.bean}.yaml"
    if not p.is_file():
        die(f"no draft {a.bean}")
    b = load_yaml(p)
    b["dependencies"] = a.deps
    dump_yaml(b, p)
    st = s.review_state()
    st["log"].append({"at": now(), "op": "deps", "bean": a.bean, "deps": a.deps})
    s.save_review(st)
    for x in check_bean(p, s, set(beans(s))):
        print(f"  FAIL  {x}")


def cmd_revise(a) -> None:
    s = Session.find(a.session)
    known = set(beans(s))
    lines = ["# Revision instructions from the owner's review\n",
             "Change only what is named here. Every other draft stays as it is.\n"]
    for bid in a.split or []:
        if bid not in known:
            die(f"no draft {bid}")
        lines.append(f"- **Split {bid}** into two beans. Keep {bid} for the first part and write the "
                     "second as the next free bean number, depending on the first.")
    for pair in a.merge or []:
        x, y = pair
        if x not in known or y not in known:
            die(f"no draft {x} or {y}")
        lines.append(f"- **Merge {y} into {x}.** Rewrite {x} to cover both, delete {y}.yaml, and point "
                     f"any bean that depended on {y} at {x}.")
    for bid in a.fix or []:
        if bid not in known:
            die(f"no draft {bid}")
        lines.append(f"- **Revise {bid}.**")
    lines.append(f"\nThe owner's note: {a.note}\n")
    (s.dir / "instructions.md").write_text("\n".join(lines))
    st = s.review_state()
    st["log"].append({"at": now(), "op": "revise", "split": a.split, "merge": a.merge,
                      "fix": a.fix, "note": a.note})
    s.save_review(st)
    cmd_draft(argparse.Namespace(session=str(s.dir), fix=False))


def cmd_approve(a) -> None:
    s = Session.find(a.session)
    order = run_order(s)
    if not order:
        die("nothing to approve")
    res = check_drafts(s)
    bad = {k: v for k, v in res.items() if v and k in order}
    if bad:
        for k, v in bad.items():
            for x in v:
                print(f"  FAIL  {x}")
        die("drafts fail their checks; approval stamps only valid beans")
    st = s.review_state()
    pos = {b: i for i, b in enumerate(order)}
    for bid in order:
        for d in load_yaml(s.drafts / f"{bid}.yaml").get("dependencies") or []:
            if d in st["rejected"]:
                die(f"{bid} depends on rejected {d}")
            if pos[d] > pos[bid]:
                die(f"{bid} runs before its dependency {d}; fix the order")
    at = now()
    for i, bid in enumerate(order, 1):
        p = s.drafts / f"{bid}.yaml"
        b = load_yaml(p)
        b["status"] = "approved"
        b["approval"] = {"approved_by": a.by, "approved_at": at, "order": i}
        dump_yaml(b, p)
    after = check_drafts(s, stage="approved")
    flat = [x for k, v in after.items() if k in order for x in v]
    if flat:
        die(f"stamped beans fail validation: {flat}")
    st["log"].append({"at": at, "op": "approve", "by": a.by, "beans": order})
    s.save_review(st)
    s.meta["approved"] = {"by": a.by, "at": at, "beans": order, "rejected": sorted(st["rejected"])}
    s.save()
    s.log("approve", by=a.by, beans=order)
    print(f"approved {len(order)} bean(s) by {a.by}: {', '.join(order)}")


def cmd_status(a) -> None:
    s = Session.find(a.session)
    m = s.meta
    print(f"session  {m['id']}  repo {m['repo']}  source {m['source_ref']}")
    for x in m.get("developer_sessions", []):
        print(f"  dev #{x['n']} {x['mode']:<8} rc={x['rc']} {x['seconds']}s  {x['started_at']}")
    qs, ans = questions(s), answers(s)
    print(f"  questions {len(qs)}, answered {len(ans)}")
    print(f"  drafts {len(s.draft_files())}")
    if m.get("approved"):
        print(f"  approved by {m['approved']['by']} at {m['approved']['at']}: {len(m['approved']['beans'])}")


def cmd_pr(a) -> None:
    from intake_pr import open_intake_pr  # noqa: PLC0415 - only this command needs it
    s = Session.find(a.session)
    if not s.meta.get("approved"):
        die("nothing approved yet: run `factory intake approve` first")
    open_intake_pr(s, dry_run=a.dry_run)


def main(argv: list[str]) -> None:
    ap = argparse.ArgumentParser(prog="factory intake", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("start"); p.add_argument("--repo", required=True)
    p.add_argument("--source", required=True); p.add_argument("--repo-dir")
    p.set_defaults(fn=cmd_start)
    for name, fn in (("extract", cmd_extract), ("check", cmd_check), ("judge", cmd_judge),
                     ("review", cmd_review), ("status", cmd_status)):
        p = sub.add_parser(name); p.add_argument("session"); p.set_defaults(fn=fn)
    p = sub.add_parser("answer"); p.add_argument("session"); p.add_argument("--set", action="append")
    p.add_argument("--accept-all", action="store_true"); p.add_argument("--by")
    p.set_defaults(fn=cmd_answer)
    p = sub.add_parser("draft"); p.add_argument("session"); p.add_argument("--fix", action="store_true")
    p.set_defaults(fn=cmd_draft)
    p = sub.add_parser("reject"); p.add_argument("session"); p.add_argument("bean")
    p.add_argument("--why", required=True); p.set_defaults(fn=cmd_reject)
    p = sub.add_parser("restore"); p.add_argument("session"); p.add_argument("bean")
    p.set_defaults(fn=cmd_restore)
    p = sub.add_parser("order"); p.add_argument("session"); p.add_argument("beans", nargs="+")
    p.set_defaults(fn=cmd_order)
    p = sub.add_parser("deps"); p.add_argument("session"); p.add_argument("bean")
    p.add_argument("deps", nargs="*"); p.set_defaults(fn=cmd_deps)
    p = sub.add_parser("revise"); p.add_argument("session")
    p.add_argument("--split", action="append"); p.add_argument("--merge", nargs=2, action="append")
    p.add_argument("--fix", action="append"); p.add_argument("--note", required=True)
    p.set_defaults(fn=cmd_revise)
    p = sub.add_parser("approve"); p.add_argument("session"); p.add_argument("--by", required=True)
    p.set_defaults(fn=cmd_approve)
    p = sub.add_parser("pr"); p.add_argument("session"); p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_pr)
    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main(sys.argv[1:])
