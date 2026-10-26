"""All fixtures are temporary databases; never call the collector's main()."""
import datetime
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest
import os

spec = importlib.util.spec_from_file_location(
    "collector", Path(__file__).resolve().parents[1] / "scripts" / "update_usage.py"
)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class WindsurfInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def database(self, sql, name="state?#.vscdb"):
        path = self.root / name
        with sqlite3.connect(path) as connection:
            connection.executescript(sql)
        return path

    def test_normal_table_reserved_path_and_usage(self):
        path = self.database("""
            CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value BLOB);
            INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo',
                '{"planName":"Test","usage":{"usedMessages":12,"messages":100}}');
        """)
        result = collector.collect_windsurf_usage(datetime.datetime.now(), db_path=path)
        self.assertEqual(result["usedByPeriod"]["30d"], 12)
        self.assertEqual(result["serverUsedPercentByPeriod"]["30d"], 12)

    def test_recursive_view_generated_and_virtual_tables(self):
        schemas = [
            """CREATE VIEW ItemTable AS WITH RECURSIVE n(x) AS
               (VALUES(1) UNION ALL SELECT x+1 FROM n)
               SELECT 'windsurf.settings.cachedPlanInfo' AS key, sum(x) AS value FROM n""",
            "CREATE TABLE ItemTable(key TEXT,seed TEXT,value TEXT GENERATED ALWAYS AS (upper(seed)))",
            "CREATE VIRTUAL TABLE ItemTable USING fts5(key,value)",
        ]
        for index, schema in enumerate(schemas):
            path = self.database(schema, f"{index}.vscdb")
            with self.assertRaises((ValueError, sqlite3.DatabaseError)):
                collector.read_windsurf_plan(path)

    def test_step_time_and_value_limits(self):
        path = self.database("""
            CREATE TABLE ItemTable(key TEXT,value TEXT);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5000)
            INSERT INTO ItemTable SELECT 'other-'||x, '{}' FROM n;
            INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{}');
        """)
        self.assertEqual(collector.read_windsurf_plan(path), {})
        with self.assertRaises(sqlite3.DatabaseError):
            collector.read_windsurf_plan(path, steps=1000)
        with self.assertRaises((ValueError, sqlite3.DatabaseError)):
            collector.read_windsurf_plan(path, seconds=0)
        large = self.database("""
            CREATE TABLE ItemTable(key TEXT,value BLOB);
            INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo',zeroblob(4096));
        """, "large.vscdb")
        with self.assertRaises((ValueError, sqlite3.DatabaseError)):
            collector.read_windsurf_plan(large, max_bytes=1024)

    def test_special_files_and_invalid_counts(self):
        path = self.database("CREATE TABLE ItemTable(key TEXT,value TEXT)")
        link = self.root / "link.vscdb"
        link.symlink_to(path)
        with self.assertRaises(OSError):
            collector.read_windsurf_plan(link)
        for value in [-1, -(2**63), 2**63, "1e100", "NaN", "inf", True]:
            with self.assertRaises(ValueError):
                collector.checked_count(value)

    def test_source_replacement_cannot_change_snapshot(self):
        path = self.database("""
            CREATE TABLE ItemTable(key TEXT,value TEXT);
            INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"planName":"Synthetic"}');
        """)

        def replace():
            path.unlink()
            os.mkfifo(path)

        self.assertEqual(collector.read_windsurf_plan(path, snapshot_ready=replace)["planName"], "Synthetic")

    def test_committed_wal_is_preserved(self):
        path = self.root / "wal.vscdb"
        connection = sqlite3.connect(path)
        try:
            connection.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE ItemTable(key TEXT,value TEXT);
                INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"planName":"WAL"}');
            """)
            self.assertTrue(Path(str(path) + "-wal").exists())
            self.assertEqual(collector.read_windsurf_plan(path)["planName"], "WAL")
        finally:
            connection.close()

        wal_link = Path(str(path) + "-wal")
        target = self.root / "target-wal"
        target.write_bytes(b"fake")
        if wal_link.exists():
            wal_link.unlink()
        wal_link.symlink_to(target)
        with self.assertRaises(OSError):
            collector.read_windsurf_plan(path)


if __name__ == "__main__":
    unittest.main()
