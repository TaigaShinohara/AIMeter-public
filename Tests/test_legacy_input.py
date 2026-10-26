"""Synthetic homes only. Path.home is forbidden throughout these tests."""
import base64
from contextlib import redirect_stdout
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "legacy", Path(__file__).resolve().parents[1] / "scripts/update_usage.py"
)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


class LegacyInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        guard = mock.patch.object(Path, "home", side_effect=AssertionError("Real home forbidden"))
        guard.start()
        self.addCleanup(guard.stop)
        self.now = datetime.datetime.now(datetime.timezone.utc)
        self.stamp = self.now.isoformat()
        self.cutoffs = {key: self.now - datetime.timedelta(hours=hours)
                        for key, hours in zip(legacy.PERIOD_KEYS, (2, 5, 24, 168, 720))}

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def put_json(self, name, value):
        return self.write(name, json.dumps(value))

    def collect(self, name, **limits):
        return getattr(legacy, "collect_" + name + "_usage")(
            self.now, self.cutoffs, home=self.root, budget=legacy.BoundedInput(**limits))

    def run_main(self, **limits):
        with redirect_stdout(io.StringIO()):
            legacy.main(home=self.root, budget=legacy.BoundedInput(**limits))

    def codex(self, value=100):
        return {"timestamp": self.stamp, "payload": {"type": "token_count", "info": {
            "total_token_usage": {"input_tokens": value, "cached_input_tokens": 20, "output_tokens": 2}
        }}}

    def grok_path(self, key="weekly-usage.cache"):
        name = base64.b32encode(key.encode()).decode().rstrip("=")
        return "Library/Application Support/Grok Bot/sand-client-persistence/" + name + ".blob"

    def test_normal_all_providers_and_atomic_snapshot(self):
        line = json.dumps(self.codex())
        self.write(".codex/sessions/2026/10/20/test.jsonl", line + "\n" + line)
        self.put_json(".gemini/antigravity/brain/a/.system_generated/logs/transcript.jsonl",
                      {"created_at": self.stamp, "input_tokens": 10, "output_tokens": 2})
        self.put_json(".gemini/tmp/a/chats/test.json", {"messages": [
            {"timestamp": self.stamp, "tokens": {"total": 20, "input": 10, "output": 10}}]})
        self.put_json(".claude/projects/a/deep/test.jsonl",
                      {"timestamp": self.stamp, "usage": {"input_tokens": 10, "output_tokens": 2}})
        self.put_json(self.grok_path(), {"value": {"reading": {"usage": {"percentUsed": 25}}}})
        self.put_json(".copilot/session-state/a/events.jsonl",
                      {"timestamp": self.stamp, "type": "session.usage_checkpoint",
                       "data": {"accountingSnapshot": {"totalPremiumRequestCost": 12}}})
        self.write("Library/Application Support/Cursor/AgentStores/cursor_agent_stores/.control/a/pin.json", "{}")
        self.write("Library/Application Support/Cursor/AgentStores/cursor_agent_stores/.control/.hidden/.pin.json", "{}")
        db = self.root / "Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
        db.parent.mkdir(parents=True)
        with sqlite3.connect(db) as connection:
            connection.executescript("""
                CREATE TABLE ItemTable(key TEXT,value TEXT);
                INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo',
                    '{"usage":{"usedMessages":12,"messages":100}}');
            """)
        self.put_json(".ai_meter_usage.json", {"providers": {
            "custom": {"usedByPeriod": {"30d": 5}, "status": "Synthetic"}, "broken": 7}})
        self.run_main()
        path = self.root / ".ai_meter_usage.json"
        saved = json.loads(path.read_text())
        self.assertEqual(saved["openaiUsedTokens"], 84)
        self.assertEqual(saved["geminiUsedTokens"], 32)
        for name, count in (("claude", 12), ("grokbot", 2500000), ("copilot", 12),
                            ("windsurf", 12), ("cursor", 2), ("custom", 5)):
            self.assertEqual(saved["providers"][name]["usedByPeriod"]["30d"], count, name)
        self.assertNotIn("broken", saved["providers"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_auxiliary_claude_and_grok_transcript_inputs(self):
        self.put_json(".claude.json", {"projects": {"synthetic": {
            "lastTotalInputTokens": 10, "lastTotalOutputTokens": 2, "lastCost": 1.5}}})
        self.assertEqual(self.collect("claude")["usedByPeriod"]["30d"], 12)
        self.put_json(self.grok_path("transcript.replicas.synthetic"), {"value": {"entries": [
            {"timestampMs": self.now.timestamp() * 1000, "content": "synthetic text"}]}})
        self.assertGreater(self.collect("grokbot")["usedByPeriod"]["30d"], 0)

    def test_every_non_sqlite_route_enforces_file_limits(self):
        cases = [
            ("codex", ".codex/sessions/2026/10/20/test.jsonl"),
            ("gemini", ".gemini/antigravity/brain/a/.system_generated/logs/transcript.jsonl"),
            ("gemini", ".gemini/tmp/a/chats/test.json"),
            ("claude", ".claude/projects/a/test.jsonl"),
            ("claude", ".claude/sessions/a/test.jsonl"),
            ("claude", ".claude.json"),
            ("grokbot", self.grok_path()),
            ("copilot", ".copilot/session-state/a/events.jsonl"),
            ("cursor", "Library/Application Support/Cursor/AgentStores/cursor_agent_stores/.control/pin.json"),
        ]
        for name, path in cases:
            with self.subTest(provider=name, path=path):
                file = self.write(path, " " * 100)
                with self.assertRaises(legacy.InputFailure):
                    self.collect(name, file_bytes=16)
                file.unlink()

    def test_all_numeric_routes_fail_closed(self):
        for bad in (-1, 2**63, True, False, "1e100", "NaN", "inf", []):
            cases = [
                ("codex", ".codex/sessions/2026/10/20/test.jsonl", self.codex(bad)),
                ("gemini", ".gemini/antigravity/brain/a/.system_generated/logs/transcript.jsonl",
                 {"created_at": self.stamp, "input_tokens": bad}),
                ("gemini", ".gemini/tmp/a/chats/test.json",
                 {"messages": [{"timestamp": self.stamp, "tokens": {"input": bad}}]}),
                ("claude", ".claude/projects/a/test.jsonl",
                 {"timestamp": self.stamp, "usage": {"input_tokens": bad}}),
                ("claude", ".claude.json", {"projects": {"a": {"lastTotalInputTokens": bad}}}),
                ("copilot", ".copilot/session-state/a/events.jsonl",
                 {"timestamp": self.stamp, "type": "session.usage_checkpoint",
                  "data": {"accountingSnapshot": {"totalPremiumRequestCost": bad}}}),
                ("grokbot", self.grok_path(), {"value": {"reading": {"usage": {"percentUsed": bad}}}}),
            ]
            for name, path, value in cases:
                with self.subTest(provider=name, bad=bad):
                    file = self.put_json(path, value)
                    with self.assertRaises(legacy.InputFailure):
                        self.collect(name)
                    file.unlink()

    def test_accumulation_and_rate_limit_metadata(self):
        for index in range(2):
            self.put_json(".claude/projects/a/%d.jsonl" % index,
                          {"timestamp": self.stamp, "usage": {"input_tokens": legacy.MAX_COUNT}})
        with self.assertRaises(legacy.InputFailure):
            self.collect("claude")
        row = self.codex()
        row["payload"]["rate_limits"] = {"primary": {"window_minutes": 300, "used_percent": "NaN"}}
        self.put_json(".codex/sessions/2026/10/20/test.jsonl", row)
        with self.assertRaises(legacy.InputFailure):
            self.collect("codex")
        self.assertEqual(legacy.checked_count(str(legacy.MAX_COUNT)), legacy.MAX_COUNT)
        with self.assertRaises(legacy.InputFailure):
            legacy.add_count(legacy.MAX_COUNT, 1)
        with self.assertRaises(legacy.InputFailure):
            legacy.load_json('{"number":' + '9' * 129 + '}')

    def test_streaming_lines_json_and_total_budgets(self):
        lines = self.write("lines.jsonl", "first\r\nsecond\nlast")
        with legacy.BoundedInput().lines(lines) as records:
            self.assertEqual(list(records), ["first\r", "second", "last"])
        with self.assertRaises(legacy.InputFailure):
            with legacy.BoundedInput(line_bytes=4).lines(lines) as records:
                list(records)
        small = self.write("small.json", "{}")
        with self.assertRaises(legacy.InputFailure):
            legacy.BoundedInput(json_bytes=1).json(small)
        for limits in ({"total_bytes": 3}, {"files": 1}):
            budget = legacy.BoundedInput(**limits)
            budget.json(small)
            with self.assertRaises(legacy.InputFailure):
                budget.json(small)
        # Size is rechecked while reading even if the file grows after fstat.
        budget = legacy.BoundedInput(file_bytes=3)
        with budget.open_regular(small) as source:
            small.write_text("123456")
            with self.assertRaises(legacy.InputFailure):
                list(budget.chunks(source, budget.file_bytes))

    def test_entry_budget_counts_hidden_nonmatching_and_deep_directories(self):
        for index in range(5):
            self.write("tree/.ignored%d" % index, "synthetic")
        with self.assertRaises(legacy.InputFailure):
            list(legacy.BoundedInput(entries=2).glob(self.root / "tree", "*.jsonl"))
        self.write("tree/a/b/c/d/value.jsonl", "{}")
        with self.assertRaises(legacy.InputFailure):
            list(legacy.BoundedInput(entries=8).glob(self.root / "tree", "**/*.jsonl"))
        self.assertEqual(len(list(legacy.BoundedInput().glob(self.root / "tree", "**/*.jsonl"))), 1)
        link = self.root / "tree/loop"
        link.symlink_to(self.root / "tree", target_is_directory=True)
        self.assertEqual(len(list(legacy.BoundedInput().glob(self.root / "tree", "**/*.jsonl"))), 1)

    def test_special_files_and_deadline(self):
        path = self.write("real.json", "{}")
        link = self.root / "link.json"
        link.symlink_to(path)
        fifo = self.root / "fifo.json"
        os.mkfifo(fifo)
        for bad in (link, fifo, self.root):
            with self.assertRaises(legacy.InputFailure):
                legacy.BoundedInput().json(bad)
        now = [0]
        budget = legacy.BoundedInput(seconds=1, clock=lambda: now[0])
        now[0] = 2
        with self.assertRaises(legacy.InputFailure):
            budget.json(path)
        now[0] = 0
        budget = legacy.BoundedInput(seconds=1, clock=lambda: now[0])
        path.write_text("one\ntwo\n")
        with budget.lines(path) as lines:
            self.assertEqual(next(lines), "one")
            now[0] = 2
            with self.assertRaises(legacy.InputFailure):
                next(lines)

    def test_opened_file_is_not_reopened_after_replacement(self):
        path = self.write("replace.json", "{}")
        budget = legacy.BoundedInput()
        with budget.open_regular(path) as source:
            path.unlink()
            os.mkfifo(path)
            self.assertEqual(b"".join(budget.chunks(source, budget.file_bytes)), b"{}")

    def test_saved_provider_types_and_nonfinite_output(self):
        for value in (7, "text", None, True, [], {"costUSD": "1"}, {"costUSD": True},
                      {"usedByPeriod": {"30d": -1}}, {"usedByPeriod": {"30d": 1.5}},
                      {"serverUsedPercentByPeriod": {"7d": float("nan")}}):
            self.assertFalse(legacy.valid_saved_provider(value))
        self.assertTrue(legacy.valid_saved_provider({"usedByPeriod": {"30d": 12.0}, "costUSD": 1.5}))
        snapshot = self.write("snapshot.json", "previous")
        with self.assertRaises(ValueError):
            legacy.atomic_write_json(snapshot, {"invalid": float("nan")})
        self.assertEqual(snapshot.read_text(), "previous")
        link = self.root / "symlink-snapshot.json"
        link.symlink_to(snapshot)
        with self.assertRaises(legacy.InputFailure):
            legacy.atomic_write_json(link, {"valid": 1})
        self.assertEqual(snapshot.read_text(), "previous")

    def test_failed_refresh_preserves_previous_snapshot(self):
        snapshot = self.put_json(".ai_meter_usage.json", {"providers": {"custom": {"status": "Old"}}})
        before = snapshot.read_bytes()
        self.put_json(".codex/sessions/2026/10/20/test.jsonl", self.codex())
        for limits in ({"line_bytes": 8}, {"total_bytes": len(before) + 8},
                       {"seconds": 0}, {"files": 1}, {"json_bytes": 1}):
            with self.assertRaises(legacy.InputFailure):
                self.run_main(**limits)
            self.assertEqual(snapshot.read_bytes(), before)
        self.put_json(".codex/sessions/2026/10/20/test.jsonl", self.codex(-1))
        with self.assertRaises(legacy.InputFailure):
            self.run_main()
        self.assertEqual(snapshot.read_bytes(), before)

    def test_sqlite_copy_shares_refresh_budget(self):
        db = self.root / "test.vscdb"
        with sqlite3.connect(db) as connection:
            connection.execute("CREATE TABLE ItemTable(key TEXT,value TEXT)")
        with self.assertRaises(legacy.InputFailure):
            legacy.read_windsurf_plan(db, budget=legacy.BoundedInput(total_bytes=1))
        with self.assertRaises(legacy.InputFailure):
            legacy.read_windsurf_plan(db, budget=legacy.BoundedInput(files=0))


if __name__ == "__main__":
    unittest.main()
