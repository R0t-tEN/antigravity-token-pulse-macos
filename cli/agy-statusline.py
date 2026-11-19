#!/usr/bin/env python3
# === TELEMETRY_MOD_CLI_STATUSLINE ===
"""
Antigravity CLI (agy) Statusline & Shared Token Ledger Sync for macOS.
Zero external dependencies (uses Python 3 standard library).
Syncs CLI session usage atomically into telemetry-activity-cache.json (v4 schema).
"""

import datetime
import json
import os
import random
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

FIXED_MAX_TOKENS = 1_000_000
SPEED_CACHE_PATH = Path(tempfile.gettempdir()) / "agy-cli-telemetry-cache.json"
NEEDLE_LSI = b"\x0flast_step_index\x12"

HEX_RE = re.compile(r"^[0-9a-f]{16,64}$", re.IGNORECASE)
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)
MODEL_PAREN_SUFFIX_RE = re.compile(
    r"\s*\((?:Extra\s+Low|Very\s+High|XHigh|High|Medium|Low|Max|Thinking|Fast|Slow|Standard|Preview|Experimental|MaaS|\d+(?:\.\d+)?\s*[KM](?:\s*context)?)\)\s*$",
    re.IGNORECASE,
)
MODEL_SLUG_SUFFIX_RE = re.compile(
    r"-(?:maas|extra[-_]low|very[-_]high|xhigh|high|medium|low|max|thinking|tiered|trial|preview|exp|latest|control|worker-agy|orchestrator-g1-pro|1m|2m|128k|200k|256k|512k|1000k|\d{4}-\d{2}-\d{2}|\d{8}|[nhabc])$",
    re.IGNORECASE,
)
LOOKS_LIKE_SLUG_SUFFIX_RE = re.compile(
    r"-(?:maas|extra[-_]low|very[-_]high|xhigh|high|medium|low|max|thinking|tiered|trial|preview|exp|latest|control|worker-agy|orchestrator-g1-pro)$",
    re.IGNORECASE,
)
INTERNAL_SLUG_RE = re.compile(r"^[a-z][a-z0-9._/@-]+$", re.IGNORECASE)
DISPLAY_LABEL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 ._()\-+/]+$")
EFFORT_LABEL_RE = re.compile(
    r"\(\s*(Extra\s+Low|Very\s+High|XHigh|High|Medium|Low|Max)\s*\)(?:\s*\([^)]+\))*\s*$",
    re.IGNORECASE,
)
EFFORT_SLUG_RE = re.compile(r"-(extra[-_]low|very[-_]high|xhigh|high|medium|low|max)$", re.IGNORECASE)


def strip_bom(text) -> str:
    if text is None:
        return ""
    return str(text).lstrip("\ufeff")


def js_round(val: float) -> int:
    # Match JS Math.round(x) for non-negative numbers: floor(x + 0.5)
    return int(val + 0.5) if val >= 0 else -int((-val) + 0.5)


def get_cli_home_dir() -> Path:
    env_cli = os.environ.get("ANTIGRAVITY_CLI_HOME", "").strip()
    if env_cli:
        return Path(os.path.expanduser(env_cli)).resolve()
    return Path.home() / ".gemini" / "antigravity-cli"


def get_activity_cache_path() -> Path:
    return Path.home() / ".gemini" / "telemetry-activity-cache.json"


def read_settings_model() -> str:
    try:
        settings_path = get_cli_home_dir() / "settings.json"
        if settings_path.is_file():
            raw = strip_bom(settings_path.read_text(encoding="utf-8")).strip()
            if raw:
                data = json.loads(raw)
                if isinstance(data, dict) and isinstance(data.get("model"), str):
                    return data["model"].strip()
    except Exception:
        pass
    return ""


