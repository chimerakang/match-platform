#!/usr/bin/env python3
import argparse
import hashlib
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f"match-platform-{args.version}.tar.gz"

    with tempfile.TemporaryDirectory() as temporary:
        source_tar = Path(temporary) / "source.tar"
        with source_tar.open("wb") as stream:
            subprocess.run(
                ["git", "archive", "--format=tar", f"--prefix=match-platform-{args.version}/", "HEAD"],
                cwd=root,
                stdout=stream,
                check=True,
            )
        with tarfile.open(source_tar, "r") as source, tarfile.open(
            archive, "w:gz", format=tarfile.PAX_FORMAT
        ) as destination:
            for member in source.getmembers():
                extracted = source.extractfile(member) if member.isfile() else None
                destination.addfile(member, extracted)

    archive_digest = sha256(archive)
    (args.output / "SHA256SUMS").write_text(
        f"{archive_digest}  {archive.name}\n", encoding="utf-8"
    )
    sbom = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"match-platform-{args.version}",
        "documentNamespace": f"https://github.com/chimerakang/match-platform/releases/{args.version}/{commit}",
        "creationInfo": {
            "creators": ["Tool: match-platform-release-builder"],
        },
        "packages": [
            {
                "name": "match-platform",
                "SPDXID": "SPDXRef-Package",
                "versionInfo": args.version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": archive_digest}
                ],
            }
        ],
    }
    (args.output / "match-platform.spdx.json").write_text(
        json.dumps(sbom, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    provenance = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": archive.name, "digest": {"sha256": archive_digest}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": "https://github.com/chimerakang/match-platform/.github/workflows/ci.yml",
                "externalParameters": {"version": args.version},
                "resolvedDependencies": [
                    {
                        "uri": "git+https://github.com/chimerakang/match-platform",
                        "digest": {"gitCommit": commit},
                    }
                ],
            },
            "runDetails": {
                "builder": {"id": "https://github.com/chimerakang/match-platform/actions"}
            },
        },
    }
    (args.output / "provenance.intoto.jsonl").write_text(
        json.dumps(provenance, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
