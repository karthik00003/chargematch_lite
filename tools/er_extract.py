#!/usr/bin/env python3
"""ER diagram of the LIVE chargematch_lite database, derived only from information_schema (read-only).

    .venv/bin/python tools/er_extract.py

1. EXTRACT  every table's columns, PK and UNIQUE keys (COLUMNS, STATISTICS) and every foreign key
            (KEY_COLUMN_USAGE + REFERENTIAL_CONSTRAINTS): child, FK column(s), parent, ON DELETE,
            nullable?, unique in the child (a UNIQUE / PRIMARY index on exactly the same column set)?
2. DECIDE   the crow's-foot ends by fixed rules (Mermaid, written PARENT <left>--<right> CHILD):
              parent end: FK NOT NULL -> "||" (exactly one)   FK NULL -> "|o" (zero or one)
              child end:  FK unique / PK of child -> "o|" (0..1)   otherwise -> "o{" (0..N)
3. VERIFY   against the data: "o|" -> MAX(children per parent) <= 1;  "||" -> no child row has a NULL FK;
            number of FKs and tables in the diagram = number in information_schema.
4. WRITE    docs/er_model.json (input for tools/er_chen.py), docs/er_crowsfoot.mmd and docs/ER_DIAGRAM.md.

Runs as the app user (cmlite_app) and only SELECTs: no data or schema is changed. Exit code 1 if anything is ✗.
"""
import json
import os
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import config  # noqa: E402
import db      # noqa: E402

SCHEMA = config.DB_NAME
DOCS = os.path.join(ROOT, "docs")


def q(cur, sql, args=()):
    cur.execute(sql, args)
    return cur.fetchall()


def table(rows, headers):
    """Plain-text table for the terminal."""
    rows = [[str(c) for c in r] for r in rows]
    w = [max(len(h), *(len(r[i]) for r in rows)) if rows else len(h) for i, h in enumerate(headers)]
    line = lambda cells: "  ".join(c.ljust(w[i]) for i, c in enumerate(cells))
    return "\n".join([line(headers), line(["-" * x for x in w])] + [line(r) for r in rows])


def md_table(rows, headers):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    out += ["| " + " | ".join(str(c).replace("|", "\\|") for c in r) + " |" for r in rows]   # GitHub: escape | even in code
    return "\n".join(out)


def ident(name):
    return "`" + name.replace("`", "``") + "`"


# ------------------------------------------------------------------------------------------------ 1. extract
def extract(cur):
    tables = [r["TABLE_NAME"] for r in q(cur, """
        SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = %s AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME""", (SCHEMA,))]
    columns = defaultdict(list)
    for r in q(cur, """
        SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA
          FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = %s
         ORDER BY TABLE_NAME, ORDINAL_POSITION""", (SCHEMA,)):
        columns[r["TABLE_NAME"]].append({"name": r["COLUMN_NAME"], "data_type": r["DATA_TYPE"],
                                         "column_type": r["COLUMN_TYPE"], "nullable": r["IS_NULLABLE"] == "YES",
                                         "auto_increment": "auto_increment" in (r["EXTRA"] or "")})
    # unique indexes (PRIMARY + UNIQUE): exact column lists in index order
    uniq = defaultdict(lambda: defaultdict(list))
    for r in q(cur, """
        SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME FROM information_schema.STATISTICS
         WHERE TABLE_SCHEMA = %s AND NON_UNIQUE = 0
         ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX""", (SCHEMA,)):
        uniq[r["TABLE_NAME"]][r["INDEX_NAME"]].append(r["COLUMN_NAME"])
    fk_rows = q(cur, """
        SELECT k.CONSTRAINT_NAME, k.TABLE_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME,
               k.ORDINAL_POSITION, r.DELETE_RULE, r.UPDATE_RULE
          FROM information_schema.KEY_COLUMN_USAGE k
          JOIN information_schema.REFERENTIAL_CONSTRAINTS r
            ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
           AND r.TABLE_NAME = k.TABLE_NAME
         WHERE k.TABLE_SCHEMA = %s AND k.REFERENCED_TABLE_NAME IS NOT NULL
         ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION""", (SCHEMA,))
    fks = {}
    for r in fk_rows:
        fk = fks.setdefault(r["CONSTRAINT_NAME"], {
            "name": r["CONSTRAINT_NAME"], "child": r["TABLE_NAME"], "parent": r["REFERENCED_TABLE_NAME"],
            "columns": [], "parent_columns": [], "on_delete": r["DELETE_RULE"], "on_update": r["UPDATE_RULE"]})
        fk["columns"].append(r["COLUMN_NAME"])
        fk["parent_columns"].append(r["REFERENCED_COLUMN_NAME"])
    fk_count_schema = q(cur, """SELECT COUNT(*) AS n FROM information_schema.REFERENTIAL_CONSTRAINTS
                                 WHERE CONSTRAINT_SCHEMA = %s""", (SCHEMA,))[0]["n"]
    return tables, columns, uniq, list(fks.values()), fk_count_schema