def acquire_file_lock(lock_path: Path, timeout_sec: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        try:
            fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            try:
                os.write(fd, str(os.getpid()).encode("ascii"))
            finally:
                os.close(fd)
            return True
        except FileExistsError:
            try:
                st = lock_path.stat()
                if time.time() - st.st_mtime > 5.0:
                    lock_path.unlink(missing_ok=True)
                    continue
            except Exception:
                pass
        except OSError:
            return False
        time.sleep(0.012 + random.random() * 0.014)
    return False


def release_file_lock(lock_path: Path) -> None:
    try:
        lock_path.unlink(missing_ok=True)
    except Exception:
        pass


def atomic_write_text(target_path: Path, payload: str) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    rand = f"{random.randint(100000, 999999)}"
    tmp_path = target_path.with_name(f"{target_path.name}.{os.getpid()}.{int(time.time() * 1000)}.{rand}.tmp")
    try:
        tmp_path.write_text(payload, encoding="utf-8")
        os.replace(str(tmp_path), str(target_path))
    finally:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except Exception:
            pass


def format_compact_tokens(num) -> str:
    try:
        n = float(num)
    except (TypeError, ValueError):
        return "0"
    if not (n > 0):
        return "0"
    if n >= 1_000_000:
        s = f"{n / 1_000_000:.1f}"
        return (s[:-2] if s.endswith(".0") else s) + "M"
    if n >= 1_000:
        return f"{js_round(n / 1_000)}k"
    return str(js_round(n))


def get_ring_char(pct: int) -> str:
    if pct <= 0:
        return "○"
    if pct < 30:
        return "◔"
    if pct < 60:
        return "◑"
    if pct < 90:
        return "◕"
    return "●"


def normalize_path(p: str) -> str:
    if not isinstance(p, str):
        return ""
    trimmed = p.strip()
    if trimmed.startswith("file://"):
        try:
            parsed = urlparse(trimmed)
            return unquote(parsed.path)
        except Exception:
            return trimmed.replace("file://", "", 1)
    return trimmed


def is_hex_or_uuid(s: str) -> bool:
    return bool(HEX_RE.match(s) or UUID_RE.match(s))


def strip_model_paren_suffixes(raw: str) -> str:
    name = str(raw or "").strip()
    while True:
        nxt = MODEL_PAREN_SUFFIX_RE.sub("", name).strip()
        if nxt == name:
            break
        name = nxt
    return name


def normalize_model_slug(raw: str) -> str:
    s = strip_model_paren_suffixes(raw)
    if not s or is_hex_or_uuid(s):
        return ""
    s = re.sub(r"^(?:[a-z0-9._-]+/)+", "", s, flags=re.IGNORECASE)
    s = re.sub(r"@.*$", "", s).strip()
    if not s or is_hex_or_uuid(s):
        return ""
    if s.lower() == "gemini-pro-orchestrator-g1-pro":
        return "Gemini 4 Argon"
    while True:
        nxt = MODEL_SLUG_SUFFIX_RE.sub("", s)
        if nxt == s:
            break
        s = nxt
    s = re.sub(r"(\d)[-_](\d)", r"\1.\2", s)
    s = re.sub(r"(\d)[-_](\d)", r"\1.\2", s)
    parts = []
    for w in re.split(r"[-_]+", s):
        if not w:
            continue
        wl = w.lower()
        if wl == "gpt":
            parts.append("GPT")
        elif wl == "oss":
            parts.append("OSS")
        elif re.match(r"^\d+(?:\.\d+)?[bk]$", w, re.IGNORECASE):
            parts.append(w.upper())
        elif w[0].isdigit():
            parts.append(w)
        else:
            parts.append(w[0].upper() + w[1:])
    return " ".join(parts).strip()


def normalize_model_name(raw_display: str, raw_internal: str) -> str:
    d = str(raw_display or "").strip()
    if d and not is_hex_or_uuid(d):
        name = strip_model_paren_suffixes(d)
        looks_like_slug = bool(
            name
            and not re.search(r"\s", name)
            and (
                "/" in name
                or "@" in name
                or LOOKS_LIKE_SLUG_SUFFIX_RE.search(name)
                or (re.match(r"^[a-z0-9._-]+$", name) and "-" in name)
            )
        )
        if looks_like_slug:
            slug_res = normalize_model_slug(name)
            if slug_res:
                return slug_res
        name = re.sub(r"^(?:[a-z0-9._-]+/)+", "", name, flags=re.IGNORECASE)
        name = re.sub(r"@[^\s()]*$", "", name).strip()
        m = re.match(r"^Orchestrator\s*\(([^)]+)\)$", name, re.IGNORECASE)
        if m:
            name = "Gemini 4 " + m.group(1).strip()
        if name and not is_hex_or_uuid(name):
            return name
    intern = str(raw_internal or "").strip()
    if intern and not is_hex_or_uuid(intern):
        res = normalize_model_slug(intern)
        if res:
            return res
    return ""


def extract_conv_model_map(conv_db_path: str) -> dict:
    step_map = {}
    default_model = ""
    db_size = 0
    if not conv_db_path or not isinstance(conv_db_path, str):
        return {"stepMap": step_map, "sortedSteps": [], "defaultModel": default_model, "dbSize": db_size}

    chunk_size = 8 * 1024 * 1024
    margin = 700
    keep = margin * 2

    for file_path in (conv_db_path, f"{conv_db_path}-wal"):
        p = Path(file_path)
        try:
            if not p.is_file():
                continue
            fsize = p.stat().st_size
        except OSError:
            continue
        db_size += fsize
        if fsize <= 0 or fsize > 512 * 1024 * 1024:
            continue

        try:
            with p.open("rb") as fh:
                carry = b""
                file_pos = 0
                while file_pos < fsize:
                    new_bytes = fh.read(chunk_size)
                    if not new_bytes:
                        break
                    file_pos += len(new_bytes)
                    buf = carry + new_bytes
                    total_len = len(buf)
                    is_last = file_pos >= fsize
                    scan_end = total_len if is_last else max(0, total_len - margin)
                    offset = max(0, len(carry) - margin) if carry else 0
                    prev_lsi_end = offset

                    while offset < scan_end:
                        idx = buf.find(NEEDLE_LSI, offset, scan_end)
                        if idx == -1:
                            break
                        pos = idx + len(NEEDLE_LSI)
                        if pos < total_len:
                            vlen = buf[pos]
                            if 1 <= vlen <= 8 and pos + 1 + vlen <= total_len:
                                step_bytes = buf[pos + 1 : pos + 1 + vlen]
                                try:
                                    step_str = step_bytes.decode("latin1")
                                except Exception:
                                    step_str = ""
                                if step_str.isdigit():
                                    raw_internal = ""
                                    int_start = max(prev_lsi_end, idx - 650)
                                    for k in range(int_start, idx - 2):
                                        if buf[k] == 0x9A and buf[k + 1] == 0x01:
                                            mlen = buf[k + 2]
                                            if 4 <= mlen <= 120 and k + 3 + mlen <= idx:
                                                try:
                                                    s = buf[k + 3 : k + 3 + mlen].decode("utf-8")
                                                except UnicodeDecodeError:
                                                    s = ""
                                                if s and INTERNAL_SLUG_RE.match(s) and not is_hex_or_uuid(s):
                                                    raw_internal = s

                                    raw_display = ""
                                    next_idx = buf.find(NEEDLE_LSI, pos, total_len)
                                    win_end = min(total_len, idx + 650, next_idx if next_idx != -1 else total_len)
                                    for k in range(pos, win_end - 2):
                                        if buf[k] == 0xAA and buf[k + 1] == 0x01:
                                            dlen = buf[k + 2]
                                            if 4 <= dlen <= 120 and k + 3 + dlen <= win_end:
                                                try:
                                                    s = buf[k + 3 : k + 3 + dlen].decode("utf-8")
                                                except UnicodeDecodeError:
                                                    s = ""
                                                if s and DISPLAY_LABEL_RE.match(s) and not is_hex_or_uuid(s):
                                                    raw_display = s
                                                    break

                                    norm = normalize_model_name(raw_display, raw_internal)
                                    if norm:
                                        step_map[int(step_str)] = norm
                                        default_model = norm

                        prev_lsi_end = pos
                        offset = pos

                    if is_last:
                        break
                    carry = buf[-keep:] if total_len > keep else buf
        except OSError:
            continue

    sorted_steps = sorted(step_map.keys())
    return {"stepMap": step_map, "sortedSteps": sorted_steps, "defaultModel": default_model, "dbSize": db_size}


def resolve_step_model(step_idx: int, model_info: dict, fallback_model: str) -> str:
    if model_info and step_idx in model_info.get("stepMap", {}):
        return model_info["stepMap"][step_idx]
    steps = model_info.get("sortedSteps", []) if model_info else []
    if steps:
        if step_idx < steps[0]:
            return model_info["stepMap"][steps[0]]
        chosen = steps[0]
        for s in reversed(steps):
            if s <= step_idx:
                chosen = s
                break
        return model_info["stepMap"][chosen]
    fb = normalize_model_name(fallback_model, "") or str(fallback_model or "").strip()
    return (model_info.get("defaultModel") if model_info else "") or fb or "其他模型"


def is_conv_entry_newer(candidate, current) -> bool:
    if not isinstance(candidate, dict) or not isinstance(candidate.get("mtimeMs"), (int, float)):
        return False
    if not isinstance(current, dict) or not isinstance(current.get("mtimeMs"), (int, float)):
        return True
    if candidate["mtimeMs"] != current["mtimeMs"]:
        return candidate["mtimeMs"] > current["mtimeMs"]
    cand_size = int(candidate.get("size") or 0)
    cur_size = int(current.get("size") or 0)
    if cand_size != cur_size:
        return cand_size > cur_size
    return int(candidate.get("dbSize") or 0) > int(current.get("dbSize") or 0)


def resolve_transcript_path(raw_path: str, conv_id: str) -> str:
    normalized = normalize_path(raw_path)
    if normalized and os.path.isfile(normalized):
        return normalized
    if not conv_id or not re.match(r"^[a-zA-Z0-9_-]+$", conv_id):
        return ""
    cli_home = get_cli_home_dir()
    candidates = [
        cli_home / "brain" / conv_id / ".system_generated" / "logs" / "transcript.jsonl",
        Path.home() / ".gemini" / "antigravity" / "brain" / conv_id / ".system_generated" / "logs" / "transcript.jsonl",
    ]
    for c in candidates:
        if c.is_file():
            return str(c)
    return ""


def parse_iso_timestamp_ms(ts_str: str):
    if not ts_str or not isinstance(ts_str, str):
        return None
    s = ts_str.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp() * 1000.0
    except ValueError:
        return None


def to_local_day_key(ts_ms: float) -> str:
    dt = datetime.datetime.fromtimestamp(ts_ms / 1000.0).astimezone()
    return dt.strftime("%Y-%m-%d")


def add_daily_bucket(daily_buckets: dict, row: dict, in_tok: float, cache_tok: float, out_tok: float, fallback_ms: float, model_name: str) -> None:
    row_total = in_tok + cache_tok + out_tok
    if row_total <= 0:
        return
    ts_ms = parse_iso_timestamp_ms(row.get("created_at"))
    if ts_ms is None:
        ts_ms = fallback_ms
    day_key = to_local_day_key(ts_ms)
    if day_key not in daily_buckets:
        daily_buckets[day_key] = {"in": 0, "cache": 0, "out": 0, "total": 0, "steps": 0, "models": {}}
    bucket = daily_buckets[day_key]
    bucket["in"] += in_tok
    bucket["cache"] += cache_tok
    bucket["out"] += out_tok
    bucket["total"] += row_total
    bucket["steps"] += 1

    m_name = model_name or "其他模型"
    models = bucket["models"]
    if m_name not in models:
        models[m_name] = {"in": 0, "cache": 0, "out": 0, "total": 0, "steps": 0}
    models[m_name]["in"] += in_tok
    models[m_name]["cache"] += cache_tok
    models[m_name]["out"] += out_tok
    models[m_name]["total"] += row_total
    models[m_name]["steps"] += 1


def parse_transcript_stats(transcript_path: str, conv_id: str, fallback_model: str):
    try:
        if not transcript_path or not os.path.isfile(transcript_path):
            return None
        st = os.stat(transcript_path)
        stat_mtime_ms = st.st_mtime * 1000.0
        stat_size = st.st_size
        raw = strip_bom(Path(transcript_path).read_text(encoding="utf-8", errors="replace"))
        rows = []
        for line in raw.splitlines():
            clean = strip_bom(line).strip()
            if not clean:
                continue
            try:
                rows.append(json.loads(clean))
            except Exception:
                continue

        model_info = None
        if isinstance(conv_id, str) and re.match(r"^[a-zA-Z0-9_-]+$", conv_id):
            cli_home = get_cli_home_dir()
            cli_db = cli_home / "conversations" / f"{conv_id}.db"
            desktop_db = Path.home() / ".gemini" / "antigravity" / "conversations" / f"{conv_id}.db"
            has_cli = cli_db.is_file() or Path(f"{cli_db}-wal").is_file()
            has_desktop = desktop_db.is_file() or Path(f"{desktop_db}-wal").is_file()
            chosen_db = cli_db if has_cli else (desktop_db if has_desktop else cli_db)
            model_info = extract_conv_model_map(str(chosen_db))

        sum_in = 0.0
        sum_cache = 0.0
        sum_out = 0.0
        latest_step_tps = 0
        base_instruction_tokens = 16_000.0
        first_planner_seen = False
        latest_planner = None
        compacted_context_used = None
        daily_buckets = {}

        for i, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            rtype = row.get("type")
            if rtype == "PLANNER_RESPONSE":
                in_tok = float(row.get("input_tokens") or 0)
                cache_tok = float(row.get("cache_read_tokens") or 0)
                out_tok = float(row.get("output_tokens") or 0)
                if not first_planner_seen and (in_tok + cache_tok > 0):
                    first_planner_seen = True
                    base_instruction_tokens = min(25_000.0, in_tok + cache_tok)
                sum_in += in_tok
                sum_cache += cache_tok
                sum_out += out_tok
                step_idx = int(row.get("step_index") or 0)
                model_name = resolve_step_model(step_idx, model_info, fallback_model)
                add_daily_bucket(daily_buckets, row, in_tok, cache_tok, out_tok, stat_mtime_ms, model_name)

                t0 = parse_iso_timestamp_ms(row.get("created_at"))
                if t0 is not None and out_tok > 0:
                    next_row = rows[i + 1] if i + 1 < len(rows) else None
                    if isinstance(next_row, dict) and next_row.get("created_at") and next_row.get("type") != "USER_INPUT":
                        t1 = parse_iso_timestamp_ms(next_row.get("created_at")) or 0.0
                    elif i == len(rows) - 1:
                        t1 = stat_mtime_ms
                    else:
                        t1 = 0.0
                    if t1 > t0:
                        elapsed = (t1 - t0) / 1000.0
                        if 0.4 <= elapsed <= 180.0:
                            step_tps = out_tok / elapsed
                            if 5.0 <= step_tps <= 350.0:
                                latest_step_tps = max(1, min(350, js_round(step_tps)))

                latest_planner = {"inputTokens": in_tok, "cacheReadTokens": cache_tok, "outputTokens": out_tok}
                compacted_context_used = None
            elif rtype == "CHECKPOINT":
                cp_in = float(row.get("input_tokens") or 0)
                cp_cache = float(row.get("cache_read_tokens") or 0)
                cp_out = float(row.get("output_tokens") or 0)
                sum_in += cp_in
                sum_cache += cp_cache
                sum_out += cp_out
                step_idx = int(row.get("step_index") or 0)
                model_name = resolve_step_model(step_idx, model_info, fallback_model)
                add_daily_bucket(daily_buckets, row, cp_in, cp_cache, cp_out, stat_mtime_ms, model_name)
                summary_tokens = cp_out if cp_out > 0 else float(js_round(len(str(row.get("content") or "")) / 3.6))
                compacted_context_used = base_instruction_tokens + summary_tokens

        cumulative_prompt = sum_in + sum_cache
        cache_hit_rate = js_round((sum_cache / cumulative_prompt) * 100.0) if cumulative_prompt > 0 else 0

        latest_context_used = 0.0
        if latest_planner is not None:
            prompt_sum = latest_planner["inputTokens"] + latest_planner["cacheReadTokens"]
            latest_context_used = compacted_context_used if compacted_context_used is not None else (prompt_sum + latest_planner["outputTokens"])
        elif compacted_context_used is not None:
            latest_context_used = compacted_context_used

        return {
            "tokensPerSecond": latest_step_tps,
            "cacheHitRate": cache_hit_rate,
            "cumulativePromptTokens": cumulative_prompt,
            "cumulativeTokens": sum_in + sum_cache + sum_out,
            "latestContextUsed": latest_context_used,
            "compactedJustNow": compacted_context_used is not None,
            "dailyBuckets": daily_buckets,
            "statMtimeMs": stat_mtime_ms,
            "statSize": stat_size,
            "dbSize": model_info["dbSize"] if model_info else 0,
        }
    except Exception:
        return None


def read_json_object(file_path: Path):
    try:
        if not file_path.is_file():
            return None
        raw = strip_bom(file_path.read_text(encoding="utf-8")).strip()
        if not raw:
            return {}
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return None


def update_and_read_speed_cache(conv_id: str, total_out_tokens: float, transcript_speed: int) -> int:
    if not conv_id:
        return transcript_speed or 0
    lock_path = Path(f"{SPEED_CACHE_PATH}.lock")
    has_lock = False
    try:
        SPEED_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        has_lock = acquire_file_lock(lock_path, 0.4)
        cache = read_json_object(SPEED_CACHE_PATH) or {}
        now_ms = int(time.time() * 1000)
        prev = cache.get(conv_id) if isinstance(cache.get(conv_id), dict) else {}
        speed = transcript_speed if transcript_speed > 0 else int(prev.get("speed") or 0)

        prev_out = float(prev.get("outTokens") or 0)
        prev_ts = float(prev.get("ts") or 0)
        if total_out_tokens > 0 and prev_out > 0 and total_out_tokens > prev_out and prev_ts > 0:
            dt = (now_ms - prev_ts) / 1000.0
            d_out = total_out_tokens - prev_out
            if 0.3 <= dt <= 60.0:
                live_tps = js_round(d_out / dt)
                if 5 <= live_tps <= 350 and not (transcript_speed > 0):
                    speed = live_tps

        if transcript_speed > 0:
            speed = transcript_speed

        cache[conv_id] = {
            "outTokens": total_out_tokens or prev_out or 0,
            "ts": now_ms if total_out_tokens != prev_out else (prev_ts or now_ms),
            "speed": speed,
        }
        atomic_write_text(SPEED_CACHE_PATH, json.dumps(cache, ensure_ascii=False))
        return speed
    except Exception:
        return transcript_speed or 0
    finally:
        if has_lock:
            release_file_lock(lock_path)


def read_activity_cache(cache_path: Path) -> tuple:
    if not cache_path.is_file():
        return ("missing", {"version": 4, "conversations": {}})
    raw = strip_bom(cache_path.read_text(encoding="utf-8", errors="replace")).strip()
    if not raw:
        return ("empty", {"version": 4, "conversations": {}})
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict) and parsed.get("version") == 4 and isinstance(parsed.get("conversations"), dict):
            return ("ok", {"version": 4, "conversations": dict(parsed["conversations"])})
        return ("reset", {"version": 4, "conversations": {}})
    except Exception:
        return ("corrupt", None)


