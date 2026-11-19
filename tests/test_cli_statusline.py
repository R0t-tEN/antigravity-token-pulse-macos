#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "cli" / "agy-statusline.py"


def load_module():
    spec = importlib.util.spec_from_file_location("agy_statusline", str(SCRIPT_PATH))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_proto_record(step: int, slug: str, display: str) -> bytes:
    buf = bytearray([0x01, 0x02, 0x03])
    s_b = slug.encode("utf-8")
    buf.extend([0x9A, 0x01, len(s_b)])
    buf.extend(s_b)
    buf.extend([0x08, 0x10])
    step_b = str(step).encode("ascii")
    buf.extend(b"\x0flast_step_index\x12")
    buf.append(len(step_b))
    buf.extend(step_b)
    d_b = display.encode("utf-8")
    buf.extend([0xAA, 0x01, len(d_b)])
    buf.extend(d_b)
    return bytes(buf)


class CliStatuslineTests(unittest.TestCase):
    def test_model_normalization(self):
        mod = load_module()
        self.assertEqual(mod.normalize_model_name("Gemini 4 Hydrogen (XHigh)", ""), "Gemini 4 Hydrogen")
        self.assertEqual(mod.normalize_model_name("", "anthropic/claude-opus-4-6-thinking@default"), "Claude Opus 4.6")
        self.assertEqual(mod.normalize_model_name("", "gemini-pro-orchestrator-g1-pro"), "Gemini 4 Argon")
        self.assertEqual(mod.normalize_model_name("", "gpt-oss-120b-maas"), "GPT OSS 120B")

    def test_end_to_end_cli_statusline_and_cache_sync(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            cli_home = home / ".gemini" / "antigravity-cli"
            conv_id = "cli-session-abc"
            logs_dir = cli_home / "brain" / conv_id / ".system_generated" / "logs"
            convs_dir = cli_home / "conversations"
            logs_dir.mkdir(parents=True, exist_ok=True)
            convs_dir.mkdir(parents=True, exist_ok=True)

            # Existing desktop entry in shared cache should be preserved
            cache_path = home / ".gemini" / "telemetry-activity-cache.json"
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(
                json.dumps(
                    {
                        "version": 4,
                        "conversations": {
                            "desktop:keep-me": {
                                "mtimeMs": 1700000000000,
                                "size": 99,
                                "dbSize": 0,
                                "source": "desktop",
                                "daily": {
                                    "2026-11-16": {
                                        "in": 100,
                                        "cache": 200,
                                        "out": 50,
                                        "total": 350,
                                        "steps": 1,
                                        "models": {"Gemini 4 Hydrogen": {"in": 100, "cache": 200, "out": 50, "total": 350, "steps": 1}},
                                    }
                                },
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )

            db_path = convs_dir / f"{conv_id}.db"
            db_path.write_bytes(make_proto_record(1, "gemini-4-hydrogen-xhigh", "Gemini 4 Hydrogen (XHigh)"))

            transcript_path = logs_dir / "transcript.jsonl"
            transcript_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "step_index": 1,
                                "type": "PLANNER_RESPONSE",
                                "created_at": "2026-11-16T10:00:00Z",
                                "input_tokens": 1000,
                                "cache_read_tokens": 9000,
                                "output_tokens": 400,
                            }
                        ),
                        json.dumps({"step_index": 2, "type": "GENERIC", "created_at": "2026-11-16T10:00:04Z", "content": "ok"}),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            stdin_payload = json.dumps(
                {
                    "conversation_id": conv_id,
                    "transcript_path": str(transcript_path),
                    "agent_state": "idle",
                    "terminal_width": 110,
                    "model": {"display_name": "Gemini 4 Hydrogen (XHigh)", "effort": "xhigh"},
                    "context_window": {},
                }
            )

            env = dict(os.environ)
            env["HOME"] = str(home)
            env.pop("ANTIGRAVITY_CLI_HOME", None)

            proc = subprocess.run(
                ["/usr/bin/python3", str(SCRIPT_PATH)],
                input=stdin_payload,
                text=True,
                capture_output=True,
                env=env,
                check=True,
            )
            out = proc.stdout.strip()
            self.assertIn("? for shortcuts", out)
            self.assertIn("100 t/s", out)
            self.assertIn("10k / 1M 1%", out)
            self.assertIn("90%", out)
            self.assertIn("10k", out)
            self.assertIn("Gemini 4 Hydrogen · xhigh", out)

            saved_cache = json.loads(cache_path.read_text(encoding="utf-8"))
            self.assertEqual(saved_cache["version"], 4)
            self.assertIn("desktop:keep-me", saved_cache["conversations"])
            self.assertIn(f"cli:{conv_id}", saved_cache["conversations"])
            cli_daily = saved_cache["conversations"][f"cli:{conv_id}"]["daily"]
            self.assertEqual(len(cli_daily), 1)
            day_bucket = next(iter(cli_daily.values()))
            self.assertEqual(day_bucket["total"], 10400)
            self.assertIn("Gemini 4 Hydrogen", day_bucket["models"])


if __name__ == "__main__":
    unittest.main()
