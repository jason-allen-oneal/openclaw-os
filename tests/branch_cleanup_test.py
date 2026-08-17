import importlib.util
import pathlib
import sys
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "delete_merged_branches.py"
SPEC = importlib.util.spec_from_file_location("delete_merged_branches", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
evaluate_branch = MODULE.evaluate_branch


class BranchCleanupDecisionTests(unittest.TestCase):
    def decide(self, **overrides):
        values = {
            "branch": "feat/example",
            "branch_sha": "a" * 40,
            "default_branch": "main",
            "protected": False,
            "has_open_pull_request": False,
            "merged_pull_request_head_shas": [],
            "ahead_by": 1,
        }
        values.update(overrides)
        return evaluate_branch(**values)

    def test_default_branch_is_never_deleted(self):
        decision = self.decide(branch="main", ahead_by=0)
        self.assertFalse(decision.delete)

    def test_protected_branch_is_never_deleted(self):
        decision = self.decide(protected=True, ahead_by=0)
        self.assertFalse(decision.delete)

    def test_open_pull_request_is_never_deleted(self):
        decision = self.decide(
            has_open_pull_request=True,
            merged_pull_request_head_shas=["a" * 40],
        )
        self.assertFalse(decision.delete)

    def test_ancestry_merged_transient_branch_is_deleted(self):
        decision = self.decide(ahead_by=0)
        self.assertTrue(decision.delete)
        self.assertIn("fully contained", decision.reason)

    def test_unchanged_squash_merged_tip_is_deleted(self):
        decision = self.decide(
            ahead_by=8,
            merged_pull_request_head_shas=["a" * 40],
        )
        self.assertTrue(decision.delete)
        self.assertIn("confirmed merged PR head", decision.reason)

    def test_branch_advanced_after_squash_merge_is_retained(self):
        decision = self.decide(
            branch_sha="b" * 40,
            ahead_by=1,
            merged_pull_request_head_shas=["a" * 40],
        )
        self.assertFalse(decision.delete)
        self.assertIn("advanced after merge", decision.reason)

    def test_non_transient_branch_without_merged_pr_is_retained(self):
        decision = self.decide(branch="release-candidate", ahead_by=0)
        self.assertFalse(decision.delete)

    def test_non_transient_branch_with_exact_merged_tip_is_deleted(self):
        decision = self.decide(
            branch="release-candidate",
            ahead_by=2,
            merged_pull_request_head_shas=["a" * 40],
        )
        self.assertTrue(decision.delete)

    def test_missing_compare_result_fails_closed(self):
        decision = self.decide(ahead_by=None)
        self.assertFalse(decision.delete)


if __name__ == "__main__":
    unittest.main()
