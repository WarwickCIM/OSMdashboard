# queries.py

# How to use this file:
# ------------------------------------------------------------
# Purpose: Convenience wrappers around DuckDB SQL to query the OSM Changeset
#   Explorer database. All functions return a pandas.DataFrame and many
#   can also write results to CSV with the to_csv parameter.
#
# Database: By default we open "osm_changesets.duckdb" in read-only mode.
#   If your DB file has a different path, pass db_path="...".
#
# Date arguments: 'start_date' / 'end_date' accept strings (such as "2021-01-01"), pandas/NumPy datetimes, or Python datetime objects.
#
# Bounding boxes (bbox): Pass as a tuple: (min_lat, min_lon, max_lat, max_lon).
#   We compute changeset centroids from the changesets table for
#   spatial filters.
#
# Lists vs single values: Parameters that accept multiple values (such as hashtags, usernames,
#   uids) can be passed as a single value or a list/iterable.
#   Internally they’re normalized to lists.
#
# Ordering and limiting: Most functions accept 'order_by' (SQL ORDER BY snippet) and 'limit'
#   (int) so you can shape the result size and sort order.
#
# CSV export: Any function with to_csv="path.csv" will also write results out.
#
# Typical usage:
#   You can write something like this in an external file: 
#   from queries import get_users_for_hashtag
#   df = get_users_for_hashtag("#mapcork", start_date="2023-01-01", end_date="2023-12-31")
#   print(df.head())
#   Or run this file by changing the lines at the very end
#
# Tables these functions expect
# - changesets(changeset_id, created, uid, user, min_lat, min_lon, max_lat, max_lon, ...)
# - changeset_hashtags(changeset_id, created, uid, user, hashtag, hashtag_raw)
# - users(uid, latest_username, first_seen, last_seen, changesets_count, ...)
# - user_points(uid, user, created, lat, lon)
#
# Please note there are approximately 170 millions lines in the main table of this database. It may take up to 5 seconds to execute queries.
# -------------------------------------------------------------------------------------------------------------


# Find here some convenience queries for the OSM Changeset Database Explorer
from __future__ import annotations
import duckdb
import pandas as pd
from typing import Iterable, Optional, Tuple, Union
import os
from datetime import datetime
# os.makedirs("QueryResults", exist_ok=True)

# #If you have a different name for your database, plesae change it here
DB_PATH_DEFAULT = "osm_changesets.duckdb"

# Helper functions to insure inputs are in list formats
def _ensure_list(x: Optional[Union[str, int, Iterable]]) -> Optional[list]:
    if x is None:
        return None
    if isinstance(x, (str, int)):
        return [x]
    return list(x)

# Add an 'IN' clause to SQL queries if necessary
def _add_in_clause(sql_parts, params, col, values, cast: Optional[str] = None):
    """
    Add "AND col IN (?,?,?)" to WHERE and extend params.
    Optionally cast: e.g. cast='::BIGINT' -> "CAST(col AS BIGINT) IN (...)"
    """
    if not values:
        return
    placeholders = ",".join(["?"] * len(values))
    if cast:
        sql_parts.append(f"AND CAST({col} AS {cast}) IN ({placeholders})")
    else:
        sql_parts.append(f"AND {col} IN ({placeholders})")
    params.extend(values)

#Adds date range component to SQL queries
def _add_date_range(sql_parts, params, col, start_date, end_date):
    if start_date is not None:
        sql_parts.append(f"AND {col} >= ?")
        params.append(pd.to_datetime(start_date))
    if end_date is not None:
        sql_parts.append(f"AND {col} <= ?")
        params.append(pd.to_datetime(end_date))

#Adds bounding box component to SQL queries in the form of latitude and longitude boundaries
def _add_bbox(sql_parts, params, lat_col, lon_col, bbox: Optional[Tuple[float,float,float,float]]):
    if not bbox:
        return
    min_lat, min_lon, max_lat, max_lon = bbox
    sql_parts.append(f"AND {lat_col} BETWEEN ? AND ?")
    sql_parts.append(f"AND {lon_col} BETWEEN ? AND ?")
    params.extend([min_lat, max_lat, min_lon, max_lon])

def _order_and_limit(order_by: Optional[str], limit: Optional[int]) -> str:
    ob = f" ORDER BY {order_by} " if order_by else ""
    lm = f" LIMIT {int(limit)} " if (limit is not None) else ""
    return ob + lm

