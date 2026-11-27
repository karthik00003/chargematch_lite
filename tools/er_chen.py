#!/usr/bin/env python3
"""Chen-notation ER diagram (Graphviz) from docs/er_model.json, the model tools/er_extract.py derived and verified.

    .venv/bin/python tools/er_chen.py   # writes docs/er_chen.dot
    dot -Tsvg docs/er_chen.dot -o docs/er_chen.svg && dot -Tpng -Gdpi=110 docs/er_chen.dot -o docs/er_chen.png
    (the file sets layout=neato, start=5, so any Graphviz command gives the same picture; start / labeldistance were
    picked so that no 1 / N / M label touches a shape, a line or another label)

Rules (nothing is typed by hand except the verb on each diamond):
  * entity = rectangle; a table whose whole PK is one FK is a WEAK entity (double rectangle, identifying double diamond)
  * a junction table (PK = two FKs) is an ASSOCIATIVE ENTITY: a rectangle inside a diamond, M:N between its two
    parents, with its own columns (e.g. note) as attribute ovals and its composite key as a note (no underline)
  * every other FK = one relationship diamond: parent side "1", child side "N" (or "1" if the FK is UNIQUE / the PK)
  * participation: FK NOT NULL -> every child row takes part -> double line (total) on the child side; else single
  * attributes = ovals, PK underlined; FK columns are not drawn as attributes (the relationship shows them)
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")

# The only hand-written part: a verb for each relationship, read "parent VERB child" (or "left VERB right" for M:N).
VERBS = {
    ("listing", ("host_id",)): "lists",
    ("charger", ("listing_id",)): "contains",
    ("charger", ("connector_id",)): "uses",                 # charger uses a connector type
    ("charger", ("reviewed_by",)): "reviews",
    ("vehicle", ("user_id",)): "owns",
    ("vehicle", ("model_id",)): "is of model",               # not "is a": ISA means inheritance in EER
    ("booking", ("customer_id",)): "books",
    ("booking", ("vehicle_id",)): "for",
    ("booking", ("charger_id",)): "reserves",
    ("charging_session", ("booking_id",)): "has",
    ("bill", ("booking_id",)): "generates",
    "listing_amenity": "offers",
    "model_connector": "accepts",
}

ENTITY = 'shape=box, style="filled", fillcolor="#E8F4F6", color="#0B4048", penwidth=2, fontsize=22, fontname="Helvetica-Bold"'
REL = 'shape=diamond, style="filled", fillcolor="#FFF9C4", color="#6B6B00", penwidth=1.6, fontsize=17, fontname="Helvetica-Bold", margin="0.08,0.04"'
ATTR = 'shape=ellipse, color="#5A5A5A", fontsize=15, fontname="Helvetica", margin="0.06,0.02"'


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    model = json.load(open(os.path.join(DOCS, "er_model.json")))
    tables, fks, junctions = model["tables"], model["foreign_keys"], model["junctions"]
    junction_tables = {j["table"] for j in junctions}
    fk_cols = {t: set() for t in tables}
    for fk in fks:
        fk_cols[fk["child"]].update(fk["columns"])
    weak = {fk["child"] for fk in fks if fk["is_child_pk"] and fk["child"] not in junction_tables}
    missing = []

    out = ["graph chen {",
           '  graph [layout=neato, start=5, overlap=prism, overlap_scaling=-6, sep="+18", splines=true, outputorder=edgesfirst,',
           '         pad=0.4, fontname="Helvetica", fontsize=26, labelloc=t,',
           '         label=<<B>ChargeMatch: ER diagram (Chen notation)</B><BR/><FONT POINT-SIZE="16">generated from information_schema of '
           f'{model["schema"]} · double line = total participation · double box / diamond = weak entity / identifying relationship'
           '<BR/>rectangle in diamond = associative entity (M:N junction table) · 12 tables = 10 entities + 2 associative entities</FONT>>];',
           '  node [fontname="Helvetica"];',
           '  edge [color="#333333", penwidth=1.4, labelfontsize=22, labelfontname="Helvetica-Bold", labelfontcolor="#B00020",',
           '        labeldistance=3.4, labelangle=28, len=1.6];']
    # cardinalities sit at the diamond end of each line (no attribute ovals there): headlabel / taillabel
    # entities + attributes
    for t, info in tables.items():
        if t in junction_tables:
            continue
        extra = ", peripheries=2" if t in weak else ""
        out.append(f'  "{t}" [{ENTITY}{extra}, label="{t}"];')
        for c in info["columns"]:
            if c["name"] in fk_cols[t]:
                continue
            name = esc(c["name"])
            label = f"<<U>{name}</U>>" if c["name"] in info["primary_key"] else f"<{name}>"
            out.append(f'  "{t}.{c["name"]}" [{ATTR}, label={label}];')
            out.append(f'  "{t}" -- "{t}.{c["name"]}" [len=1.0, penwidth=1, color="#777777"];')
    # 1:N and 1:1 relationships
    for fk in fks:
        if fk["child"] in junction_tables:
            continue
        key = (fk["child"], tuple(fk["columns"]))
        verb = VERBS.get(key)
        if verb is None:
            missing.append(key)
            verb = "has"
        rid = f'R_{fk["child"]}_{"_".join(fk["columns"])}'
        ident = fk["is_child_pk"] and fk["child"] in weak
        out.append(f'  "{rid}" [{REL}{", peripheries=2" if ident else ""}, label="{verb}"];')
        child_card = "1" if fk["unique"] else "N"
        total = '"#333333:invis:#333333"'                       # double line = total participation
        out.append(f'  "{fk["parent"]}" -- "{rid}" [headlabel="1"];')
        out.append(f'  "{rid}" -- "{fk["child"]}" [taillabel="{child_card}"'
                   f'{", color=" + total if not fk["nullable"] else ""}];')
    # M:N junction tables = associative entities: a rectangle (HTML table) inside a diamond
    for j in junctions:
        rid = f'R_{j["table"]}'
        verb = VERBS.get(j["table"], "relates")
        box = ('<<TABLE BORDER="2" CELLBORDER="0" CELLPADDING="3" CELLSPACING="0" COLOR="#0B4048" BGCOLOR="#E8F4F6">'
               f'<TR><TD><FONT POINT-SIZE="17"><B>{esc(j["table"])}</B></FONT></TD></TR>'
               f'<TR><TD><FONT POINT-SIZE="15">({esc(verb)})</FONT></TD></TR></TABLE>>')
        out.append(f'  "{rid}" [shape=diamond, style="filled", fillcolor="#FFF9C4", color="#6B6B00", penwidth=1.6, '
                   f'margin="0.02,0.02", label={box}];')
        pk = " + ".join(tables[j["table"]]["primary_key"])
        out.append(f'  "{rid}.pk" [shape=note, style="filled", fillcolor="#FFFFFF", color="#777777", fontsize=14, '
                   f'fontname="Helvetica", label="PK = {pk}"];')
        out.append(f'  "{rid}" -- "{rid}.pk" [len=1.0, style=dotted, penwidth=1.2, color="#777777"];')
        out.append(f'  "{j["left"]}" -- "{rid}" [headlabel="M"];')
        out.append(f'  "{rid}" -- "{j["right"]}" [taillabel="N"];')
        for a in j["attributes"]:
            out.append(f'  "{rid}.{a}" [{ATTR}, label="{a}"];')
            out.append(f'  "{rid}" -- "{rid}.{a}" [len=0.9, penwidth=1, color="#777777"];')
    out.append("}")
    with open(os.path.join(DOCS, "er_chen.dot"), "w") as f:
        f.write("\n".join(out) + "\n")
    rels = sum(1 for fk in fks if fk["child"] not in junction_tables) + len(junctions)
    print(f"er_chen.dot: {len(tables)} tables = {len(tables) - len(junction_tables)} entities ({len(weak)} weak: "
          f"{', '.join(sorted(weak))}) + {len(junction_tables)} associative entities; "
          f"{rels} relationships ({len(junctions)} M:N), from {len(fks)} foreign keys")
    if missing:
        print("no verb for:", missing, "(drawn as 'has'; add them to VERBS)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