def sync_activity_ledger_cache(conv_id: str, t_stats) -> None:
    if not conv_id or not isinstance(conv_id, str) or not t_stats or not t_stats.get("dailyBuckets"):
        return
    try:
        cache_path = get_activity_cache_path()
        key = f"cli:{conv_id}"
        target_db_size = int(t_stats.get("dbSize") or 0)
        status, initial_cache = read_activity_cache(cache_path)
        if status == "ok" and initial_cache:
            prev = initial_cache["conversations"].get(key)
            if (
                isinstance(prev, dict)
                and abs(float(prev.get("mtimeMs") or 0) - float(t_stats["statMtimeMs"])) < 1.5
                and int(prev.get("size") or -1) == int(t_stats["statSize"])
                and int(prev.get("dbSize") or 0) == target_db_size
                and isinstance(prev.get("daily"), dict)
            ):
                return

        new_entry = {
            "mtimeMs": t_stats["statMtimeMs"],
            "size": t_stats["statSize"],
            "dbSize": target_db_size,
            "source": "cli",
            "daily": t_stats["dailyBuckets"],
        }

        cache_path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = Path(f"{cache_path}.lock")
        has_lock = acquire_file_lock(lock_path, 1.0)
        try:
            latest_status, latest_cache = read_activity_cache(cache_path)
            if latest_status == "corrupt":
                time.sleep(0.02)
                latest_status, latest_cache = read_activity_cache(cache_path)
            if latest_status == "corrupt" or not latest_cache:
                return
            latest_self = latest_cache["conversations"].get(key)
            if is_conv_entry_newer(latest_self, new_entry):
                return
            if (
                isinstance(latest_self, dict)
                and abs(float(latest_self.get("mtimeMs") or 0) - float(new_entry["mtimeMs"])) < 1.5
                and int(latest_self.get("size") or -1) == int(new_entry["size"])
                and int(latest_self.get("dbSize") or 0) == target_db_size
                and isinstance(latest_self.get("daily"), dict)
            ):
                return
            latest_cache["conversations"][key] = new_entry
            atomic_write_text(cache_path, json.dumps(latest_cache, ensure_ascii=False))
        finally:
            if has_lock:
                release_file_lock(lock_path)
    except Exception:
        pass