#Connects to the database
def connect(db_path: str = DB_PATH_DEFAULT):
    """Return a DuckDB connection (caller can reuse it and close when done)."""
    return duckdb.connect(db_path, read_only=True)


#These are the queries. Additional filters (above) are added to these queries depending on the arguments given

def get_users_for_hashtag(
    hashtag: Union[str, Iterable[str]],
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    bbox: Optional[Tuple[float,float,float,float]] = None,  # (min_lat, min_lon, max_lat, max_lon)
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = None,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    
    #This returns users who used a given hashtag(s), optionally filtered by a date range and bounding box.
    #Counts per user are aggregated.
    hashtags = _ensure_list(hashtag)
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []

        # join to changesets for bbox + created
        sql = """
        SELECT
          h.uid,
          h.user,
          COUNT(*) AS n,
          MIN(h.created) AS first_seen,
          MAX(h.created) AS last_seen
        FROM changeset_hashtags h
        JOIN changesets c USING (changeset_id)
        """

        _add_in_clause(where, params, "h.hashtag", hashtags, cast=None)
        _add_date_range(where, params, "h.created", start_date, end_date)
        _add_bbox(where, params, "(c.min_lat + c.max_lat)/2.0", "(c.min_lon + c.max_lon)/2.0", bbox)

        sql += " " + " ".join(where) + " GROUP BY h.uid, h.user "
        sql += _order_and_limit(order_by, limit)

        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def get_hashtags_for_users(
    *,
    usernames: Optional[Union[str, Iterable[str]]] = None,
    uids: Optional[Union[int, Iterable[int]]] = None,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    bbox: Optional[Tuple[float,float,float,float]] = None,
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = None,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    #This returns hashtags given by specified user(s). The user can be specified by username or userid and optionally filtered by a date range and bounding box.
    #Counts per hashtag are aggregated.
    usernames = _ensure_list(usernames)
    uids = _ensure_list(uids)
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []

        sql = """
        SELECT
          h.hashtag,
          COUNT(*) AS n,
          MIN(h.created) AS first_seen,
          MAX(h.created) AS last_seen
        FROM changeset_hashtags h
        JOIN changesets c USING (changeset_id)
        """

        if uids:
            _add_in_clause(where, params, "h.uid", uids, cast="BIGINT")
        if usernames:
            _add_in_clause(where, params, "h.user", usernames, cast=None)
        _add_date_range(where, params, "h.created", start_date, end_date)
        _add_bbox(where, params, "(c.min_lat + c.max_lat)/2.0", "(c.min_lon + c.max_lon)/2.0", bbox)

        sql += " " + " ".join(where) + " GROUP BY h.hashtag "
        sql += _order_and_limit(order_by, limit)

        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()

def get_all_users(
    *,
    order_by: Optional[str] = "changesets_count DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """List users from the materialized `users` table."""
    con = connect(db_path)
    try:
        sql = "SELECT * FROM users " + _order_and_limit(order_by, limit)
        df = con.execute(sql).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()

def get_all_hashtags(
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    bbox: Optional[Tuple[float,float,float,float]] = None,
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """Global hashtag counts with optional date/bbox filters."""
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []
        sql = """
        SELECT
          h.hashtag,
          COUNT(*) AS n,
          MIN(h.created) AS first_seen,
          MAX(h.created) AS last_seen
        FROM changeset_hashtags h
        JOIN changesets c USING (changeset_id)
        """
        _add_date_range(where, params, "h.created", start_date, end_date)
        _add_bbox(where, params, "(c.min_lat + c.max_lat)/2.0", "(c.min_lon + c.max_lon)/2.0", bbox)

        sql += " " + " ".join(where) + " GROUP BY h.hashtag "
        sql += _order_and_limit(order_by, limit)

        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def get_hashtags_between_dates(
    start_date,
    end_date,
    *,
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """Alias for get_all_hashtags with only date filters."""
    return get_all_hashtags(
        start_date=start_date, end_date=end_date,
        order_by=order_by, limit=limit, db_path=db_path, to_csv=to_csv
    )

def get_users_in_bbox(
    bbox: Tuple[float,float,float,float],
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    order_by: Optional[str] = "changesets_in_bbox DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """
    Users who made changes inside a bbox (via user_points view).
    Counts points (i.e., changesets with bbox centroid inside).
    """
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []
        _add_date_range(where, params, "created", start_date, end_date)
        min_lat, min_lon, max_lat, max_lon = bbox
        where.append("AND lat BETWEEN ? AND ?")
        where.append("AND lon BETWEEN ? AND ?")
        params.extend([min_lat, max_lat, min_lon, max_lon])

        sql = f"""
        SELECT uid, user AS username, COUNT(*) AS changesets_in_bbox,
               MIN(created) AS first_seen, MAX(created) AS last_seen
        FROM user_points
        {' '.join(where)}
        GROUP BY uid, username
        """ + _order_and_limit(order_by, limit)

        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def get_hashtags_in_bbox(
    bbox: Tuple[float,float,float,float],
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """Hashtag usage within a bbox."""
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []
        _add_date_range(where, params, "h.created", start_date, end_date)
        # join to changesets for centroid bbox
        min_lat, min_lon, max_lat, max_lon = bbox
        where.append("AND ( (c.min_lat + c.max_lat)/2.0 ) BETWEEN ? AND ?")
        where.append("AND ( (c.min_lon + c.max_lon)/2.0 ) BETWEEN ? AND ?")
        params.extend([min_lat, max_lat, min_lon, max_lon])

        sql = """
        SELECT h.hashtag, COUNT(*) AS n
        FROM changeset_hashtags h
        JOIN changesets c USING (changeset_id)
        """ + " ".join(where) + " GROUP BY h.hashtag " + _order_and_limit(order_by, limit)

        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def get_hashtags_for_users_in_bbox(
    *,
    usernames: Optional[Union[str, Iterable[str]]] = None,
    uids: Optional[Union[int, Iterable[int]]] = None,
    bbox: Tuple[float,float,float,float],
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """Hashtags used by specific users inside a bbox and optional date range."""
    usernames = _ensure_list(usernames)
    uids = _ensure_list(uids)
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []

        sql = """
        SELECT h.hashtag, COUNT(*) AS n
        FROM changeset_hashtags h
        JOIN changesets c USING (changeset_id)
        """
        if uids:
            _add_in_clause(where, params, "h.uid", uids, cast="BIGINT")
        if usernames:
            _add_in_clause(where, params, "h.user", usernames, cast=None)

        _add_date_range(where, params, "h.created", start_date, end_date)

        min_lat, min_lon, max_lat, max_lon = bbox
        where.append("AND ( (c.min_lat + c.max_lat)/2.0 ) BETWEEN ? AND ?")
        where.append("AND ( (c.min_lon + c.max_lon)/2.0 ) BETWEEN ? AND ?")
        params.extend([min_lat, max_lat, min_lon, max_lon])

        sql += " " + " ".join(where) + " GROUP BY h.hashtag " + _order_and_limit(order_by, limit)
        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def get_users_for_hashtag_in_bbox(
    hashtag: Union[str, Iterable[str]],
    bbox: Tuple[float,float,float,float],
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    order_by: Optional[str] = "n DESC",
    limit: Optional[int] = 1000,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """Users who used a hashtag inside a bbox."""
    return get_users_for_hashtag(
        hashtag,
        start_date=start_date,
        end_date=end_date,
        bbox=bbox,
        order_by=order_by,
        limit=limit,
        db_path=db_path,
        to_csv=to_csv,
    )


def get_user_points(
    *,
    usernames: Optional[Union[str, Iterable[str]]] = None,
    uids: Optional[Union[int, Iterable[int]]] = None,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """All lat/lon centroids (user_points) for the given users, optional date filter."""
    usernames = _ensure_list(usernames)
    uids = _ensure_list(uids)
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []
        if uids:
            _add_in_clause(where, params, "uid", uids, cast="BIGINT")
        if usernames:
            _add_in_clause(where, params, "user", usernames, cast=None)
        _add_date_range(where, params, "created", start_date, end_date)

        sql = "SELECT uid, user, created, lat, lon FROM user_points " + " ".join(where)
        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def get_hashtag_points(
    hashtag: Union[str, Iterable[str]],
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    db_path: str = DB_PATH_DEFAULT,
    to_csv: Optional[str] = None,
) -> pd.DataFrame:
    """All lat/lon centroids for changesets that used the given hashtag(s)."""
    hashtags = _ensure_list(hashtag)
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []
        _add_in_clause(where, params, "h.hashtag", hashtags, cast=None)
        _add_date_range(where, params, "h.created", start_date, end_date)

        sql = """
        SELECT
          h.hashtag,
          h.created,
          (c.min_lat + c.max_lat)/2.0 AS lat,
          (c.min_lon + c.max_lon)/2.0 AS lon
        FROM changeset_hashtags h
        JOIN changesets c USING (changeset_id)
        """ + " ".join(where)

        df = con.execute(sql, params).df()
        if to_csv:
            df.to_csv(to_csv, index=False)
        return df
    finally:
        con.close()


def count_hashtag(
    hashtag: Union[str, Iterable[str]],
    *,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    db_path: str = DB_PATH_DEFAULT,
) -> pd.DataFrame:
    """Counts of one or more hashtags (optional date range)."""
    hashtags = _ensure_list(hashtag)
    con = connect(db_path)
    try:
        where = ["WHERE 1=1"]
        params = []
        _add_in_clause(where, params, "hashtag", hashtags, cast=None)
        _add_date_range(where, params, "created", start_date, end_date)
        sql = "SELECT hashtag, COUNT(*) AS n FROM changeset_hashtags " + " ".join(where) + " GROUP BY hashtag"
        return con.execute(sql, params).df()
    finally:
        con.close()


def count_user_changes(
    *,
    uids: Optional[Union[int, Iterable[int]]] = None,
    usernames: Optional[Union[str, Iterable[str]]] = None,
    start_date: Optional[Union[str, pd.Timestamp]] = None,
    end_date: Optional[Union[str, pd.Timestamp]] = None,
    db_path: str = DB_PATH_DEFAULT,
) -> pd.DataFrame:
    """Count changesets per user (optional date range)."""
    uids = _ensure_list(uids)
    usernames = _ensure_list(usernames)
    con = connect(db_path)
    try:
        where = ["WHERE uid IS NOT NULL"]
        params = []
        if uids:
            _add_in_clause(where, params, "uid", uids, cast="BIGINT")
        if usernames:
            _add_in_clause(where, params, "user", usernames, cast=None)
        _add_date_range(where, params, "created", start_date, end_date)

        sql = "SELECT uid, user, COUNT(*) AS changesets FROM changesets " + " ".join(where) + " GROUP BY uid, user"
        return con.execute(sql, params).df()
    finally:
        con.close()

def make_filename(prefix, start_date=None, end_date=None, bbox=None):
    """
    Build a CSV filename like:
    QueryResults/<prefix>_<start>_to_<end>_bbox_<minlat>_<minlon>_<maxlat>_<maxlon>_<YYYYMMDD>.csv
    Any missing parts (dates/bbox) are omitted.
    """
    date_str = ""
    if start_date and end_date:
        date_str = f"_{start_date}_to_{end_date}"
    elif start_date:
        date_str = f"_{start_date}"
    elif end_date:
        date_str = f"_{end_date}"

    bbox_str = ""
    if bbox:
        bbox_str = "_bbox_" + "_".join(map(str, bbox))

    timestamp = datetime.now().strftime("%Y%m%d")
    return f"QueryResults/{prefix}{date_str}{bbox_str}_{timestamp}.csv"


# ------------------------------------------------------------
# Usage Examples (You can copy/paste these into a separate file for convenience)
# ------------------------------------------------------------


# 1) Users who used a given hashtag (or list of hashtags)
# from queries import get_users_for_hashtag
# df = get_users_for_hashtag(
#     hashtag=["#mapcork", "#missingmaps"],
#     start_date="2022-01-01",
#     end_date="2022-12-31",
#     order_by="n DESC",
#     limit=50
# )
# df.to_csv(make_filename("users_for_hashtag", "2022-01-01", "2022-12-31"), index=False)

# 2) Hashtags used by specific users (by username and/or UID)
# from queries import get_hashtags_for_users
# df = get_hashtags_for_users(
#     usernames=["alice123", "bob_mapper"],
#     uids=[12345],
#     start_date="2023-01-01",
#     end_date="2023-06-30",
#     order_by="n DESC",
#     limit=100
# )
# df.to_csv(make_filename("hashtags_for_users", "2023-01-01", "2023-06-30"), index=False)

# 3) List all users (materialized stats in `users` table)
# from queries import get_all_users
# df = get_all_users(order_by="changesets_count DESC", limit=100)
# df.to_csv(make_filename("all_users"), index=False)

# 4) Global hashtag counts (optionally filtered by date & bbox)
# from queries import get_all_hashtags
# df = get_all_hashtags(
#     start_date="2021-01-01",
#     end_date="2021-12-31",
#     order_by="n DESC",
#     limit=200
# )
# df.to_csv(make_filename("all_hashtags", "2021-01-01", "2021-12-31"), index=False)

# 5) Hashtags between two dates (alias for #4 with only dates)
# from queries import get_hashtags_between_dates
# df = get_hashtags_between_dates(
#     "2020-01-01", "2020-12-31",
#     order_by="n DESC", limit=50
# )
# df.to_csv(make_filename("hashtags_between_dates", "2020-01-01", "2020-12-31"), index=False)

# 6) Users active inside a geographic bbox (using user_points)
# from queries import get_users_in_bbox
# bbox = (51.2, -0.5, 51.8, 0.3)  # (min_lat, min_lon, max_lat, max_lon)
# df = get_users_in_bbox(
#     bbox=bbox,
#     start_date="2024-01-01",
#     end_date="2024-03-31",
#     order_by="changesets_in_bbox DESC",
#     limit=25
# )
# df.to_csv(make_filename("users_in_bbox", "2024-01-01", "2024-03-31", bbox), index=False)

# 7) Hashtags used inside a bbox (global top tags in region)
# from queries import get_hashtags_in_bbox
# bbox = (40.4, -74.2, 41.0, -73.6)  # NYC-ish
# df = get_hashtags_in_bbox(
#     bbox=bbox,
#     start_date="2023-01-01",
#     end_date="2023-12-31",
#     order_by="n DESC",
#     limit=50
# )
# df.to_csv(make_filename("hashtags_in_bbox", "2023-01-01", "2023-12-31", bbox), index=False)

# 8) Hashtags used by specific users inside a bbox
# from queries import get_hashtags_for_users_in_bbox
# bbox = (48.7, 2.1, 49.1, 2.6)  # Paris-ish
# df = get_hashtags_for_users_in_bbox(
#     usernames=["paris_mapper"],
#     uids=None,
#     bbox=bbox,
#     start_date="2022-01-01",
#     end_date="2022-12-31",
#     order_by="n DESC",
#     limit=30
# )
# df.to_csv(make_filename("hashtags_for_users_in_bbox", "2022-01-01", "2022-12-31", bbox), index=False)

# 9) Users for a given hashtag restricted to a bbox
# from queries import get_users_for_hashtag_in_bbox
# bbox = (34.0, -118.7, 34.4, -118.1)  # LA-ish
# df = get_users_for_hashtag_in_bbox(
#     hashtag="#missingmaps",
#     bbox=bbox,
#     start_date="2021-06-01",
#     end_date="2021-12-31",
#     order_by="n DESC",
#     limit=50
# )
# df.to_csv(make_filename("users_for_hashtag_in_bbox", "2021-06-01", "2021-12-31", bbox), index=False)

# 10) All point centroids (user_points) for specific users
# from queries import get_user_points
# df = get_user_points(
#     usernames=["alice123"],
#     uids=[12345],
#     start_date="2023-05-01",
#     end_date="2023-06-01"
# )
# df.to_csv(make_filename("user_points", "2023-05-01", "2023-06-01"), index=False)

# 11) All point centroids for a hashtag or list of hashtags
# from queries import get_hashtag_points
# df = get_hashtag_points(
#     hashtag=["#mapcork", "#roads"],
#     start_date="2020-01-01",
#     end_date="2020-12-31"
# )
# df.to_csv(make_filename("hashtag_points", "2020-01-01", "2020-12-31"), index=False)

# 12) Count one or more hashtags (optional date range)
# from queries import count_hashtag
# df = count_hashtag(
#     hashtag=["#mapcork", "#buildings"],
#     start_date="2019-01-01",
#     end_date="2024-12-31"
# )
# df.to_csv(make_filename("count_hashtag", "2019-01-01", "2024-12-31"), index=False)

# 13) Count changesets per user (by uid and/or username)
# from queries import count_user_changes
# df = count_user_changes(
#     uids=[98765, 12345],
#     usernames=["alice123"],
#     start_date="2022-01-01",
#     end_date="2022-12-31"
# )
# df.to_csv(make_filename("count_user_changes", "2022-01-01", "2022-12-31"), index=False)
