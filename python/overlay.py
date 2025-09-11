#overlay.py
from __future__ import annotations
import os
import pandas as pd
from typing import Iterable, Optional, Tuple, Union
import duckdb
import importlib.util

def _load_queries_module(queries_path: str):
    spec = importlib.util.spec_from_file_location("queries", queries_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import queries.py at {queries_path}.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def _ensure_list(x: Optional[Union[str, int, Iterable]]) -> list:
    if x is None:
        return []
    if isinstance(x, (str, int)):
        return [x]
    return [i for i in x if i is not None]

def build_overlay(
    *,
    db_path: str,
    queries_path: str = "python/queries.py",
    group_users_csv: str = "data/metadata/group_users.csv",
    group_info_csv: str = "data/metadata/group_info.csv",
    out_dir: str = "data/db_overlay",
    usernames: Optional[Iterable[str]] = None,
    hashtags: Optional[Iterable[str]] = None,
    start: Optional[str] = None,
    end: Optional[str] = None,
    bbox: Optional[Tuple[float, float, float, float]] = None,  # (min_lat,min_lon,max_lat,max_lon)
) -> None:
    """
    Query DuckDB for the current group and write overlay CSVs into out_dir:
      - changesets_subset.csv
      - changesets_tags_subset.csv
      - contributions_summary_subset.csv
      - user_hashtag_pairs.csv
      - _overlay_log.txt
    """

    #load the helper functions
    queries = _load_queries_module(queries_path)

    #usernames as union of CSV and provided param
    if not os.path.exists(group_users_csv):
        raise RuntimeError(
            f"Expected group users at {group_users_csv} with column 'username' or 'user'."
        )
    uinfo = pd.read_csv(group_users_csv)
    name_col = "username" if "username" in uinfo.columns else ("user" if "user" in uinfo.columns else None)
    if name_col is None:
        raise RuntimeError("group_users.csv must have a 'username' or 'user' column.")
    csv_usernames = [str(x).strip() for x in uinfo[name_col].dropna().tolist() if str(x).strip()]

    param_usernames = [u.strip() for u in _ensure_list(usernames) if str(u).strip()]
    all_usernames = sorted(set(csv_usernames) | set(param_usernames))

    if not all_usernames:
        raise RuntimeError("No usernames found in group_users.csv or params.")

    #optional start and end from group_info.csv, otherwise overridden 
    if os.path.exists(group_info_csv):
        try:
            gdf = pd.read_csv(group_info_csv)
            if start is None:
                for col in ("start","start_date","from"):
                    if col in gdf.columns and pd.notna(gdf[col].iloc[0]):
                        start = str(gdf[col].iloc[0])
                        break
            if end is None:
                for col in ("end","end_date","to"):
                    if col in gdf.columns and pd.notna(gdf[col].iloc[0]):
                        end = str(gdf[col].iloc[0])
                        break
        except Exception:
            pass

    # connect to the database
    con = queries.connect(db_path)
    try:
        # base changesets for selected users with optional date/bbox/hashtags
        where = ["WHERE 1=1"]
        params: list = []

        #always filter users
        placeholders_users = ",".join(["?"] * len(all_usernames))
        where.append(f"AND c.user IN ({placeholders_users})")
        params.extend(all_usernames)

        # dates
        if start:
            where.append("AND c.created >= ?")
            params.append(pd.to_datetime(start))
        if end:
            where.append("AND c.created <= ?")
            params.append(pd.to_datetime(end))

        #bbox on centroid
        if bbox:
            min_lat, min_lon, max_lat, max_lon = bbox
            where.append("AND ( (c.min_lat + c.max_lat)/2.0 ) BETWEEN ? AND ?")
            where.append("AND ( (c.min_lon + c.max_lon)/2.0 ) BETWEEN ? AND ?")
            params.extend([min_lat, max_lat, min_lon, max_lon])

        #hashtags filter (restricts which changesets we fetch)
        join_hashtags = ""
        if hashtags:
            tags = [h.strip() for h in hashtags if h and str(h).strip()]
            if tags:
                join_hashtags = "JOIN changeset_hashtags h ON h.changeset_id = c.changeset_id"
                placeholders_tags = ",".join(["?"] * len(tags))
                where.append(f"AND h.hashtag IN ({placeholders_tags})")
                params.extend(tags)

        sql = f"""
        SELECT
          c.changeset_id AS id,
          c.user,
          c.uid,
          c.created            AS created_at,
          c.comment,
          c.created_by,
          c.imagery_used,
          c.source,
          c.min_lat, c.min_lon, c.max_lat, c.max_lon
        FROM changesets c
        {join_hashtags}
        {' '.join(where)}
        """
        changesets = con.execute(sql, params).df()

        #attach hashtags column
        if not changesets.empty:
            sid = tuple(changesets["id"].tolist())
            tag_params = list(sid)
            tag_sql = f"""
                SELECT changeset_id AS id, hashtag
                FROM changeset_hashtags
                WHERE changeset_id IN ({','.join(['?']*len(sid))})
            """
            tags_df = con.execute(tag_sql, tag_params).df()
            if not tags_df.empty:
                h = (
                    tags_df.groupby("id")["hashtag"]
                    .apply(lambda s: ";".join(sorted({x.strip() for x in s if x and str(x).strip()})))
                    .reset_index(name="hashtags")
                )
                changesets = changesets.merge(h, on="id", how="left")
            else:
                changesets["hashtags"] = ""
        else:
            changesets = pd.DataFrame(
                columns=[
                    "id","user","uid","created_at","comment","created_by","imagery_used",
                    "source","min_lat","min_lon","max_lat","max_lon","hashtags"
                ]
            )

        #write the overlay outputs
        os.makedirs(out_dir, exist_ok=True)
        changesets.to_csv(os.path.join(out_dir, "changesets_subset.csv"), index=False)

        #explode the hashtags into changesets_tags_subset.csv
        tags_rows = []
        for cid, s in zip(changesets["id"], changesets["hashtags"].fillna("")):
            if not s:
                continue
            for t in [x.strip() for x in s.split(";") if x.strip()]:
                tags_rows.append((cid, "hashtags", t))
        pd.DataFrame(tags_rows, columns=["changeset","key","value"]).to_csv(
            os.path.join(out_dir, "changesets_tags_subset.csv"), index=False
        )

        #minimal contributions summary
        summary = (
            changesets.groupby("user", dropna=False)
            .size()
            .reset_index(name="map_changesets")
        )
        for col in ["account_age","comments","diary","map_notes","traces","wiki_edits"]:
            summary[col] = 0
        summary.to_csv(os.path.join(out_dir, "contributions_summary_subset.csv"), index=False)

        #user-hashtag pairs
        pairs = []
        for user, s in zip(changesets["user"], changesets["hashtags"].fillna("")):
            if not s:
                continue
            for t in [x.strip() for x in s.split(";") if x.strip()]:
                pairs.append((user, t))
        pd.DataFrame(pairs, columns=["user","hashtag"]).to_csv(
            os.path.join(out_dir, "user_hashtag_pairs.csv"), index=False
        )

        with open(os.path.join(out_dir, "_overlay_log.txt"), "w") as f:
            f.write(
                f"Overlay written\n"
                f"- users: {len(all_usernames)}\n"
                f"- changesets: {len(changesets)}\n"
                f"- user-hashtag pairs: {len(pairs)}\n"
                f"- filters: start={start}, end={end}, bbox={bbox}, hashtags={hashtags}\n"
                f"- db_path: {db_path}\n"
            )
    finally:
        con.close()