def extract_effort_from_label(label: str) -> str:
    m = EFFORT_LABEL_RE.search(str(label or "").strip())
    return re.sub(r"\s+", " ", m.group(1)).lower() if m else ""


def extract_effort_from_slug(slug: str) -> str:
    s = re.sub(r"@.*$", "", str(slug or "").strip())
    s = re.sub(r"-(?:maas|1m|2m|128k|200k|256k|512k|1000k)$", "", s, flags=re.IGNORECASE)
    m = EFFORT_SLUG_RE.search(s)
    return re.sub(r"[-_]+", " ", m.group(1)).lower() if m else ""


def resolve_model_label(data: dict) -> str:
    model_obj = data.get("model") if isinstance(data.get("model"), dict) else None
    if model_obj and isinstance(model_obj.get("display_name"), str):
        raw_display = model_obj["display_name"].strip()
    elif isinstance(data.get("model"), str):
        raw_display = data["model"].strip()
    else:
        raw_display = ""

    raw_id = model_obj["id"].strip() if (model_obj and isinstance(model_obj.get("id"), str)) else ""
    effort = model_obj["effort"].strip() if (model_obj and isinstance(model_obj.get("effort"), str)) else ""

    display_name = ""
    if raw_display:
        if not effort:
            effort = extract_effort_from_label(raw_display) or extract_effort_from_slug(raw_display)
        display_name = normalize_model_name(raw_display, "")

    if not display_name and raw_id:
        if not effort:
            effort = extract_effort_from_slug(raw_id)
        display_name = normalize_model_name("", raw_id)
    elif display_name and not effort and raw_id:
        effort = extract_effort_from_slug(raw_id)

    if not display_name:
        settings_model = read_settings_model()
        if settings_model:
            if not effort:
                effort = extract_effort_from_label(settings_model) or extract_effort_from_slug(settings_model)
            display_name = normalize_model_name(settings_model, "")

    if not display_name:
        return ""

    clean_effort = re.sub(r"\s+", " ", str(effort or "").strip().replace("_", " ")).lower()
    return f"{display_name} · {clean_effort}" if clean_effort else display_name


