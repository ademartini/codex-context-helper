import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "observe_resources.py"
SPEC = importlib.util.spec_from_file_location("observe_resources", SCRIPT)
observe_resources = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observe_resources)


class ObserveResourcesTests(unittest.TestCase):
    def test_idle_full_duration_within_budget_cannot_pass_acceptance(self):
        result = observe_resources.result_for(
            samples=[{"rssMiB": 100.0, "processes": 1}],
            survived=True,
            elapsed=1800.0,
            cpu_seconds=0.0,
        )

        self.assertTrue(result["resourceBudgetPassed"])
        self.assertFalse(result["workloadVerified"])
        self.assertFalse(result["acceptancePassed"])
        self.assertEqual(result["childProcessSamples"], 0)

    def test_short_observation_cannot_pass_resource_budget(self):
        result = observe_resources.result_for(
            samples=[{"rssMiB": 1.0, "processes": 2}],
            survived=True,
            elapsed=1799.999,
            cpu_seconds=0.0,
        )

        self.assertFalse(result["resourceBudgetPassed"])
        self.assertFalse(result["acceptancePassed"])

    def test_unrounded_thresholds_do_not_false_pass(self):
        result = observe_resources.result_for(
            samples=[{"rssMiB": 149.999, "processes": 2}],
            survived=True,
            elapsed=1800.0,
            cpu_seconds=36.0018,
        )

        self.assertGreater(result["averageCPUPercent"], 2.0)
        self.assertFalse(result["resourceBudgetPassed"])


if __name__ == "__main__":
    unittest.main()
