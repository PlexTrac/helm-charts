#!/usr/bin/env python3
"""Generate the secret-key contract tables in docs/pre-install-checklist.md.

The tables between the BEGIN/END GENERATED markers are derived from what the chart
actually renders, not hand-maintained. This is deliberate: the previous version of
this reference lived in .env.example, was maintained by hand, and had drifted
(wrong key count, shared-secret keys listed under the application secret, and two
keys missing) by the time it was removed in PR #20.

How keys are classified: the chart is rendered twice. A key whose value changes
between renders is auto-generated. A key that is empty is one the operator supplies.
Anything else is a static default, and its value is printed.

Usage:
  scripts/gen-secrets-reference.py            # rewrite the generated region
  scripts/gen-secrets-reference.py --check    # exit 1 if the region is stale (CI)

Requires: helm 3.10+, python3. Maintainer tool; customers never run this.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CHART = REPO / "charts" / "plextrac"
DOC = REPO / "docs" / "pre-install-checklist.md"
BEGIN = "<!-- BEGIN GENERATED: secret-key-contract -->"
END = "<!-- END GENERATED: secret-key-contract -->"
SECRETS = ("application-secrets", "shared-secrets")


def render():
    """Render the chart and return {secret_name: {key: value}} for the manual-mode Secrets."""
    out = subprocess.run(
        ["helm", "template", "ref", str(CHART), "--set", "global.ingress.host=x.example.com"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"helm template failed:\n{out.stderr}")

    found, name, in_sd = {}, None, False
    for line in out.stdout.splitlines():
        if line.startswith("---"):
            name, in_sd = None, False
            continue
        m = re.match(r"^  name: (\S+)", line)
        if m and m.group(1) in SECRETS:
            name = m.group(1)
            found.setdefault(name, {})
            continue
        if name and line.startswith("stringData:"):
            in_sd = True
            continue
        if in_sd and name:
            m = re.match(r'^  ([A-Z0-9_]+): "?(.*?)"?$', line)
            if m:
                found[name][m.group(1)] = m.group(2)
            elif line and not line.startswith("  "):
                in_sd = False
    missing = [s for s in SECRETS if s not in found]
    if missing:
        sys.exit(f"could not find rendered Secret(s): {', '.join(missing)}")
    return found


def classify(a, b):
    """Split keys into (static defaults, operator-supplied, auto-generated)."""
    static, supplied, generated = {}, [], {}
    for k, v in sorted(a.items()):
        if v == "" and b.get(k, "") == "":
            supplied.append(k)
        elif b.get(k) != v:
            generated[k] = len(v)
        else:
            static[k] = v
    return static, supplied, generated


def table(rows, headers):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return out


def build(r1, r2):
    L = []
    app_s, app_u, app_g = classify(r1["application-secrets"], r2["application-secrets"])
    sh_s, sh_u, sh_g = classify(r1["shared-secrets"], r2["shared-secrets"])
    total = len(r1["application-secrets"])

    L += [f"### `application-secrets` — {total} keys", ""]
    L += [
        "In `externalSecrets` and `csi` modes **every key below must exist** in your secret",
        "store before `helm install`, even the ones that may be empty. In `manual` mode the",
        "chart fills all of them in for you and you can ignore this table.", "",
        "> **Nothing validates this at install time.** In `manual` mode the chart generates",
        "> the keys from `secrets.manual.requiredKeys`, so the contract holds by construction.",
        "> In `externalSecrets` mode the chart uses `dataFrom.extract.key`, which pulls your",
        "> remote secret wholesale without enumerating keys; in `csi` mode you supply the",
        "> whole `parameters.secrets` / `secretObjects` mapping yourself. In both, a missing",
        "> key installs cleanly and fails later at runtime, as a crash-loop or a quietly",
        "> broken feature. This table is the only place the contract is written down, which",
        "> is why it is generated rather than hand-maintained.", "",
    ]

    L += [f"#### Auto-generated ({len(app_g)}) — random values, `manual` mode creates these for you", ""]
    L += [
        "In `externalSecrets` / `csi` mode you generate these yourself. Any random value works",
        "on first creation, but **keep them stable afterwards**: nothing rotates them for you,",
        "and changing some of them breaks the deployment (see the rotation notes in",
        "[secrets-modes.md](runbooks/secrets-modes.md)). Lengths below are what the chart",
        "generates, not a hard requirement.", "",
    ]
    L += table([[f"`{k}`", f"{n} chars"] for k, n in sorted(app_g.items())], ["Key", "Chart-generated length"])
    L.append("")

    L += [f"#### Static defaults ({len(app_s)}) — usernames, database and bucket names", ""]
    L += [
        "These are identities, not secrets. The values match the docker-compose reference",
        "deployment. Override them only if you know why; several are referenced by the",
        "Postgres init scripts.", "",
    ]
    L += table([[f"`{k}`", f"`{v}`"] for k, v in sorted(app_s.items())], ["Key", "Value"])
    L.append("")

    L += [f"#### Operator-supplied ({len(app_u)}) — may be empty, but the key must exist", ""]
    L += table([[f"`{k}`"] for k in app_u], ["Key"])
    L.append("")

    L += [f"### `shared-secrets` — {len(r1['shared-secrets'])} keys", ""]
    L += [
        "All optional integrations. Each key must exist in `externalSecrets` / `csi` mode; an",
        "empty value disables that integration.", "",
    ]
    L += table([[f"`{k}`"] for k in sh_u], ["Key"])
    if sh_s or sh_g:
        L += ["", "Non-empty by default in this chart version:", ""]
        L += table([[f"`{k}`"] for k in sorted(list(sh_s) + list(sh_g))], ["Key"])
    L.append("")
    return "\n".join(L)


def main():
    check = "--check" in sys.argv
    generated = build(render(), render())

    if not DOC.exists():
        sys.exit(f"{DOC.relative_to(REPO)} not found; create it with the {BEGIN} / {END} markers first")
    doc = DOC.read_text()
    if BEGIN not in doc or END not in doc:
        sys.exit(f"markers not found in {DOC.relative_to(REPO)}")

    head, rest = doc.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    new = f"{head}{BEGIN}\n\n{generated}\n{END}{tail}"

    if check:
        if new != doc:
            print(f"STALE: {DOC.relative_to(REPO)} does not match the chart.", file=sys.stderr)
            print("Run scripts/gen-secrets-reference.py and commit the result.", file=sys.stderr)
            sys.exit(1)
        print(f"OK: {DOC.relative_to(REPO)} matches the chart.")
        return
    DOC.write_text(new)
    print(f"wrote generated region of {DOC.relative_to(REPO)}")


if __name__ == "__main__":
    main()
