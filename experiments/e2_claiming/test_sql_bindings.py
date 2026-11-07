import ast
import re
import unittest
from pathlib import Path


RUNNER = Path(__file__).with_name("e2_runner.py")


def literal_execute_bindings(tree):
    """Return execute() calls whose SQL and positional parameter tuple are literals."""
    for node in ast.walk(tree):
        if (not isinstance(node, ast.Call)
                or not isinstance(node.func, ast.Attribute)
                or node.func.attr != "execute"
                or len(node.args) < 2):
            continue
        sql_node, params_node = node.args[:2]
        if (isinstance(sql_node, ast.Constant) and isinstance(sql_node.value, str)
                and isinstance(params_node, (ast.Tuple, ast.List))):
            placeholders = len(re.findall(r"(?<!%)%s", sql_node.value))
            yield node.lineno, sql_node.value, params_node, placeholders


class SqlBindingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = RUNNER.read_text(encoding="utf-8")
        cls.tree = ast.parse(cls.source)

    def test_all_literal_execute_parameter_counts_match(self):
        mismatches = [(line, count, len(params.elts))
                      for line, _sql, params, count in literal_execute_bindings(self.tree)
                      if count != len(params.elts)]
        self.assertEqual(mismatches, [])

    def test_snapshot_listing_uses_fourteen_listing_bindings(self):
        function = next(node for node in self.tree.body
                        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                        and node.name == "snapshot_listing")
        matches = [(sql, params, count) for _line, sql, params, count
                   in literal_execute_bindings(ast.Module(body=[function], type_ignores=[]))]
        self.assertEqual(len(matches), 1)
        sql, params, placeholder_count = matches[0]
        self.assertEqual(placeholder_count, 14)
        self.assertEqual(len(params.elts), 14)
        self.assertTrue(all(isinstance(value, ast.Name) and value.id == "listing"
                            for value in params.elts))
        self.assertIn("request_audit_counts_ok", sql)


if __name__ == "__main__":
    unittest.main()
