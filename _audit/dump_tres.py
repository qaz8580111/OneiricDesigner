"""Dump all .tres resource fields in this Godot project to structured text."""
import re, sys, io
from pathlib import Path

ROOT = Path(r"D:\Projects\OneiricDesigner\data")
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

def parse_tres(path):
    text = path.read_text(encoding="utf-8")
    # collect ext_resource path -> id
    ext = {}
    for m in re.finditer(r'\[ext_resource type="([^"]+)"[^]]*?path="([^"]+)"[^]]*?id="([^"]+)"', text):
        ext[m.group(3)] = m.group(2)
    # main [resource ...] block
    blocks = {}
    for m in re.finditer(r'\[(sub_resource|resource)[^\]]*\]\n((?:(?!^\[).)*)', text, re.M | re.S):
        kind, body = m.group(1), m.group(2)
        blocks.setdefault(kind, []).append(body)
    return text, ext, blocks

def fields(body, ext):
    out = []
    for raw in body.strip().splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        if "=" not in line:
            # continuation of multiline value
            if out and out[-1][1] is None:
                out[-1][1] = line
            elif out:
                out[-1] = (out[-1][0], (out[-1][1] or "") + " " + line)
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        # strip trailing comment on same line
        v = re.sub(r'\s*;.*$', '', v).strip()
        m = re.match(r'ExtResource\("([^"]+)"\)', v)
        if m:
            v = ext.get(m.group(1), v)
        else:
            m2 = re.match(r'SubResource\("([^"]+)"\)', v)
            if m2:
                v = f"<sub:{m2.group(1)}>"
        out.append([k, v])
    return [(k, v) for k, v in out]

for path in sorted(ROOT.rglob("*.tres")):
    rel = path.relative_to(ROOT.parent)
    text, ext, blocks = parse_tres(path)
    print("=" * 78)
    print(f"### {rel.as_posix()}")
    # script class
    m = re.search(r'script_class="([^"]+)"', text)
    print(f"    class: {m.group(1) if m else '?'}")
    # sub-resources first (shield effects etc.)
    for i, sb in enumerate(blocks.get("sub_resource", []), 1):
        sm = re.search(r'\[sub_resource[^\]]*id="([^"]+)"', text)
        print(f"    [sub#{i}]")
        for k, v in fields(sb, ext):
            print(f"        {k} = {v}")
    for rb in blocks.get("resource", []):
        for k, v in fields(rb, ext):
            print(f"    {k} = {v}")
    print()
