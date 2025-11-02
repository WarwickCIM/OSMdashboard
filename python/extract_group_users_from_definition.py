#!/usr/bin/env python3
from __future__ import annotations
import argparse, os, time, csv
from typing import Optional, Tuple, List
import pandas as pd
import duckdb

# --- helpers ---------------------------------------------------------

def _split_pipe(val) -> List[str]:
    if val is None or (isinstance(val, float) and pd.isna(val)): return []
    s = str(val).strip()
    if not s: return []
    return [x.strip() for x in s.split("|") if x.strip()]

def _parse_bbox(val) -> Optional[Tuple[float,float,float,float]]:
    if val is None or (isinstance(val, float) and pd.isna(val)): return None
    parts = [p.strip() for p in str(val).split(",")]
    if len(parts) != 4: return None
    mnlat, mnlon, mxlat, mxlon = map(float, parts)
    return (mnlat, mnlon, mxlat, mxlon)

# optional live validation (off by default)
def _head_ok_cached(user: str, cache_file: str, sleep_min: float, sleep_max: float) -> bool:
    try:
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        cache = {}
        if os.path.exists(cache_file):
            with open(cache_file, newline="", encoding="utf-8") as f:
                for r in csv.DictReader(f):
                    cache[r["username"]] = r["ok"] == "1"

        if user in cache:
            return cache[user]

        import random, urllib.request
        time.sleep(random.uniform(sleep_min, sleep_max))
        req = urllib.request.Request(f"https://www.openstreetmap.org/user/{user}", method="HEAD")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310
                ok = (200 <= resp.status < 400)
        except Exception:
            ok = False  # be strict on errors

        new = not os.path.exists(cache_file)
        with open(cache_file, "a", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["username","ok","ts"])
            w.writerow([user, "1" if ok else "0", int(time.time())])

        return ok
    except Exception:
        return True  #don't block on cache errors