# ------------------------------------------------------------------------------------------------- 2. decide
def decide(tables, columns, uniq, fks):
    nullable = {(t, c["name"]): c["nullable"] for t in tables for c in columns[t]}
    for fk in fks:
        child_unique_sets = [set(cols) for cols in uniq[fk["child"]].values()]
        fk["nullable"] = any(nullable[(fk["child"], c)] for c in fk["columns"])
        fk["unique"] = set(fk["columns"]) in child_unique_sets                  # exact same column set
        fk["is_child_pk"] = set(fk["columns"]) == set(uniq[fk["child"]].get("PRIMARY", []))
        fk["left"] = "|o" if fk["nullable"] else "||"
        fk["right"] = "o|" if fk["unique"] else "o{"
        fk["mermaid"] = f'{fk["left"]}--{fk["right"]}'
        fk["ratio"] = f'{"0..1" if fk["nullable"] else "1"}:{"0..1" if fk["unique"] else "N"}'
    # junction table: its PK is made of exactly the columns of two FKs that point at two different tables
    junctions = []
    for t in tables:
        pk = set(uniq[t].get("PRIMARY", []))
        mine = [fk for fk in fks if fk["child"] == t]
        for i, a in enumerate(mine):
            for b in mine[i + 1:]:
                if a["parent"] != b["parent"] and pk == set(a["columns"]) | set(b["columns"]):
                    # name the pair in the order the junction table's name does: listing M:N amenity, model M:N connector
                    pos = lambda fk: min((t.find(w) for w in fk["parent"].split("_") if w in t), default=99)
                    if pos(b) < pos(a):
                        a, b = b, a
                    extra = [c["name"] for c in columns[t] if c["name"] not in pk]
                    junctions.append({"table": t, "left": a["parent"], "right": b["parent"],
                                      "fks": [a["name"], b["name"]], "attributes": extra})
    return junctions


# ------------------------------------------------------------------------------------------------- 3. verify
def verify(cur, fks, tables, fk_count_schema, table_count_schema):
    for fk in fks:
        child, cols = ident(fk["child"]), ", ".join(ident(c) for c in fk["columns"])
        not_null = " AND ".join(f"{ident(c)} IS NOT NULL" for c in fk["columns"])
        any_null = " OR ".join(f"{ident(c)} IS NULL" for c in fk["columns"])
        checks = []
        # children per parent (actual maximum), for every relationship
        mx = q(cur, f"SELECT IFNULL(MAX(cnt), 0) AS m FROM (SELECT COUNT(*) AS cnt FROM {child} "
                    f"WHERE {not_null} GROUP BY {cols}) x")[0]["m"]
        fk["max_children"] = int(mx)
        nulls = q(cur, f"SELECT COUNT(*) AS n FROM {child} WHERE {any_null}")[0]["n"]
        fk["null_rows"] = int(nulls)
        ok = True
        if fk["right"] == "o|":
            checks.append(f"max children per parent = {mx} (must be ≤ 1)")
            ok &= mx <= 1
        else:
            checks.append(f"max children per parent = {mx}")
        if fk["left"] == "||":
            checks.append(f"child rows with NULL FK = {nulls} (must be 0)")
            ok &= nulls == 0
        else:
            checks.append(f"child rows with NULL FK = {nulls} (allowed)")
        fk["checks"] = checks
        fk["verified"] = bool(ok)
    totals = [("Foreign keys", len(fks), fk_count_schema, 15), ("Tables", len(tables), table_count_schema, 12)]
    return totals


# -------------------------------------------------------------------------------------------------- 4. write
def mermaid_type(c):
    """Mermaid attribute types may hold letters, digits, - _ ( ) [ ] but no commas or quotes."""
    t = c["column_type"]
    if c["data_type"] in ("char", "varchar"):
        return t
    if c["data_type"] == "enum":
        return "enum"
    if c["data_type"] == "decimal":
        return t.replace(",", "-")              # decimal(5,2) -> decimal(5-2)
    return c["data_type"]


