#!/usr/bin/env python3
"""Stage 1-3 of the art bake-off: generate style sheets from the Stage-0 renders.

See design_ideas/art_direction.md. The short version:

  * art/shots.json  -> tmp/shots/*.png   (Godot, `--run-shots`) -- the CONTROL images
  * art/anchors/<CODE>.png               -- one hero image per style, the style contract
  * art/prompts/<CODE>.txt               -- the frozen scaffold, one {SUBJECT} slot
  * this script                          -- holds all three fixed and varies the subject
  * art/out/<CODE>/                      -- generated cells + a sheet to look at

THE API HAS NO SEED AND NO TEMPERATURE. Consistency does not come from sampler
settings; it comes from holding the INPUTS fixed -- the same anchor, the same
control render, the same scaffold. Two runs are not pixel-identical and do not
need to be: every style is held by the same three mechanisms, so no style gets
an advantage from the way it was prompted.

Stdlib only, deliberately: no pip, no venv, no lockfile. It is a dev tool -- the
build and the test gate never invoke it, and a machine without Python can still
build and ship the game.

Usage:
    export GEMINI_API_KEY=...            # never stored in the repo
    python art/gen.py anchors            # stage 1: six hero images, one per style
    python art/gen.py roster --style SITE
    python art/gen.py all
    python art/gen.py roster --dry-run   # print the exact request, call nothing
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
SHOTS = os.path.join(REPO, "tmp", "shots")
OUT = os.path.join(ROOT, "out")
ANCHORS = os.path.join(ROOT, "anchors")
PROMPTS = os.path.join(ROOT, "prompts")

ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions"

# Anchors and action shots go to Pro: six of the first and eighteen of the
# second, and they are the images anyone actually looks at. The ~126 roster
# cells go to Flash, which also carries the style-reference slots this needs.
MODEL_PRO = "gemini-3-pro-image"
MODEL_FLASH = "gemini-3.1-flash-image"

# Per-model reference-slot budgets, asserted rather than discovered in a 400.
SLOT_BUDGET = {MODEL_PRO: 6, MODEL_FLASH: 10}


def styles():
    return sorted(f[:-4] for f in os.listdir(PROMPTS) if f.endswith(".txt"))


CONTROL_RULE = (
    "Keep the proportions, stance, camera angle and composition of the reference\n"
    "render exactly. You are restyling an existing object, not inventing a new one.\n")


def read_prompt(code, subject, framing, has_control):
    with open(os.path.join(PROMPTS, code + ".txt"), encoding="utf-8") as fh:
        scaffold = fh.read()
    # The rule is only true when a control render is actually attached. Left in
    # for the anchor -- which has none -- it instructs the model to match a
    # reference that is not there, which is the kind of prompt line that quietly
    # costs you an image.
    scaffold = scaffold.replace("{CONTROL_RULE}", CONTROL_RULE if has_control else "")
    # Formatted from the file, never concatenated at the call site: a prompt that
    # gets hand-tweaked per cell is how a sheet ends up comparing prompts
    # instead of comparing styles.
    return scaffold.replace("{SUBJECT}", subject).replace("{FRAMING}", framing)


def b64(path):
    with open(path, "rb") as fh:
        return base64.b64encode(fh.read()).decode("ascii")


def build_request(model, prompt, images, aspect="1:1", size="2K"):
    parts = [{"type": "text", "text": prompt}]
    for path in images:
        parts.append({"type": "image", "mime_type": "image/png", "data": b64(path)})
    budget = SLOT_BUDGET.get(model, 6)
    if len(images) > budget:
        raise SystemExit("%s takes at most %d reference images, got %d"
                         % (model, budget, len(images)))
    return {
        "model": model,
        "input": parts,
        "response_format": {
            "type": "image",
            "mime_type": "image/png",
            "aspect_ratio": aspect,
            "image_size": size,
        },
    }


def find_image(payload):
    """Pull the first base64 image blob out of a response.

    Walks the whole structure rather than indexing one documented path: the
    response shape is the one thing here we do not control, and a schema change
    should cost a shrug rather than a rewrite. If nothing is found the caller
    gets the raw JSON to look at.
    """
    stack = [payload]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            data = node.get("data")
            if isinstance(data, str) and len(data) > 1024:
                mime = str(node.get("mime_type", node.get("mimeType", "image/png")))
                if mime.startswith("image/"):
                    return data
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return None


def call(api_key, body, retries=4):
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json", "x-goog-api-key": api_key},
        method="POST",
    )
    delay = 4.0
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:400]
            # 429 and 5xx are worth waiting out; a 400 is a bug in what we sent
            # and retrying it just spends money slowly.
            if err.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                print("    http %d, retrying in %.0fs" % (err.code, delay))
                time.sleep(delay)
                delay *= 2
                continue
            raise SystemExit("http %d: %s" % (err.code, detail))
        except urllib.error.URLError as err:
            if attempt < retries - 1:
                print("    %s, retrying in %.0fs" % (err.reason, delay))
                time.sleep(delay)
                delay *= 2
                continue
            raise SystemExit("network: %s" % err.reason)
    return None


def control_path(name):
    if not name:
        return None
    path = os.path.join(SHOTS, name + ".beauty.png")
    return path if os.path.exists(path) else None


def generate(api_key, code, cell, subject, framing, control, model, aspect, size,
             dry_run, force):
    out_dir = os.path.join(OUT, code)
    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, cell + ".png")
    if os.path.exists(target) and not force:
        print("  = %-24s (exists, --force to redo)" % cell)
        return True

    prompt = read_prompt(code, subject, framing, control is not None)
    refs = []
    anchor = os.path.join(ANCHORS, code + ".png")
    if os.path.exists(anchor):
        refs.append(anchor)
    elif cell != "_anchor" and dry_run:
        print("  ~ %-24s (no anchor yet -- it would be reference 1)" % cell)
    elif cell != "_anchor":
        raise SystemExit(
            "no anchor for %s -- run `python art/gen.py anchors` first.\n"
            "The anchor is the style contract; generating cells without one is "
            "six styles of nothing in particular." % code)
    if control:
        refs.append(control)

    if dry_run:
        print("  ~ %-24s %s  refs=%s  %s %s" % (
            cell, model, [os.path.basename(r) for r in refs], aspect, size))
        print("    " + "\n    ".join(prompt.strip().splitlines()))
        print()
        return True

    body = build_request(model, prompt, refs, aspect, size)
    payload = call(api_key, body)
    data = find_image(payload)
    if data is None:
        stamp = os.path.join(out_dir, cell + ".response.json")
        with open(stamp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        print("  ! %-24s no image in response -> %s" % (cell, stamp))
        return False
    with open(target, "wb") as fh:
        fh.write(base64.b64decode(data))
    print("  + %-24s %d KB" % (cell, os.path.getsize(target) // 1024))
    return True


# --- Sheets ------------------------------------------------------------------
#
# HTML rather than a composited image: it keeps this script on the stdlib, and it
# puts the control render BESIDE every generated cell so drift in proportion or
# composition is visible by default rather than something you have to go looking
# for. compare.html is the view the Stage-4 rubric is scored from.

SHEET_CSS = """
:root { color-scheme: light dark; }
body { font: 14px/1.5 system-ui, sans-serif; margin: 24px; }
h1, h2 { font-weight: 500; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
.cell { border: 1px solid #8886; border-radius: 8px; padding: 10px; }
.pair { display: flex; gap: 6px; }
.pair img { width: 50%; border-radius: 4px; background: #8882; }
.pair img.solo { width: 100%; }
.name { font-weight: 500; margin: 8px 0 2px; }
.sub { opacity: .7; font-size: 12px; }
table { border-collapse: collapse; width: 100%; }
td, th { border: 1px solid #8886; padding: 6px; vertical-align: top; text-align: left; }
td img { width: 100%; border-radius: 4px; }
"""


def write_sheet(code, rows):
    out_dir = os.path.join(OUT, code)
    os.makedirs(out_dir, exist_ok=True)
    html = ["<meta charset='utf-8'><title>%s sheet</title><style>%s</style>" % (code, SHEET_CSS),
            "<h1>%s</h1><div class='grid'>" % code]
    for cell, subject, control in rows:
        img = cell + ".png"
        if not os.path.exists(os.path.join(out_dir, img)):
            continue
        control_img = ""
        if control:
            rel = os.path.relpath(control, out_dir).replace("\\", "/")
            control_img = "<img src='%s' alt='control render'>" % rel
        html.append(
            "<div class='cell'><div class='pair'>%s<img src='%s' class='%s' alt='%s'></div>"
            "<div class='name'>%s</div><div class='sub'>%s</div></div>"
            % (control_img, img, "" if control_img else "solo", cell, cell,
               subject[:150].replace("<", "&lt;")))
    html.append("</div>")
    path = os.path.join(out_dir, "sheet.html")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(html))
    return path


def write_compare(codes, rows):
    os.makedirs(OUT, exist_ok=True)
    html = ["<meta charset='utf-8'><title>style comparison</title><style>%s</style>" % SHEET_CSS,
            "<h1>Style comparison</h1><table><tr><th>cell</th><th>control</th>"]
    for code in codes:
        html.append("<th>%s</th>" % code)
    html.append("</tr>")
    for cell, subject, control in rows:
        html.append("<tr><td><div class='name'>%s</div><div class='sub'>%s</div></td>"
                    % (cell, subject[:200].replace("<", "&lt;")))
        if control:
            html.append("<td><img src='%s'></td>" % os.path.relpath(control, OUT).replace("\\", "/"))
        else:
            html.append("<td></td>")
        for code in codes:
            img = os.path.join(OUT, code, cell + ".png")
            html.append("<td><img src='%s/%s.png'></td>" % (code, cell)
                        if os.path.exists(img) else "<td></td>")
        html.append("</tr>")
    html.append("</table>")
    path = os.path.join(OUT, "compare.html")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(html))
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stage", choices=["anchors", "roster", "action", "all", "sheets"])
    parser.add_argument("--style", action="append", help="limit to one style code (repeatable)")
    parser.add_argument("--cell", action="append", help="limit to one cell (repeatable)")
    parser.add_argument("--limit", type=int, default=0, help="stop after N cells per style")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the exact request for each cell and call nothing")
    parser.add_argument("--force", action="store_true", help="regenerate cells that already exist")
    args = parser.parse_args()

    with open(os.path.join(ROOT, "subjects.json"), encoding="utf-8") as fh:
        subjects = json.load(fh)

    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key and not args.dry_run and args.stage != "sheets":
        # Refuses rather than prompting: a key typed at a prompt ends up in a
        # shell history, and a key read from a file in the repo ends up in a
        # commit.
        raise SystemExit("GEMINI_API_KEY is not set. Set it in the environment; "
                         "this script will not read a key from a file in the repo.")

    codes = args.style or styles()
    for code in codes:
        if not os.path.exists(os.path.join(PROMPTS, code + ".txt")):
            raise SystemExit("no prompt scaffold for %s" % code)

    def rows_for(stage):
        out = []
        for entry in subjects.get(stage, []):
            if args.cell and entry["cell"] not in args.cell:
                continue
            out.append((entry["cell"], entry["subject"], control_path(entry.get("control"))))
        return out

    roster_rows = rows_for("roster")
    action_rows = rows_for("action")

    if args.stage == "sheets":
        for code in codes:
            print("sheet:", write_sheet(code, roster_rows + action_rows))
        print("compare:", write_compare(codes, roster_rows + action_rows))
        return

    for code in codes:
        print("[%s]" % code)
        if args.stage in ("anchors", "all"):
            generate(api_key, code, "_anchor", subjects["anchor_subject"],
                     subjects["framing"]["anchor"], None, MODEL_PRO, "4:3", "4K",
                     args.dry_run, args.force)
            src = os.path.join(OUT, code, "_anchor.png")
            if os.path.exists(src) and not os.path.exists(os.path.join(ANCHORS, code + ".png")):
                os.makedirs(ANCHORS, exist_ok=True)
                with open(src, "rb") as a, open(os.path.join(ANCHORS, code + ".png"), "wb") as b:
                    b.write(a.read())
                print("  -> promoted to art/anchors/%s.png (the style contract; "
                      "delete it to re-roll)" % code)

        if args.stage in ("roster", "all"):
            for i, (cell, subject, control) in enumerate(roster_rows):
                if args.limit and i >= args.limit:
                    print("  (stopped at --limit %d, %d cells not generated)"
                          % (args.limit, len(roster_rows) - args.limit))
                    break
                generate(api_key, code, cell, subject, subjects["framing"]["roster"],
                         control, MODEL_FLASH, "1:1", "2K", args.dry_run, args.force)

        if args.stage in ("action", "all"):
            for cell, subject, control in action_rows:
                generate(api_key, code, cell, subject, subjects["framing"]["action"],
                         control, MODEL_PRO, "16:9", "2K", args.dry_run, args.force)

        if not args.dry_run:
            print("  sheet:", write_sheet(code, roster_rows + action_rows))

    if not args.dry_run:
        print("compare:", write_compare(codes, roster_rows + action_rows))


if __name__ == "__main__":
    sys.exit(main())
