import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError


SCRIPT = Path(__file__).resolve().parents[1] / ".github/scripts/bump-ubuntu-snapshot.py"
SPEC = importlib.util.spec_from_file_location("snapshot_bump", SCRIPT)
snapshot_bump = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot_bump)

CURRENT = "20261101T060000Z"
LATEST = "20261116T120000Z"
DIGEST = "sha256:" + "a" * 64
NEW_DIGEST = "sha256:" + "b" * 64


def release(architecture="amd64", checksum="a" * 64, date="Monday"):
    entries = "\n".join(
        f" {checksum} 123 {component}/binary-{architecture}/Packages"
        for component in snapshot_bump.COMPONENTS
    )
    return f"Date: {date}\nSHA256:\n{entries}\nSHA512:\n ignored\n"


class SnapshotBumpTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.dockerfile = Path(self.directory.name) / "Dockerfile"
        self.original = (
            'ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"\n'
            'ARG ARG_UBUNTU_BASE_IMAGE_TAG="24.04"\n'
            f'ARG ARG_UBUNTU_BASE_IMAGE_DIGEST="{DIGEST}"\n'
            f'ARG ARG_UBUNTU_SNAPSHOT="{CURRENT}"\n'
            "FROM ubuntu\n"
        )
        self.dockerfile.write_text(self.original)
        self.digest_lookup = patch.object(
            snapshot_bump, "latest_image_digest", return_value=DIGEST
        )
        self.mock_digest = self.digest_lookup.start()
        self.addCleanup(self.digest_lookup.stop)

    def test_metadata_only_changes_leave_dockerfile_untouched(self):
        before = snapshot_bump.package_checksums(release(), "amd64")
        after = snapshot_bump.package_checksums(
            release(date="Tuesday")
            + f" {'b' * 64} 456 main/source/Sources\n",
            "amd64",
        )
        with patch.object(snapshot_bump, "snapshot_checksums", side_effect=[before, after]):
            self.assertFalse(snapshot_bump.bump_snapshot(self.dockerfile, LATEST))
        self.assertEqual(self.original, self.dockerfile.read_text())

    def test_changed_package_index_bumps_snapshot(self):
        before = snapshot_bump.package_checksums(release("arm64"), "arm64")
        after = dict(before)
        after["universe/binary-arm64/Packages"] = "b" * 64
        with patch.object(snapshot_bump, "snapshot_checksums", side_effect=[before, after]):
            self.assertTrue(snapshot_bump.bump_snapshot(self.dockerfile, LATEST))
        self.assertEqual(
            self.original.replace(CURRENT, LATEST), self.dockerfile.read_text()
        )

    def test_digest_only_update_preserves_snapshot(self):
        self.mock_digest.return_value = NEW_DIGEST
        with patch.object(snapshot_bump, "snapshot_checksums", return_value={"same": {}}):
            self.assertTrue(snapshot_bump.bump_snapshot(self.dockerfile, LATEST))
        self.assertEqual(
            self.original.replace(DIGEST, NEW_DIGEST), self.dockerfile.read_text()
        )

    def test_both_pins_change_together(self):
        self.mock_digest.return_value = NEW_DIGEST
        with patch.object(snapshot_bump, "snapshot_checksums", side_effect=[{}, {"new": {}}]):
            self.assertTrue(snapshot_bump.bump_snapshot(self.dockerfile, LATEST))
        self.assertEqual(
            self.original.replace(CURRENT, LATEST).replace(DIGEST, NEW_DIGEST),
            self.dockerfile.read_text(),
        )

    def test_registry_failure_does_not_change_pins(self):
        self.mock_digest.side_effect = URLError("registry unavailable")
        with self.assertRaises(URLError):
            snapshot_bump.bump_snapshot(self.dockerfile, LATEST)
        self.assertEqual(self.original, self.dockerfile.read_text())

    def test_digest_update_is_not_written_if_snapshot_check_fails(self):
        self.mock_digest.return_value = NEW_DIGEST
        with patch.object(snapshot_bump, "snapshot_checksums", side_effect=ValueError("bad metadata")):
            with self.assertRaises(ValueError):
                snapshot_bump.bump_snapshot(self.dockerfile, LATEST)
        self.assertEqual(self.original, self.dockerfile.read_text())

    def test_digest_only_workflow_outputs_use_preserved_snapshot(self):
        self.mock_digest.return_value = NEW_DIGEST
        output = Path(self.directory.name) / "output"
        with (
            patch.object(snapshot_bump, "snapshot_checksums", return_value={}),
            patch.object(snapshot_bump, "Path", side_effect=lambda name: (
                self.dockerfile if name == "Dockerfile" else Path(name)
            )),
            patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}),
        ):
            self.assertEqual(0, snapshot_bump.main())
        self.assertEqual(
            f"updated=true\nsnapshot={CURRENT}\ndigest={NEW_DIGEST}\n",
            output.read_text(),
        )

    def test_checks_every_suite_for_both_architectures(self):
        with patch.object(snapshot_bump, "urlopen") as fetch:
            metadata = release().replace(
                "SHA512:", release("arm64").split("SHA256:\n")[1]
            )
            fetch.return_value.__enter__.return_value.read.return_value = metadata.encode()
            result = snapshot_bump.snapshot_checksums(CURRENT, "noble")
        expected = {
            f"noble{suffix}/{architecture}"
            for suffix in ("", "-updates", "-security", "-backports")
            for architecture in ("amd64", "arm64")
        }
        self.assertEqual(expected, result.keys())
        for suite_architecture, checksums in result.items():
            architecture = suite_architecture.split("/")[1]
            self.assertEqual(snapshot_bump.package_checksums(metadata, architecture), checksums)
        self.assertEqual(
            {f"https://snapshot.ubuntu.com/ubuntu/{CURRENT}/dists/noble{suffix}/Release"
             for suffix in ("", "-updates", "-security", "-backports")},
            {call.args[0] for call in fetch.call_args_list},
        )
        self.assertEqual(4, fetch.call_count)

    def test_arm64_checksum_change_in_shared_release_bumps_snapshot(self):
        def metadata(arm_checksum):
            return release().replace(
                "SHA512:", release("arm64", checksum=arm_checksum).split("SHA256:\n")[1]
            ).encode()

        with patch.object(snapshot_bump, "urlopen") as fetch:
            fetch.return_value.__enter__.return_value.read.side_effect = (
                [metadata("a" * 64)] * 4 + [metadata("b" * 64)] * 4
            )
            self.assertTrue(snapshot_bump.bump_snapshot(self.dockerfile, LATEST))
        self.assertEqual(self.original.replace(CURRENT, LATEST), self.dockerfile.read_text())

    def test_incomplete_or_invalid_metadata_fails_without_bumping(self):
        for metadata in (
            "<html>service unavailable</html>",
            release().replace("SHA256:", "MD5Sum:"),
            release().replace("main/binary-amd64/Packages", "main/binary-arm64/Packages"),
            release(checksum="invalid"),
        ):
            with self.subTest(metadata=metadata), patch.object(snapshot_bump, "urlopen") as fetch:
                fetch.return_value.__enter__.return_value.read.return_value = metadata.encode()
                with self.assertRaises(ValueError):
                    snapshot_bump.bump_snapshot(self.dockerfile, LATEST)
                self.assertEqual(self.original, self.dockerfile.read_text())

    def test_download_failure_leaves_dockerfile_untouched(self):
        with patch.object(snapshot_bump, "urlopen", side_effect=URLError("unavailable")):
            with self.assertRaises(URLError):
                snapshot_bump.bump_snapshot(self.dockerfile, LATEST)
        self.assertEqual(self.original, self.dockerfile.read_text())

    def test_unsupported_base_tag_fails_instead_of_checking_wrong_suites(self):
        self.dockerfile.write_text(self.original.replace("24.04", "26.04"))
        with self.assertRaisesRegex(ValueError, "new Ubuntu base tag"):
            snapshot_bump.bump_snapshot(self.dockerfile, LATEST)


