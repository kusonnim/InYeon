"""Regression checks for false-positive permission results and secret-safe output."""

from contextlib import redirect_stdout
import base64
from email.message import Message
from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from verify_rls import CheckError, Probe, deny, load_config, main, public_key
from common import Reply


USER_A = "10000000-0000-4000-8000-000000000001"


def reply(status, body):
    return Reply(status, Message(), json.dumps(body).encode())


class RlsVerifierTests(unittest.TestCase):
    def setUp(self):
        self.probe = Probe({"url": "https://project.supabase.co", "publishable_key": "sb_publishable_test"})

    def test_missing_route_or_unrelated_error_is_not_permission_denial(self):
        for response in (reply(404, {"code": "PGRST205"}), reply(403, {"code": "unrelated"}), reply(200, [])):
            with self.subTest(status=response.status), self.assertRaises(CheckError):
                deny(response, authenticated=True)
        deny(reply(403, {"code": "42501"}), authenticated=True)
        deny(reply(401, {"code": "42501"}), authenticated=False)

    def test_visible_foreign_row_fails(self):
        with patch.object(self.probe, "send", return_value=reply(200, [{"id": USER_A}])):
            with self.assertRaises(CheckError):
                self.probe.foreign_row("contents", {"id": USER_A}, "private-token")

    def test_missing_owner_fixture_fails(self):
        with patch.object(self.probe, "send", return_value=reply(200, [])):
            with self.assertRaises(CheckError):
                self.probe.own_row("contents", {"id": USER_A}, "private-token")

    def test_wrong_authenticated_identity_fails(self):
        response = reply(200, {"access_token": "private-token", "user": {"id": "other-owner"}})
        with patch.object(self.probe, "send", return_value=response):
            with self.assertRaises(CheckError):
                self.probe.sign_in({"id": USER_A, "email": "private@example.test", "password": "private-password"})

    def test_all_three_write_operations_are_checked(self):
        with patch.object(self.probe, "send", return_value=reply(403, {"code": "42501"})) as send:
            self.probe.writes_denied("contents", {"id": USER_A, "user_id": USER_A}, "private-token")
            self.assertEqual([call.kwargs["method"] for call in send.call_args_list], ["POST", "PATCH", "DELETE"])

    def test_privileged_key_is_rejected(self):
        malformed = ["x." + base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=") + ".x"
                     for value in ([], None)]
        for key in ("sb_secret_private", "invalid", *malformed):
            with self.subTest(key=key), self.assertRaises(CheckError):
                public_key(key)

    def test_malformed_verified_user_is_reported_safely(self):
        session = reply(200, {"access_token": "private-token", "user": {"id": USER_A}})
        with patch.object(self.probe, "send", side_effect=[session, reply(200, [])]):
            with self.assertRaises(CheckError):
                self.probe.sign_in({"id": USER_A, "email": "private@example.test", "password": "private-password"})

    def test_config_failure_does_not_print_private_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "private.json"
            config.write_text(json.dumps({"password": "do-not-print-this-password"}), encoding="utf-8")
            output = StringIO()
            with patch("sys.argv", ["verify_rls.py", "--config", str(config)]), redirect_stdout(output):
                self.assertEqual(main(), 1)
            self.assertNotIn("do-not-print-this-password", output.getvalue())
            self.assertIn("FAIL", output.getvalue())


if __name__ == "__main__":
    unittest.main()