def mermaid(tables, columns, uniq, fks, junctions):
    fk_cols = defaultdict(set)
    for fk in fks:
        fk_cols[fk["child"]].update(fk["columns"])
    lines = ["erDiagram"]
    # relationships, grouped by parent
    for fk in sorted(fks, key=lambda f: (f["parent"], f["child"], f["columns"])):
        lines.append(f'    {fk["parent"]} {fk["mermaid"]} {fk["child"]} : "{", ".join(fk["columns"])} ({fk["ratio"]})"')
    lines.append("")
    for t in tables:
        pk = set(uniq[t].get("PRIMARY", []))
        uk = {c for name, cols in uniq[t].items() if name != "PRIMARY" for c in cols}
        lines.append(f"    {t} {{")
        for c in columns[t]:
            keys = [k for k, on in (("PK", c["name"] in pk), ("FK", c["name"] in fk_cols[t]), ("UK", c["name"] in uk)) if on]
            notes = []
            if c["data_type"] == "enum":
                notes.append(c["column_type"][5:-1].replace("'", "").replace(",", " / "))
            for name, cols in uniq[t].items():              # a UK over several columns is unique only together
                if name != "PRIMARY" and len(cols) > 1 and c["name"] in cols:
                    notes.append("UK together: " + " + ".join(cols))
            if c["nullable"]:
                notes.append("NULL")
            comment = f' "{" · ".join(notes)}"' if notes else ""
            lines.append(f'        {mermaid_type(c)} {c["name"]}{" " + ", ".join(keys) if keys else ""}{comment}')
        lines.append("    }")
    return "\n".join(lines) + "\n"


def main():
    conn = db.connect()
    try:
        with conn.cursor() as cur:
            tables, columns, uniq, fks, fk_count_schema = extract(cur)
            junctions = decide(tables, columns, uniq, fks)
            totals = verify(cur, fks, tables, fk_count_schema, len(tables))
    finally:
        conn.close()

    # ---- terminal output
    print(f"Database: {SCHEMA} (read-only, as {config.DB_USER})\n")
    print("FOREIGN KEYS (information_schema.KEY_COLUMN_USAGE + REFERENTIAL_CONSTRAINTS)")
    print(table([(f["child"], ", ".join(f["columns"]), f["parent"], f["on_delete"],
                  "NULL" if f["nullable"] else "NOT NULL",
                  "PK" if f["is_child_pk"] and f["unique"] else ("UNIQUE" if f["unique"] else "no"))
                 for f in fks], ["Child", "FK column(s)", "Parent", "ON DELETE", "Nullable", "Unique in child"]))
    print("\nKEYS AND COLUMNS (information_schema.STATISTICS + COLUMNS)")
    print(table([(t, ", ".join(uniq[t].get("PRIMARY", [])),
                   "; ".join(f"{n}({', '.join(c)})" for n, c in uniq[t].items() if n != "PRIMARY") or "—",
                   ", ".join(c["name"] for c in columns[t])) for t in tables],
                ["Table", "Primary key", "Unique keys", "Columns"]))
    print("\nJUNCTION TABLES (PK = the columns of two FKs)")
    for j in junctions:
        print(f"  {j['table']}: {j['left']} M:N {j['right']}   extra attributes: {', '.join(j['attributes']) or '—'}")
    print("\nVERIFICATION AGAINST THE DATA")
    final = [(f["parent"], f["child"], ", ".join(f["columns"]), "YES" if f["nullable"] else "NO",
              "YES" if f["unique"] else "NO", f'`{f["mermaid"]}`', f["ratio"], "; ".join(f["checks"]),
              "✓" if f["verified"] else "✗") for f in sorted(fks, key=lambda f: (f["parent"], f["child"]))]
    headers = ["Parent", "Child", "FK", "Nullable", "Unique", "Mermaid", "Ratio", "Data check", "Verified"]
    print(table([[c.strip("`") for c in r] for r in final], headers))
    tot_rows = [(name, diagram, schema, expected, "✓" if diagram == schema == expected else "✗")
                for name, diagram, schema, expected in totals]
    print()
    print(table(tot_rows, ["Count", "In diagram", "In information_schema", "Expected", "Verified"]))
    all_ok = all(f["verified"] for f in fks) and all(r[-1] == "✓" for r in tot_rows)
    print("\nALL VERIFIED ✓" if all_ok else "\nSOMETHING FAILED ✗ (see above)")

    # ---- files
    mmd = mermaid(tables, columns, uniq, fks, junctions)
    with open(os.path.join(DOCS, "er_crowsfoot.mmd"), "w") as f:
        f.write(mmd)
    model = {"schema": SCHEMA, "tables": {t: {"columns": columns[t], "primary_key": uniq[t].get("PRIMARY", []),
                                              "unique_keys": {n: c for n, c in uniq[t].items() if n != "PRIMARY"}}
                                          for t in tables},
             "foreign_keys": fks, "junctions": junctions}
    with open(os.path.join(DOCS, "er_model.json"), "w") as f:
        json.dump(model, f, indent=1, default=str)
    write_markdown(mmd, final, headers, tot_rows, junctions, fks, tables, uniq)
    return 0 if all_ok else 1