class RegistryDigestTests(unittest.TestCase):
    def fetch_digest(self, media_type, architectures, advertised_digest=None):
        content = json.dumps({
            "mediaType": media_type,
            "manifests": [
                {"platform": {"os": "linux", "architecture": architecture}}
                for architecture in architectures
            ],
        }).encode()
        digest = "sha256:" + hashlib.sha256(content).hexdigest()
        with patch.object(snapshot_bump, "urlopen") as fetch:
            token_response = io.BytesIO(b'{"token": "test-token"}')
            manifest_response = io.BytesIO(content)
            manifest_response.headers = {
                "Docker-Content-Digest": advertised_digest or digest
            }
            fetch.side_effect = [token_response, manifest_response]
            result = snapshot_bump.latest_image_digest()
            request = fetch.call_args_list[1].args[0]
            self.assertEqual(
                "https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04",
                request.full_url,
            )
            self.assertEqual("Bearer test-token", request.get_header("Authorization"))
        self.assertEqual(digest, result)

    def test_oci_and_docker_multi_platform_indexes(self):
        for media_type in (
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
        ):
            with self.subTest(media_type=media_type):
                self.fetch_digest(media_type, ["amd64", "arm64"])

    def test_single_platform_manifest_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "multi-platform"):
            self.fetch_digest(
                "application/vnd.oci.image.manifest.v1+json", ["amd64", "arm64"]
            )

    def test_missing_arm64_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            self.fetch_digest("application/vnd.oci.image.index.v1+json", ["amd64"])

    def test_digest_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.fetch_digest(
                "application/vnd.oci.image.index.v1+json",
                ["amd64", "arm64"],
                advertised_digest=DIGEST,
            )


if __name__ == "__main__":
    unittest.main()