# --- main -------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, help="Path to osm_changesets.duckdb")
    ap.add_argument("--group-def", required=True, help="Path to data/metadata/group_definition.csv")
    ap.add_argument("--out", default="data/metadata/group_users.csv", help="Output CSV (username only)")
    ap.add_argument("--max-users", type=int, default=None, help="Cap number of users (top N by activity)")
    ap.add_argument("--validate-live", action="store_true", help="Drop usernames that 404 on OSM website (polite, cached)")
    ap.add_argument("--sleep-min", type=float, default=0.6)
    ap.add_argument("--sleep-max", type=float, default=1.4)
    ap.add_argument("--valid-cache", default="data/processed/.user_valid_cache.csv")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    def write_empty_and_exit(msg: str):
        # Always write a CSV with just the header so R never fails on "no columns"
        pd.DataFrame(columns=["username"]).to_csv(args.out, index=False)
        print(msg)
        raise SystemExit(0)

    df = pd.read_csv(args.group_def)
    if df.empty:
        write_empty_and_exit("group_definition.csv is empty — wrote an empty group_users.csv")

    row = df.iloc[0]
    tags_exact    = _split_pipe(row.get("Group_tags"))
    tags_like     = _split_pipe(row.get("Group_liketags"))
    comment_terms = _split_pipe(row.get("Group_comment"))
    comment_like  = _split_pipe(row.get("Group_likecomment"))
    bbox          = _parse_bbox(row.get("Group_bbx"))
    start_date    = str(row.get("Group_startdate")).strip() if pd.notna(row.get("Group_startdate")) else None
    end_date      = str(row.get("Group_enddate")).strip() if pd.notna(row.get("Group_enddate")) else None

    top_active = None
    if "TopActive" in df.columns and pd.notna(row.get("TopActive")):
        try:
            t = int(row["TopActive"])
            if t > 0:
                top_active = t
        except Exception:
            pass

    # Build shared WHERE for date/bbox on changesets
    base_where = ["WHERE 1=1 AND c.uid IS NOT NULL"]
    params: List = []

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

    # Tag/Comment predicates
    tag_parts, tag_params = [], []
    t_exact = [t.lstrip("#").lower() for t in tags_exact]
    if t_exact:
        tag_parts.append(f"LOWER(h.hashtag) IN ({','.join(['?']*len(t_exact))})")
        tag_params.extend(t_exact)
    for p in tags_like:
        tag_parts.append("LOWER(h.hashtag) LIKE ?")
        tag_params.append(p.lower())

    c_parts, c_params = [], []
    for t in comment_terms:
        c_parts.append("LOWER(c.comment) LIKE ?")
        c_params.append(f"%{t.lower()}%")
    for p in comment_like:
        c_parts.append("LOWER(c.comment) LIKE ?")
        c_params.append(p.lower())

    con = duckdb.connect(args.db, read_only=True)

    try:
        # CASE A: no tag/comment filters → if TopActive provided, take global top users (respect date/bbox)
        if not tag_parts and not c_parts:
            if top_active is None and args.max_users is None:
                write_empty_and_exit("No tag/comment filters and no TopActive — wrote empty group_users.csv")

            sql = f"""
            WITH users_latest AS (
              SELECT uid, arg_max(user, created) AS latest_username
              FROM changesets
              WHERE uid IS NOT NULL AND user IS NOT NULL
              GROUP BY uid
            ),
            base AS (
              SELECT c.uid, COUNT(*) AS n
              FROM changesets c
              {' '.join(base_where)}
              GROUP BY c.uid
            )
            SELECT LOWER(u.latest_username) AS username, b.n
            FROM base b
            JOIN users_latest u USING (uid)
            WHERE u.latest_username IS NOT NULL
            ORDER BY b.n DESC
            {('LIMIT ' + str(int(args.max_users))) if args.max_users
              else (('LIMIT ' + str(int(top_active))) if top_active else '')}
            """
            users = con.execute(sql, params).df()

        # CASE B: tag/comment filters present
        else:
            tag_exists = ""
            if tag_parts:
                tag_exists = ("EXISTS (SELECT 1 FROM changeset_hashtags h "
                              "WHERE h.changeset_id = c.changeset_id AND (" + " OR ".join(tag_parts) + "))")
            comment_pred = "(" + " OR ".join(c_parts) + ")" if c_parts else ""
            any_match = " OR ".join([p for p in [tag_exists, comment_pred] if p])

            sql = f"""
            WITH users_latest AS (
              SELECT
                uid,
                arg_max(user, created) AS latest_username
              FROM changesets
              WHERE uid IS NOT NULL AND user IS NOT NULL
              GROUP BY uid
            ),
            base AS (
              SELECT c.uid, COUNT(*) AS n
              FROM changesets c
              {' '.join(base_where)}
                AND ( {any_match} )
              GROUP BY c.uid
            )
            SELECT LOWER(u.latest_username) AS username, b.n
            FROM base b
            JOIN users_latest u USING (uid)
            WHERE u.latest_username IS NOT NULL
            ORDER BY b.n DESC
            {('LIMIT ' + str(int(args.max_users))) if args.max_users
              else (('LIMIT ' + str(int(top_active))) if top_active else '')}
            """
            users = con.execute(sql, params + tag_params + c_params).df()

    finally:
        con.close()

    #Write just the username column -if empty, still write header
    out = (users["username"]
           .astype(str).str.strip()
           .replace({"": None}).dropna()
           .drop_duplicates().sort_values().to_frame())

    if out.empty:
        pd.DataFrame(columns=["username"]).to_csv(args.out, index=False)
        print("No users matched this group definition — wrote an empty group_users.csv")
        raise SystemExit(0)

    #optional live validation
    if args.validate_live:
        keep = []
        for u in out["username"]:
            if _head_ok_cached(u, args.valid_cache, args.sleep_min, args.sleep_max):
                keep.append(u)
        out = pd.DataFrame({"username": keep})

    out.to_csv(args.out, index=False)
    print(f"Wrote {len(out)} usernames to {args.out}")

if __name__ == "__main__":
    main()
