"""One-line descriptions of the kinds of place, written by claude-haiku-5-5 through the Message Batches API (a project decision,
2026-10-28). The lines go to `kinds-described.tsv` (kind, description, model, date), which is reviewed, kept with the
builder and reused by every build until the taxonomy changes; `places_pack common` reads it. Kinds already in the file are
not described again.

Runs in a container (python:3.12-slim with the anthropic SDK, pip-installed inside the container only), with
ANTHROPIC_API_KEY in the environment (and ANTHROPIC_WORKSPACE_ID when the key is not scoped to a workspace):

    python describe_kinds.py --common out/<build>/common.sqlite --tsv kinds-described.tsv [--per-request 50]

The kinds come from the common file `places_pack common` wrote (its kinds table, with the data's own words for each kind
as the hint). The model is asked what the place is and what people go there for, in plain words; nothing about any search
or query is in the prompt.
"""

import argparse
import datetime
import json
import os
import sqlite3
import sys
import time

import anthropic
from anthropic.types.message_create_params import MessageCreateParamsNonStreaming
from anthropic.types.messages.batch_create_params import Request

MODEL = "claude-haiku-5-5"
# Batch prices, USD per million tokens (half the standard $0.10 / $0.50 of claude-haiku-5-5).
PRICE_IN, PRICE_OUT = 0.05, 0.25

PROMPT = """Below are kinds of place from map data (OpenStreetMap tags and the Overture Maps place categories). For each one,
write one plain, factual line of at most 25 words that says what the place is and what people go there for. Use everyday
words. No brand names, no opinions, no marketing. The hint after each kind is the source data's own wording for it; use it
to tell what the kind means. Give every id back exactly as written.

{kinds}"""

SCHEMA = {
    "type": "object",
    "properties": {
        "kinds": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"id": {"type": "string"}, "description": {"type": "string"}},
                "required": ["id", "description"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["kinds"],
    "additionalProperties": False,
}


def read_tsv(path):
    done = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                parts = line.rstrip("\n").split("\t")
                if i == 0 or len(parts) < 2 or line.startswith("#"):
                    continue
                done[parts[0]] = parts
    return done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--common", required=True)
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--per-request", type=int, default=50)
    a = ap.parse_args()

    db = sqlite3.connect(f"file:{a.common}?mode=ro", uri=True)
    kinds = []
    for kid, label, desc, category, rules in db.execute("SELECT id, label, description, category, rules FROM kinds ORDER BY sort"):
        # A kind the rules define has a hand-written description: the hint is its label and category, not that text.
        hint = f"{label} (one of the kinds of {category})" if rules != "[]" and category else desc
        kinds.append((kid, label, hint))
    done = read_tsv(a.tsv)
    todo = [k for k in kinds if k[0] not in done]
    print(f"{len(kinds)} kinds, {len(done)} already described, {len(todo)} to describe", flush=True)
    if not todo:
        return

    chunks = [todo[i:i + a.per_request] for i in range(0, len(todo), a.per_request)]
    requests = []
    for n, chunk in enumerate(chunks):
        lines = "\n".join(f"- id: {kid} | {label} | hint: {hint}" for kid, label, hint in chunk)
        requests.append(Request(
            custom_id=f"kinds-{n}",
            params=MessageCreateParamsNonStreaming(
                model=MODEL,
                max_tokens=16000,
                output_config={"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
                messages=[{"role": "user", "content": PROMPT.format(kinds=lines)}],
            ),
        ))
    workspace = os.environ.get("ANTHROPIC_WORKSPACE_ID")
    client = anthropic.Anthropic(default_headers={"anthropic-workspace-id": workspace} if workspace else None)
    batch = client.messages.batches.create(requests=requests)
    print(f"batch {batch.id}: {len(requests)} requests", flush=True)
    while True:
        batch = client.messages.batches.retrieve(batch.id)
        if batch.processing_status == "ended":
            break
        print(f"  {batch.processing_status}: {batch.request_counts.processing} processing", flush=True)
        time.sleep(20)
    print(f"ended: {batch.request_counts.succeeded} succeeded, {batch.request_counts.errored} errored, {batch.request_counts.expired} expired", flush=True)

    asked = {f"kinds-{n}": {k[0] for k in chunk} for n, chunk in enumerate(chunks)}
    got, tokens_in, tokens_out, problems = {}, 0, 0, []
    for result in client.messages.batches.results(batch.id):
        if result.result.type != "succeeded":
            problems.append(f"{result.custom_id}: {result.result.type}")
            continue
        msg = result.result.message
        tokens_in += msg.usage.input_tokens
        tokens_out += msg.usage.output_tokens
        if msg.stop_reason != "end_turn":
            problems.append(f"{result.custom_id}: stop_reason {msg.stop_reason}")
            continue
        text = next((b.text for b in msg.content if b.type == "text"), "")
        try:
            rows = json.loads(text)["kinds"]
        except (ValueError, KeyError) as e:
            problems.append(f"{result.custom_id}: unreadable answer ({e})")
            continue
        for r in rows:
            kid, d = r["id"].strip(), " ".join(r["description"].split())
            if kid in asked[result.custom_id] and d:
                got[kid] = d
        missing = asked[result.custom_id] - set(got)
        if missing:
            problems.append(f"{result.custom_id}: {len(missing)} kinds not answered")

    today = datetime.date.today().isoformat()
    new_file = not os.path.exists(a.tsv)
    with open(a.tsv, "a", encoding="utf-8") as f:
        if new_file:
            f.write("kind\tdescription\tmodel\tdate\n")
        for kid, _, _ in todo:
            if kid in got:
                f.write(f"{kid}\t{got[kid]}\t{MODEL}\t{today}\n")
    cost = tokens_in / 1e6 * PRICE_IN + tokens_out / 1e6 * PRICE_OUT
    print(f"described {len(got)} of {len(todo)}; {tokens_in} input and {tokens_out} output tokens, about ${cost:.4f} at batch prices", flush=True)
    for p in problems:
        print("problem:", p, flush=True)
    if len(got) < len(todo):
        sys.exit(2)


if __name__ == "__main__":
    main()