def resolve_left_hint(data: dict) -> str:
    state = str(data.get("agent_state") or "idle").lower()
    if state and state != "idle":
        return "esc to cancel"
    return "? for shortcuts"


def render_single_line(data: dict, speed: int, used_tokens: float, pct: int, cache_hit: int, total_tokens: float) -> str:
    fg = "\x1b[38;2;145;145;156m"
    dot = "\x1b[38;2;118;120;134m"
    native = "\x1b[38;2;118;118;118m"
    rst = "\x1b[0m"

    left_text = resolve_left_hint(data)
    model_text = resolve_model_label(data)

    speed_str = f"{speed} t/s" if speed > 0 else "-- t/s"
    ring_char = get_ring_char(pct)
    ctx_str = f"{format_compact_tokens(used_tokens)} / 1M {pct}%"
    cache_str = f"{cache_hit}%"
    total_str = format_compact_tokens(total_tokens).ljust(5, " ") if model_text else format_compact_tokens(total_tokens)

    telemetry_plain = (
        f"↯ {speed_str}  ·  "
        f"{ring_char} {ctx_str}  ·  "
        f"◈ {cache_str}  ·  "
        f"∑ {total_str}"
    )

    telemetry_ansi = (
        f"{fg}↯ {speed_str}{dot}  ·  "
        f"{fg}{ring_char} {ctx_str}{dot}  ·  "
        f"{fg}◈ {cache_str}{dot}  ·  "
        f"{fg}∑ {total_str}{rst}"
    )

    gap_before_model = "   " if model_text else ""
    right_visible_cols = len(telemetry_plain) + len(gap_before_model) + len(model_text)

    term_width = int(data.get("terminal_width") or 0)
    if term_width <= 0:
        term_width = shutil.get_terminal_size((120, 24)).columns or 120
    center_spaces = max(2, term_width - len(left_text) - right_visible_cols)

    return (
        f"{native}{left_text}{rst}"
        + (" " * center_spaces)
        + telemetry_ansi
        + (f"{gap_before_model}{native}{model_text}{rst}" if model_text else "")
    )


