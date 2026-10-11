#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent


def load_script(filename: str, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, HERE / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


policy = load_script("job_location_policy.py", "job_location_policy")
remote_boards = load_script("remote-job-boards.py", "remote_job_boards")


class JobLocationPolicyTests(unittest.TestCase):
    def test_linkedin_us_location_needs_explicit_remote_detail(self) -> None:
        details = policy.LinkedInDetails(
            location="United States",
            description=(
                "Contact Center Architect. Location: Remote – EST/CST candidates only "
                "Role Summary: Seeking a Contact Center Architect with strong AWS experience."
            ),
        )
        decision = policy.evaluate_job(
            "linkedin-remote",
            "Contact Center Architect [United States]",
            details=details,
        )
        self.assertTrue(decision.accepted)
        self.assertEqual(
            decision.display_title,
            "Contact Center Architect [Remote — EST/CST candidates only]",
        )

    def test_linkedin_us_location_alone_is_rejected(self) -> None:
        decision = policy.evaluate_job(
            "linkedin-remote",
            "Contact Center Architect [United States]",
            details=policy.LinkedInDetails(
                location="United States",
                description="Build contact center systems for enterprise customers.",
            ),
        )
        self.assertFalse(decision.accepted)
        self.assertIn("explicit remote", decision.reason)

    def test_linkedin_remote_location_without_description_is_rejected(self) -> None:
        decision = policy.evaluate_job(
            "linkedin-remote",
            "Staff AI Engineer [United States]",
            details=policy.LinkedInDetails(location="Remote", description=""),
        )
        self.assertFalse(decision.accepted)
        self.assertIn("explicit remote", decision.reason)

    def test_region_restrictions_override_generic_anywhere_or_global_words(self) -> None:
        cases = (
            ("Europe", "Remote, work from anywhere."),
            ("United States", "Remote — work from anywhere in Europe."),
            ("United States", "Remote — work from anywhere in India."),
            ("United States", "Remote, global team, EMEA hours."),
            ("United States", "Fully remote. EU work authorization is required for this role."),
            ("Anywhere", "Remote-first. We can only hire employees in India."),
            ("Global", "Remote within the country for our Germany office team."),
            ("", "Remote — work from anywhere in Brazil."),
            ("", "Remote role; applicants must be located in Canada."),
            ("", "Remote role; candidates must reside in Germany."),
        )
        for location, description in cases:
            with self.subTest(location=location, description=description):
                decision = policy.evaluate_job(
                    "linkedin-remote",
                    "Staff AI Engineer [United States]",
                    details=policy.LinkedInDetails(location=location, description=description),
                )
                self.assertFalse(decision.accepted, decision.display_title)
                self.assertIn("Denton", decision.reason)

    def test_remote_hybrid_onsite_and_rto_are_rejected(self) -> None:
        descriptions = (
            "Remote role with a hybrid schedule of three office days per week.",
            "Remote after onboarding; regular on-site attendance is required.",
            "Remote today, but the company return-to-office policy begins next quarter.",
            "Remote role; candidates must be commutable to the New York office.",
        )
        for description in descriptions:
            with self.subTest(description=description):
                decision = policy.evaluate_job(
                    "linkedin-remote",
                    "Staff AI Engineer [United States]",
                    details=policy.LinkedInDetails(
                        location="United States",
                        description=description,
                    ),
                )
                self.assertFalse(decision.accepted)
                self.assertIn("contradiction", decision.reason)

    def test_exact_denton_is_accepted_even_when_onsite(self) -> None:
        decision = policy.evaluate_job(
            "linkedin-denton",
            "AI Automation Engineer [Denton, Texas, United States]",
            details=policy.LinkedInDetails(
                location="Denton, Texas, United States",
                description="This position is on-site in Denton five days per week.",
            ),
        )
        self.assertTrue(decision.accepted)
        self.assertEqual(decision.display_title, "AI Automation Engineer [Denton, TX]")

    def test_incidental_denton_text_is_not_treated_as_listed_denton_location(self) -> None:
        cases = (
            ("reddit", "Sales Rep for Denton, TX territory [Austin, Texas]"),
            ("remoteok", "Engineer relocating near Denton, Texas [Europe]"),
            ("reddit", "[UNVERIFIED REDDIT LEAD] hiring onsite NYC | visited Denton, TX once"),
        )
        for source, title in cases:
            with self.subTest(source=source, title=title):
                decision = policy.evaluate_job(source, title)
                self.assertFalse(decision.accepted, decision.display_title)

    def test_dallas_dfw_and_denton_county_are_not_denton_city(self) -> None:
        for location in (
            "Dallas-Fort Worth Metroplex",
            "Dallas, Texas, United States",
            "Denton County, Texas, United States",
            "Lewisville, Texas, United States",
        ):
            with self.subTest(location=location):
                decision = policy.evaluate_job(
                    "linkedin-denton",
                    f"AI Engineer [{location}]",
                    details=policy.LinkedInDetails(location=location, description="On-site role."),
                )
                self.assertFalse(decision.accepted)

    def test_remote_board_needs_us_compatible_or_unrestricted_location(self) -> None:
        accepted = (
            ("wellfound", "Staff Applied AI Engineer [United States]"),
            ("remoteok", "Agent Engineer [Worldwide]"),
            ("remotive", "LLM Engineer [Remote]"),
            ("himalayas", "AI Engineer [North America]"),
        )
        for source, title in accepted:
            with self.subTest(source=source):
                decision = policy.evaluate_job(source, title)
                self.assertTrue(decision.accepted, decision.reason)
                self.assertIn("[Remote", decision.display_title)

        decision = policy.evaluate_job(
            "workingnomads", "AI Engineer [Europe, Middle East, Africa]"
        )
        self.assertFalse(decision.accepted)
        self.assertIn("Denton-compatible", decision.reason)

    def test_unverified_or_ambiguous_text_does_not_pass(self) -> None:
        for source, title in (
            ("reddit", "[UNVERIFIED REDDIT LEAD] Agentic AI Engineer [United States] remote status unclear"),
            ("twitter", "Hiring AI engineers across the United States"),
            ("upwork", "Build an AI agent for our team"),
            ("linkedin", "Staff AI Engineer [United States]"),
        ):
            with self.subTest(source=source):
                decision = policy.evaluate_job(source, title)
                self.assertFalse(decision.accepted)

    def test_explicit_fully_remote_us_text_can_pass_unstructured_source(self) -> None:
        decision = policy.evaluate_job(
            "reddit",
            "[UNVERIFIED REDDIT LEAD] Hiring Staff Agent Engineer — fully remote, US only",
        )
        self.assertTrue(decision.accepted)
        self.assertIn("[Remote — US only]", decision.display_title)

    def test_remote_board_parser_rejects_description_contradictions(self) -> None:
        rejected = remote_boards.make_job(
            "remotive",
            "1",
            "Example",
            "Staff AI Engineer",
            "https://example.com/jobs/1",
            "United States",
            description="Remote listing, transitioning to hybrid with two office days.",
        )
        self.assertIsNone(rejected)
        accepted = remote_boards.make_job(
            "remotive",
            "2",
            "Example",
            "Staff AI Engineer",
            "https://example.com/jobs/2",
            "United States",
            description="Fully distributed team. Work from anywhere in the United States.",
        )
        self.assertIsNotNone(accepted)

    def test_remote_board_scans_full_description_for_trailing_rto(self) -> None:
        description = "Fully remote role. " + ("Engineering responsibilities. " * 150)
        description += " Employees must return-to-office and work on-site in Berlin."
        rejected = remote_boards.make_job(
            "remotive",
            "3",
            "Example",
            "Staff AI Engineer",
            "https://example.com/jobs/3",
            "United States",
            description=description,
        )
        self.assertGreater(len(description), 3000)
        self.assertIsNone(rejected)

    def test_filter_tsv_is_single_gate_and_normalizes_linkedin_source(self) -> None:
        remote_url = "https://www.linkedin.com/jobs/view/4470319201"
        rows = [
            f"li-4470319201\tlinkedin-remote\tMobile Apps US\tContact Center Architect [United States]\t{remote_url}\t",
            "li-2\tlinkedin-remote\tExample\tAI Engineer [United States]\thttps://www.linkedin.com/jobs/view/2\t",
            "wf-3\twellfound\tExample\tStaff Applied AI Engineer [United States]\thttps://wellfound.com/jobs/3\t$200k-$270k",
            "reddit-4\treddit\tr/jobs\t[UNVERIFIED REDDIT LEAD] Agentic AI [United States] remote status unclear\thttps://reddit.com/4\t",
            "li-5\tlinkedin-denton\tUNT\tAI Engineer [Denton, Texas, United States]\thttps://www.linkedin.com/jobs/view/5\t",
        ]
        accepted, rejected = policy.filter_tsv(
            rows,
            linkedin_details={
                remote_url: policy.LinkedInDetails(
                    location="United States",
                    description="Location: Remote - EST/CST candidates only.",
                ),
                "https://www.linkedin.com/jobs/view/2": policy.LinkedInDetails(
                    location="United States", description="Location: United States."
                ),
                "https://www.linkedin.com/jobs/view/5": policy.LinkedInDetails(
                    location="Denton, Texas, United States", description="On-site in Denton."
                ),
            },
        )
        self.assertEqual(len(accepted), 3)
        self.assertEqual(len(rejected), 2)
        self.assertTrue(all("\tlinkedin\t" in row for row in (accepted[0], accepted[2])))
        self.assertIn("[Remote — EST/CST candidates only]", accepted[0])
        self.assertIn("[Remote — United States]", accepted[1])
        self.assertIn("[Denton, TX]", accepted[2])
    def test_remote_boards_admit_current_role_and_adjacent_delivery_titles(self) -> None:
        titles = (
            "Delivery Consultant - Connect and Lex",
            "Senior Professional Services Consultant - Contact Center AI",
            "Principal CCaaS Architect",
        )
        for index, title in enumerate(titles, 1):
            with self.subTest(title=title):
                job = remote_boards.make_job(
                    "remotive",
                    str(index),
                    "Example",
                    title,
                    f"https://example.com/jobs/{index}",
                    "United States",
                    description="Fully remote. Work from anywhere in the United States.",
                )
                self.assertIsNotNone(job)

    def test_job_scores_require_exact_count_sequential_indices_and_schema(self) -> None:
        valid = """startup noise
{"idx":1,"score":5,"reason":"exact lane"}
{"idx":2,"score":3,"reason":"adjacent fit"}
"""
        self.assertEqual(
            policy.validate_job_scores(valid, 2),
            [
                {"idx": 1, "score": 5, "reason": "exact lane"},
                {"idx": 2, "score": 3, "reason": "adjacent fit"},
            ],
        )

        invalid_outputs = (
            ('{"idx":1,"score":5,"reason":"only one"}', "score count"),
            (
                '{"idx":1,"score":5,"reason":"first"}\n'
                '{"idx":1,"score":4,"reason":"duplicate"}',
                "sequential index 2",
            ),
            (
                '{"idx":1,"score":5,"reason":"first"}\n'
                '{"idx":3,"score":4,"reason":"gap"}',
                "sequential index 2",
            ),
            (
                '{"idx":1,"score":5}\n'
                '{"idx":2,"score":4,"reason":"second"}',
                "invalid schema",
            ),
            (
                '{"idx":1,"score":5,"reason":"first","pay":"guessed"}\n'
                '{"idx":2,"score":4,"reason":"second"}',
                "invalid schema",
            ),
            (
                '{"idx":1,"score":true,"reason":"first"}\n'
                '{"idx":2,"score":4,"reason":"second"}',
                "invalid score",
            ),
            (
                '{"idx":1,"score":5,"reason":""}\n'
                '{"idx":2,"score":4,"reason":"second"}',
                "invalid reason",
            ),
        )
        for raw, expected_error in invalid_outputs:
            with self.subTest(expected_error=expected_error):
                with self.assertRaisesRegex(ValueError, expected_error):
                    policy.validate_job_scores(raw, 2)

    def test_both_job_pipelines_use_strict_score_validation_and_fail_closed(self) -> None:
        for filename in ("ai-agent-jobs.sh", "nathan-jobs.sh"):
            with self.subTest(filename=filename):
                script = (HERE / filename).read_text(encoding="utf-8")
                self.assertIn('MODEL_COUNT=$((i - 1))', script)
                self.assertIn('--validate-scores --expected-count "$MODEL_COUNT"', script)
                self.assertIn("scoring failed closed", script)
                validator = script.index('--validate-scores --expected-count "$MODEL_COUNT"')
                digest = script.index("# --- Build digest ---")
                self.assertLess(validator, digest)

    def test_scheduled_pipeline_gates_before_scoring_and_delivery(self) -> None:
        script = (HERE / "ai-agent-jobs.sh").read_text(encoding="utf-8")
        gate = script.index('job_location_policy.py" --input "$JOBS_FILE"')
        scoring = script.index('log "Filtering via kiro-cli..."')
        delivery = script.index("# --- Deliver ---")
        self.assertLess(gate, scoring)
        self.assertLess(scoring, delivery)
        self.assertIn("location=Denton%2C+Texas%2C+United+States", script)
        self.assertNotIn("location=Dallas-Fort+Worth+Metroplex", script)
        self.assertIn("AI_AGENT_JOBS_DRY_RUN", script)
        self.assertIn("skipping Discord, email, and dedup writes", script)
        self.assertIn("AWS Delivery Consultant — Connect and Lex", script)
        self.assertIn("Amazon Connect Center of Delivery Excellence", script)
        self.assertIn("LinkedIn job 4470215327", script)
        self.assertIn("TARGET ROLES — COMPARABLE OR UPWARD", script)
        self.assertIn("SOCIAL TRUST RULE", script)
        self.assertIn("job-alert/aggregator accounts", script)
        self.assertIn("declare -A KEPT_KEYS", script)
        self.assertIn("dedupe_key=", script)
        self.assertIn(r'{\"idx\":<N>,\"score\":<1-5>', script)
        self.assertNotIn("CURRENT: AWS Solutions Architect", script)


if __name__ == "__main__":
    unittest.main()