def write_markdown(mmd, final, headers, tot_rows, junctions, fks, tables, uniq):
    mn = "\n".join(f"* **{j['left']} M:N {j['right']}**, resolved by `{j['table']}` "
                   f"(PK = {' + '.join(uniq[j['table']]['PRIMARY'])}"
                   f"{'; own attribute: ' + ', '.join(j['attributes']) if j['attributes'] else ''}). "
                   f"Drawn as two 1:N lines: {j['left']} 1:N {j['table']} and {j['right']} 1:N {j['table']}."
                   for j in junctions)
    keys = md_table([(t, ", ".join(uniq[t].get("PRIMARY", [])),
                      "; ".join(f"`{n}` ({', '.join(c)})" for n, c in uniq[t].items() if n != "PRIMARY") or "—")
                     for t in tables], ["Table", "Primary key", "Unique keys"])
    text = f"""# ChargeMatch: ER diagram (generated from the live database)

Generated by `tools/er_extract.py` from `information_schema` of the live `{SCHEMA}` database (read-only), then checked
against the data. Regenerate with `.venv/bin/python tools/er_extract.py` (and the render commands at the end).

* Crow's-foot (this page, also `er_crowsfoot.svg` / `er_crowsfoot.png`)
* Chen notation for the viva: `er_chen.svg` / `er_chen.png` (below)

## How each line was decided

Every line is one foreign key, written `PARENT <parent end>--<child end> CHILD : "fk_column (ratio)"`.

| Rule (from information_schema) | Symbol | Meaning |
|---|---|---|
| FK column NOT NULL | `\\|\\|` at the parent | each child row has **exactly one** parent |
| FK column NULL | `\\|o` at the parent | each child row has **zero or one** parent |
| FK column(s) UNIQUE or the child's PK (same column set) | `o\\|` at the child | each parent row has **zero or one** child (ratio 1 : 0..1) |
| otherwise | `o{{` at the child | each parent row has **zero or many** children (ratio 1 : N) |

Legend: `||` exactly one · `|o` / `o|` zero or one · `o{{` zero or many.

## Crow's-foot diagram

![ChargeMatch ER diagram, crow's-foot notation](er_crowsfoot.svg)

```mermaid
{mmd}```

## Chen notation (for the viva)

![ChargeMatch ER diagram, Chen notation](er_chen.svg)

Built by `tools/er_chen.py` from the same verified model (`er_model.json`):

* **Rectangle** = entity, **diamond** = relationship (named with a verb), **oval** = attribute, <u>underlined</u> = primary key.
  FK columns are not drawn as ovals: the relationship diamond is the foreign key.
* **1 / N / M** on each line = the same ratios as the table below (1:N, 1:0..1 drawn as 1:1, M:N).
* **Double line** = total participation: the FK is NOT NULL, so every child row takes part (e.g. every booking is made
  by a user). Single line = partial (a user need not book; `charger.reviewed_by` is NULL until reviewed).
* **Double rectangle + double diamond** = weak entity and its identifying relationship: `charging_session`'s whole
  primary key is its FK `booking_id`, so a session cannot exist or be identified without its booking.
* Junction tables are not entities: `listing_amenity` is the M:N diamond *offers* (with its attribute `note`) and
  `model_connector` is the M:N diamond *accepts*.

## Many-to-many relationships

{mn}

## Verification against the data

For a `o|` child end the most children any parent has must be ≤ 1; for a `||` parent end no child row may have a
NULL foreign key. The other ends need no data check (they allow more), so the actual maximum is shown for information.

{md_table(final, headers)}

{md_table(tot_rows, ["Count", "In diagram", "In information_schema", "Expected", "Verified"])}

## Keys per table

{keys}

## Rendering

```bash
.venv/bin/python tools/er_extract.py          # extract + verify + this page, er_crowsfoot.mmd, er_model.json
.venv/bin/python tools/er_chen.py             # er_chen.dot from er_model.json
export PUPPETEER_SKIP_DOWNLOAD=1                  # mermaid-cli uses the installed Chrome (docs/er_puppeteer.json)
npx -y @mermaid-js/mermaid-cli@11 -i docs/er_crowsfoot.mmd -o docs/er_crowsfoot.svg -b white -c docs/er_mermaid_config.json -p docs/er_puppeteer.json
npx -y @mermaid-js/mermaid-cli@11 -i docs/er_crowsfoot.mmd -o docs/er_crowsfoot.png -s 2 -b white -c docs/er_mermaid_config.json -p docs/er_puppeteer.json
dot -Tsvg docs/er_chen.dot -o docs/er_chen.svg && dot -Tpng -Gdpi=110 docs/er_chen.dot -o docs/er_chen.png   # Graphviz (brew install graphviz)
```
"""
    with open(os.path.join(DOCS, "ER_DIAGRAM.md"), "w") as f:
        f.write(text)


if __name__ == "__main__":
    sys.exit(main())
