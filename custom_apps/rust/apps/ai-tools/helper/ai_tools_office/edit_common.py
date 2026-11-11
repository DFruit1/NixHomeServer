"""Deterministic table rules shared by the native OOXML editors."""
from __future__ import annotations

import datetime
import decimal
import hashlib
import re

MAX_ROWS = 5000
MAX_COLUMNS = 64
MAX_CHANGED_CELLS = 100000


def revision(document):
    return hashlib.sha256(document).hexdigest()


def pin(document, expected):
    if not isinstance(expected, str) or not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise ValueError("source_revision must be the SHA-256 revision returned by office_inspect")
    if revision(document) != expected:
        raise ValueError("source changed since inspection; inspect it again before editing")


def fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise ValueError("expected fields: " + ", ".join(required) + "; optional: " + ", ".join(optional))


def integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{label} must be an integer from {low} to {high}")
    return value


def scalar(value):
    # Strings are always literals here. Formula creation is a separate, typed
    # cell operation, never inferred from imported text beginning with '='.
    if value is None or type(value) is bool:
        return value
    if type(value) in (int, float):
        if not decimal.Decimal(str(value)).is_finite() or abs(value) > 2**53:
            raise ValueError("number loses precision; supply it as literal text")
        return value
    if not isinstance(value, str) or len(value) > 32767:
        raise ValueError("cell values must be scalars with at most 32767 text characters")
    if any(ord(c) < 32 and c not in "\t\n\r" for c in value):
        raise ValueError("cell text contains unsupported control characters")
    return value


def matrix(rows, width):
    if not isinstance(rows, list) or not 1 <= len(rows) <= 500:
        raise ValueError("supply 1–500 rows per operation")
    if any(not isinstance(row, list) or len(row) != width for row in rows):
        raise ValueError(f"each row must contain exactly {width} cells; map columns explicitly")
    return [[scalar(v) for v in row] for row in rows]


def text(value):
    if value is None:
        return ""
    if type(value) is bool:
        return "true" if value else "false"
    return str(value)


def column(value, headers, width):
    if type(value) is int:
        return integer(value, 1, width, "column") - 1
    if not isinstance(value, str) or not value.strip():
        raise ValueError("column must be a 1-based index or unique header")
    matches = [i for i, h in enumerate(headers) if text(h).strip().casefold() == value.strip().casefold()]
    if len(matches) != 1:
        raise ValueError(f"header {value!r} is missing or ambiguous; use an inspected column index")
    return matches[0]


def permutation(rows, headers, keys):
    if not isinstance(keys, list) or not 1 <= len(keys) <= 4:
        raise ValueError("sort needs 1–4 keys, in priority order")
    order = list(range(len(rows)))
    width = len(headers)
    for key in reversed(keys):
        fields(key, ("column",), ("direction", "kind"))
        index = column(key["column"], headers, width)
        direction, kind = key.get("direction", "ascending"), key.get("kind", "auto")
        if direction not in ("ascending", "descending") or kind not in ("auto", "text", "number", "date"):
            raise ValueError("use ascending/descending and auto/text/number/date")
        values = [row[index] for row in rows if row[index] is not None and row[index] != ""]
        if any(isinstance(v, dict) for v in values):
            raise ValueError("formula cells cannot be sort keys; cached results may be stale")
        if kind == "auto":
            if all(type(v) in (int, float) for v in values):
                kind = "number"
            elif all(isinstance(v, str) for v in values):
                kind = "text"
            else:
                raise ValueError("sort key has mixed types; choose an explicit text/number/date interpretation")
        def converted(row_index):
            value = rows[row_index][index]
            if kind == "text":
                return text(value).casefold()
            if kind == "date":
                if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                    raise ValueError("date sorting requires explicit ISO YYYY-MM-DD values; do not guess a locale")
                return datetime.date.fromisoformat(value)
            try:
                result = decimal.Decimal(text(value))
            except decimal.InvalidOperation:
                raise ValueError("numeric sort key is not a plain number; do not guess currency or units") from None
            if not result.is_finite():
                raise ValueError("numeric sort key is not finite")
            return result
        present = [i for i in order if rows[i][index] is not None and rows[i][index] != ""]
        missing = [i for i in order if rows[i][index] is None or rows[i][index] == ""]
        order = sorted(present, key=converted, reverse=direction == "descending") + missing
    return order


def mapped_rows(source_headers, source_rows, target_headers, mapping=None):
    if not source_headers or not target_headers:
        raise ValueError("import requires explicit source/destination headers")
    if mapping is None:
        # A missing target column becomes blank (or its calculated formula).
        # Every source column must match exactly, with no implicit data loss.
        pairs = [(column(h, target_headers, len(target_headers)), i, "preserve") for i, h in enumerate(source_headers)]
    else:
        if not isinstance(mapping, list) or not mapping:
            raise ValueError("column_map must be a nonempty array of {source,target}")
        pairs = []
        for pair in mapping:
            fields(pair, ("source", "target"), ("kind",))
            kind = pair.get("kind", "preserve")
            if kind not in ("preserve", "text", "number"):
                raise ValueError("column_map kind must be preserve, text or number")
            pairs.append((column(pair["target"], target_headers, len(target_headers)), column(pair["source"], source_headers, len(source_headers)), kind))
    if len({p[0] for p in pairs}) != len(pairs) or len({p[1] for p in pairs}) != len(pairs):
        raise ValueError("column mapping duplicates a source or destination column")
    if set(p[1] for p in pairs) != set(range(len(source_headers))):
        raise ValueError("mapping must retain every selected source column; inspect a narrower source range to omit columns intentionally")
    result = []
    for row in source_rows:
        target = [None] * len(target_headers)
        for dst, src, kind in pairs:
            value = scalar(row[src])
            if kind == "text" and value is not None:
                value = text(value)
            if kind == "number" and value not in (None, ""):
                if not re.fullmatch(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?", text(value)):
                    raise ValueError("numeric import requires plain decimals without leading-zero identifiers, currency, units or guessed locale")
                number = decimal.Decimal(text(value))
                value = int(number) if number == number.to_integral_value() else float(number)
                if decimal.Decimal(str(value)) != number:
                    raise ValueError("numeric import loses precision; preserve the source as text")
                value = scalar(value)
            target[dst] = value
        result.append(target)
    return result
