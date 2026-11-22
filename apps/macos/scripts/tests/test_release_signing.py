"""Static checks that release signing keeps a team-based designated requirement (DIST-10)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT.parents[1] / ".github" / "workflows" / "release.yml"


class ReleaseSigningTests(unittest.TestCase):
    def test_build_script_signs_with_team_requirement(self):
        script = (ROOT / "scripts" / "build-app.sh").read_text()
        self.assertIn('anchor apple generic and certificate leaf[subject.OU] = \\"$TEAM_ID\\"', script)
        self.assertIn('--requirements "=$REQUIREMENT"', script)
        self.assertIn("self-signed", script)

    def test_workflow_signs_whenever_certificate_secret_exists(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("SIGN_WITH_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE_P12 != '' }}", workflow)
        self.assertIn("if: env.SIGN_WITH_CERTIFICATE == 'true'", workflow)
        self.assertIn("NOTARIZE: ${{ env.NOTARIZE_RELEASE == 'true' && '1' || '0' }}", workflow)
        self.assertNotIn("SIGN_WITH_APPLE", workflow)

    def test_identity_is_optional_for_import(self):
        script = (ROOT / "scripts" / "import-certificate.sh").read_text()
        self.assertNotIn('"${CODE_SIGN_IDENTITY:?}"', script)


if __name__ == "__main__":
    unittest.main()