def run_with_input(raw_input: str) -> None:
    text = strip_bom(raw_input or "").strip()
    data = {}
    if text:
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict):
                data = parsed
        except Exception:
            data = {}

    conv_id = data.get("conversation_id") or data.get("session_id") or ""
    model_obj = data.get("model") if isinstance(data.get("model"), dict) else {}
    raw_display_name = model_obj.get("display_name") or ""
    raw_model_id = model_obj.get("id") or ""
    main_model_fallback = normalize_model_name(raw_display_name, raw_model_id)
    if not main_model_fallback:
        settings_model = read_settings_model()
        if settings_model:
            main_model_fallback = normalize_model_name(settings_model, "")

    transcript_path = resolve_transcript_path(data.get("transcript_path") or "", conv_id)
    t_stats = parse_transcript_stats(transcript_path, conv_id, main_model_fallback)

    cw = data.get("context_window") if isinstance(data.get("context_window"), dict) else {}
    cu = cw.get("current_usage") if isinstance(cw.get("current_usage"), dict) else {}

    cu_in = float(cu.get("input_tokens") or 0)
    cu_cache_read = float(cu.get("cache_read_input_tokens") or 0)
    cu_cache_create = float(cu.get("cache_creation_input_tokens") or 0)
    cu_out = float(cu.get("output_tokens") or 0)
    cu_used = cu_in + cu_cache_read + cu_cache_create + cu_out

    total_out_tokens = max(float(cw.get("total_output_tokens") or 0), cu_out)

    raw_speed = t_stats["tokensPerSecond"] if (t_stats and t_stats["tokensPerSecond"] > 0) else 0
    speed = update_and_read_speed_cache(conv_id, total_out_tokens, raw_speed)

    if t_stats and t_stats["latestContextUsed"] > 0:
        used_tokens = float(t_stats["latestContextUsed"])
    elif cu_used > 0:
        used_tokens = cu_used
    else:
        used_tokens = 0.0
    pct = max(0, min(100, js_round((used_tokens / FIXED_MAX_TOKENS) * 100.0)))

    cache_hit = 0
    if t_stats and t_stats["cumulativePromptTokens"] > 0:
        cache_hit = int(t_stats["cacheHitRate"])
    elif cu_in + cu_cache_read > 0:
        cache_hit = js_round((cu_cache_read / (cu_in + cu_cache_read)) * 100.0)

    cw_total = float(cw.get("total_input_tokens") or 0) + float(cw.get("total_output_tokens") or 0)
    total_tokens = max(
        float(t_stats["cumulativeTokens"]) if t_stats else 0.0,
        cw_total,
        cu_used,
    )

    sys.stdout.write(render_single_line(data, speed, used_tokens, pct, cache_hit, total_tokens) + "\n")
    sys.stdout.flush()
    sync_activity_ledger_cache(conv_id, t_stats)


def main() -> None:
    if sys.stdin.isatty():
        run_with_input("")
    else:
        raw = sys.stdin.read()
        run_with_input(raw)


if __name__ == "__main__":
    main()
