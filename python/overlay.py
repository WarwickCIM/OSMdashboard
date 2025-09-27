from __future__ import annotations
import os
import importlib.util
from typing import Iterable, Optional, Tuple, Union, List
import duckdb
import pandas as pd


# ---------- helpers ----------------------------------------------------------

def _load_queries_module(queries_path: str):
    spec = importlib.util.spec_from_file_location("queries", queries_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import queries.py at {queries_path}.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[attr-defined]
    return module

def _ensure_list(x: Optional[Union[str, int, Iterable]]) -> List[str]:
    if x is None:
        return []
    if isinstance(x, (str, int)):
        return [str(x)]
    return [str(i) for i in x if i is not None]

def _abs(p: Optional[str]) -> Optional[str]:
    if p is None:
        return None
    return p if os.path.isabs(p) else os.path.abspath(os.path.join(os.getcwd(), p))

def _resolve_under_project(relpath: str) -> str:
    """
    Resolve a project-relative path like 'data/metadata/group_users.csv'.
    Prefer CWD, otherwise try relative to repo root (parent of this file).
    """
    candidate = _abs(relpath)
    if candidate and os.path.exists(candidate):
        return candidate
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    alt = os.path.join(repo_root, relpath)
    if os.path.exists(alt):
        return alt
    # last try: stay with candidate (even if missing) so errors are clear
    return candidate

# ---------- core -------------------------------------------------------------


def build_overlay(
    *,
    db_path: str,
    queries_path: str = "python/queries.py",
    group_users_csv: str = "data/metadata/group_users.csv",
    group_info_csv: str = "data/metadata/group_info.csv",
    out_dir: str = "data/db_overlay",
    usernames: Optional[Iterable[str]] = None,      # optional extras
    hashtags: Optional[Iterable[str]] = None,       # optional filter
    start: Optional[str] = None,                    # optional filter
    end: Optional[str] = None,                      # optional filter
    bbox: Optional[Tuple[float, float, float, float]] = None,  # (min_lat,min_lon,max_lat,max_lon)
    strict_group_only: bool = True,                 # ONLY users from group_users.csv
    include_all_group_users: bool = True,           # include zeros in summary
    use_group_info_dates: bool = False,             # only read dates from group_info if True
) -> None:
    """
    Query DuckDB for the current group and write overlay CSVs into out_dir:
      - changesets_subset.csv  (only for selected users)
      - changesets_tags_subset.csv (only hashtags exploded)
      - contributions_summary_subset.csv (one row per group user if include_all_group_users=True)
      - user_hashtag_pairs.csv
      - _overlay_log.txt
    """

    # normalize paths
    db_path        = _abs(db_path) or db_path
    queries_path   = _resolve_under_project(queries_path)
    group_users_csv= _resolve_under_project(group_users_csv)
    group_info_csv = _resolve_under_project(group_info_csv)
    out_dir        = _resolve_under_project(out_dir)

    # load queries module (provides .connect())
    queries = _load_queries_module(queries_path)

    # read group users (supports column name 'username' or 'user')
    if not os.path.exists(group_users_csv):
        raise RuntimeError(f"Expected group users at {group_users_csv} with column 'username' or 'user'.")
    uinfo = pd.read_csv(group_users_csv)
    name_col = "username" if "username" in uinfo.columns else ("user" if "user" in uinfo.columns else None)
    if name_col is None:
        raise RuntimeError("group_users.csv must have a 'username' or 'user' column.")

    csv_usernames = (
        uinfo[name_col]
        .astype(str)
        .str.strip()
        .replace({"": None})
        .dropna()
        .str.lower()   # case-insensitive matching
        .tolist()
    )

    # extra usernames param
    param_usernames = [u.strip().lower() for u in _ensure_list(usernames) if u.strip()] if usernames else []

    # decide target users
    target_users = sorted(set(csv_usernames)) if strict_group_only else sorted(set(csv_usernames) | set(param_usernames))
    if not target_users:
        raise RuntimeError("No usernames found (after normalization).")

    # optionally pull start/end from group_info.csv
    if use_group_info_dates and os.path.exists(group_info_csv):
        try:
            gdf = pd.read_csv(group_info_csv)
            if start is None:
                for col in ("start","start_date","from"):
                    if col in gdf.columns and pd.notna(gdf[col].iloc[0]):
                        start = str(gdf[col].iloc[0]); break
            if end is None:
                for col in ("end","end_date","to"):
                    if col in gdf.columns and pd.notna(gdf[col].iloc[0]):
                        end = str(gdf[col].iloc[0]); break
        except Exception:
            pass

    # connect
    con = queries.connect(db_path)
    try:
        # WHERE building (user filter always on)
        where = ["WHERE 1=1"]
        params: list = []

        #compare on lower(c.user) to avoid case issues
        placeholders_users = ",".join(["?"] * len(target_users))
        where.append(f"AND lower(c.user) IN ({placeholders_users})")
        params.extend(target_users)

        # dates
        if start:
            where.append("AND c.created >= ?")
            params.append(pd.to_datetime(start))
        if end:
            where.append("AND c.created <= ?")
            params.append(pd.to_datetime(end))

        # bbox on centroid
        if bbox:
            min_lat, min_lon, max_lat, max_lon = bbox
            where.append("AND ((c.min_lat + c.max_lat)/2.0) BETWEEN ? AND ?")
            where.append("AND ((c.min_lon + c.max_lon)/2.0) BETWEEN ? AND ?")
            params.extend([min_lat, max_lat, min_lon, max_lon])

        # optional hashtag filter
        join_hashtags = ""
        if hashtags:
            tags = [h.strip() for h in _ensure_list(hashtags) if h.strip()]
            if tags:
                join_hashtags = "JOIN changeset_hashtags h ON h.changeset_id = c.changeset_id"
                placeholders_tags = ",".join(["?"] * len(tags))
                where.append(f"AND h.hashtag IN ({placeholders_tags})")
                params.extend(tags)

        # fetch changesets for the group users
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

        # attach hashtags column from changeset_hashtags
        if not changesets.empty:
            sid = changesets["id"].tolist()
            tag_sql = f"""
                SELECT changeset_id AS id, hashtag
                FROM changeset_hashtags
                WHERE changeset_id IN ({','.join(['?']*len(sid))})
            """
            tags_df = con.execute(tag_sql, sid).df()
            if not tags_df.empty:
                h = (
                    tags_df.groupby("id")["hashtag"]
                    .apply(lambda s: ";".join(sorted({str(x).strip() for x in s if str(x).strip()})))
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

        # convenience lon/lat for centroids in R
        if not changesets.empty:
            changesets["lon"] = (changesets["min_lon"] + changesets["max_lon"]) / 2.0
            changesets["lat"] = (changesets["min_lat"] + changesets["max_lat"]) / 2.0

        # write overlay dir
        os.makedirs(out_dir, exist_ok=True)
        changesets.to_csv(os.path.join(out_dir, "changesets_subset.csv"), index=False)

        # explode hashtags -> changesets_tags_subset.csv (only key='hashtags')
        tags_rows = []
        for cid, s in zip(changesets.get("id", []), changesets.get("hashtags", pd.Series([], dtype=str)).fillna("")):
            if not s:
                continue
            for t in [x.strip() for x in s.split(";") if x.strip()]:
                tags_rows.append((cid, "hashtags", t))
        pd.DataFrame(tags_rows, columns=["changeset","key","value"]).to_csv(
            os.path.join(out_dir, "changesets_tags_subset.csv"), index=False
        )

        # build contributions summary
        # start with all group users (if include_all_group_users)
        base_users_df = pd.DataFrame({"user": [u for u in target_users]})
        if not changesets.empty:
            counts = changesets.groupby(changesets["user"].str.lower()).size().rename("map_changesets")
            # map back to original casing (lowercase join)
            base_users_df["map_changesets"] = base_users_df["user"].map(counts).fillna(0).astype(int)
        else:
            base_users_df["map_changesets"] = 0

        # add the other columns the dashboard expects (zeros for now)
        for col in ["account_age","comments","diary","map_notes","traces","wiki_edits"]:
            base_users_df[col] = 0

        base_users_df.to_csv(os.path.join(out_dir, "contributions_summary_subset.csv"), index=False)

        # user-hashtag pairs (only for those that actually had hashtags)
        pairs = []
        if not changesets.empty and "hashtags" in changesets.columns:
            for user, s in zip(changesets["user"], changesets["hashtags"].fillna("")):
                if not s:
                    continue
                for t in [x.strip() for x in s.split(";") if x.strip()]:
                    pairs.append((user, t))
        pd.DataFrame(pairs, columns=["user","hashtag"]).to_csv(
            os.path.join(out_dir, "user_hashtag_pairs.csv"), index=False
        )

        # log
        with open(os.path.join(out_dir, "_overlay_log.txt"), "w", encoding="utf-8") as f:
            f.write(
                "Overlay written\n"
                f"- users_from_group_csv: {len(csv_usernames)}\n"
                f"- users_param (ignored={strict_group_only}): {len(param_usernames)}\n"
                f"- target_users_used: {len(target_users)}\n"
                f"- changesets: {len(changesets)}\n"
                f"- user-hashtag pairs: {len(pairs)}\n"
                f"- filters: start={start}, end={end}, bbox={bbox}, hashtags={hashtags}\n"
                f"- db_path: {db_path}\n"
                f"- group_users_csv: {group_users_csv}\n"
            )

    finally:
        con.close()
