#!/usr/bin/env python3
from __future__ import annotations
import argparse, os
import pandas as pd
import duckdb

def _split_pipe(val):
    if val is None or (isinstance(val, float) and pd.isna(val)): return []
    s = str(val).strip()
    if not s: return []
    return [x.strip() for x in s.split("|") if x.strip()]

def _parse_bbox(val):
    if val is None or (isinstance(val, float) and pd.isna(val)): return None
    parts = [p.strip() for p in str(val).split(",")]
    if len(parts) != 4: return None
    mnlat, mnlon, mxlat, mxlon = map(float, parts)
    return (mnlat, mnlon, mxlat, mxlon)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, help="Path to osm_changesets.duckdb")
    ap.add_argument("--group-def", required=True, help="Path to data/metadata/group_definition.csv")
    ap.add_argument("--out", default="data/metadata/group_users.csv", help="Output CSV (username only)")
    args = ap.parse_args()

    df = pd.read_csv(args.group_def)
    if df.empty:
        raise SystemExit("group_definition.csv is empty.")

    # We assume a single active group (first row)
    row = df.iloc[0]

    tags_exact      = _split_pipe(row.get("Group_tags"))
    tags_like       = _split_pipe(row.get("Group_liketags"))
    comment_terms   = _split_pipe(row.get("Group_comment"))       # treated as substrings
    comment_like    = _split_pipe(row.get("Group_likecomment"))   # treat as LIKE patterns
    bbox            = _parse_bbox(row.get("Group_bbx"))
    start_date      = str(row.get("Group_startdate")).strip() if pd.notna(row.get("Group_startdate")) else None
    end_date        = str(row.get("Group_enddate")).strip() if pd.notna(row.get("Group_enddate")) else None

    top_active = None
    if "TopActive" in df.columns and pd.notna(row.get("TopActive")):
        try:
            ta = int(row["TopActive"])
            if ta > 0:
                top_active = ta
        except Exception:
            pass

    #Build SQL (case-insensitive on hashtags/comments - only need usernames out)
    base_where = ["WHERE 1=1 AND c.user IS NOT NULL"]
    params = []

    if start_date:
        base_where.append("AND c.created >= ?")
        params.append(pd.to_datetime(start_date))
    if end_date:
        base_where.append("AND c.created <= ?")
        params.append(pd.to_datetime(end_date))
    if bbox:
        mnlat, mnlon, mxlat, mxlon = bbox
        base_where.append("AND ((c.min_lat + c.max_lat)/2.0) BETWEEN ? AND ?")
        base_where.append("AND ((c.min_lon + c.max_lon)/2.0) BETWEEN ? AND ?")
        params.extend([mnlat, mxlat, mnlon, mxlon])

    # Tag conditions (match against LOWER(h.hashtag)); we strip leading '#' and lowercase
    tag_expr_parts, tag_params = [], []
    t_exact = [t.lstrip("#").lower() for t in tags_exact]
    if t_exact:
        tag_expr_parts.append(f"LOWER(h.hashtag) IN ({','.join(['?']*len(t_exact))})")
        tag_params.extend(t_exact)
    for p in tags_like:
        tag_expr_parts.append("LOWER(h.hashtag) LIKE ?")
        tag_params.append(p.lower())

    # Comment conditions (substring for Group_comment; raw LIKE for Group_likecomment)
    cmt_expr_parts, cmt_params = [], []
    for t in comment_terms:
        cmt_expr_parts.append("LOWER(c.comment) LIKE ?")
        cmt_params.append(f"%{t.lower()}%")
    for p in comment_like:
        cmt_expr_parts.append("LOWER(c.comment) LIKE ?")
        cmt_params.append(p.lower())

    if not tag_expr_parts and not cmt_expr_parts:
        # Safety: require at least one of tags or comments to define the group
        raise SystemExit("No tag/comment filters provided in group_definition.csv (nothing to select).")

    #compose final predicate: EXISTS(tag match) OR (comment match)
    tag_exists_sql = ""
    if tag_expr_parts:
        tag_exists_sql = "EXISTS (SELECT 1 FROM changeset_hashtags h WHERE h.changeset_id = c.changeset_id AND (" + " OR ".join(tag_expr_parts) + "))"
    comment_sql = ""
    if cmt_expr_parts:
        comment_sql = "(" + " OR ".join(cmt_expr_parts) + ")"

    any_match_sql = []
    if tag_exists_sql: any_match_sql.append(tag_exists_sql)
    if comment_sql:    any_match_sql.append(comment_sql)
    any_match = " OR ".join(any_match_sql)

    sql = f"""
        SELECT LOWER(c.user) AS user, COUNT(*) AS n
        FROM changesets c
        {' '.join(base_where)}
          AND ( {any_match} )
        GROUP BY user
        ORDER BY n DESC
        {('LIMIT ' + str(top_active)) if top_active else ''}
    """

    all_params = params + tag_params + cmt_params

    con = duckdb.connect(args.db, read_only=True)
    try:
        users = con.execute(sql, all_params).df()
    finally:
        con.close()

    # Write only a single username column
    out = (
        users["user"]
        .astype(str)
        .str.strip()
        .replace({"": None})
        .dropna()
        .drop_duplicates()
        .sort_values()
        .rename("username")
        .to_frame()
        .reset_index(drop=True)
    )
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    out.to_csv(args.out, index=False)
    print(f"Wrote {len(out)} usernames to {args.out}")

if __name__ == "__main__":
    main()
