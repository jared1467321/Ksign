#!/usr/bin/env python3
"""Fetch, rank, and validate the backloop.dev TLS identity used by the iOS app build."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, NoReturn, Optional
from urllib.request import Request, urlopen

DEFAULT_SOURCES = (
    "https://backloop.dev/pack.json",
    "https://raw.githubusercontent.com/perki/backloop.dev/gh-pages/pack.json",
)


@dataclass(frozen=True)
class CertificateCandidate:
    source: str
    full_chain: str
    private_key: str
    common_name: str
    not_before: datetime
    not_after: datetime


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def require_string(pack: dict[str, Any], key: str) -> str:
    value = pack.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"missing or empty JSON field: {key}")
    return value


def download_pack(source: str) -> dict[str, Any]:
    request = Request(
        source,
        headers={
            "Accept": "application/json",
            "User-Agent": "Ksign-build/1.0",
        },
    )
    with urlopen(request, timeout=30) as response:
        payload = response.read()
    decoded = json.loads(payload.decode("utf-8"))
    if not isinstance(decoded, dict):
        fail("the JSON root is not an object")
    return decoded


def normalize_pem(value: str) -> str:
    return value.strip() + "\n"


def build_files(pack: dict[str, Any]) -> tuple[str, str, str]:
    cert = normalize_pem(require_string(pack, "cert"))
    ca = normalize_pem(require_string(pack, "ca"))
    key1 = require_string(pack, "key1")
    key2 = require_string(pack, "key2")

    info = pack.get("info")
    if not isinstance(info, dict):
        fail("missing JSON object: info")
    domains = info.get("domains")
    if not isinstance(domains, dict):
        fail("missing JSON object: info.domains")
    common_name = domains.get("commonName")
    if not isinstance(common_name, str) or not common_name.strip():
        fail("missing or empty JSON field: info.domains.commonName")

    full_chain = cert + "\n" + ca
    private_key = normalize_pem(key1 + key2)

    if full_chain.count("-----BEGIN CERTIFICATE-----") < 2:
        fail("certificate pack does not contain a leaf plus CA/intermediate chain")
    if (
        "-----BEGIN PRIVATE KEY-----" not in private_key
        and "-----BEGIN RSA PRIVATE KEY-----" not in private_key
    ):
        fail("certificate pack does not contain a private key")

    return full_chain, private_key, common_name.strip() + "\n"


def run_checked(command: list[str], *, input_data: Optional[bytes] = None) -> bytes:
    result = subprocess.run(
        command,
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(
            f"{' '.join(command)} failed: "
            f"{result.stderr.decode(errors='replace').strip()}"
        )
    return result.stdout


def require_openssl() -> str:
    openssl = shutil.which("openssl")
    if openssl is None:
        fail(
            "openssl is required to validate certificate/key pairing and compare "
            "X.509 validity dates"
        )
    return openssl


def parse_openssl_date(value: str) -> datetime:
    value = value.strip()
    if value.endswith(" GMT"):
        value = value[:-4]
    try:
        return datetime.strptime(value, "%b %d %H:%M:%S %Y").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        fail(f"could not parse OpenSSL certificate date {value!r}: {error}")


def certificate_dates(crt: Path) -> tuple[datetime, datetime]:
    openssl = require_openssl()
    output = run_checked([openssl, "x509", "-in", str(crt), "-noout", "-dates"])
    values: dict[str, str] = {}
    for line in output.decode("utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key.strip()] = value.strip()

    if "notBefore" not in values or "notAfter" not in values:
        fail("openssl did not return both notBefore and notAfter")

    not_before = parse_openssl_date(values["notBefore"])
    not_after = parse_openssl_date(values["notAfter"])
    if not_after <= not_before:
        fail("the certificate validity interval is inverted")
    return not_before, not_after


def validate_with_openssl(directory: Path) -> tuple[datetime, datetime]:
    openssl = require_openssl()
    crt = directory / "server.crt"
    key = directory / "server.pem"
    certificate_blocks = re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        crt.read_text(encoding="utf-8"),
        flags=re.DOTALL,
    )
    if len(certificate_blocks) < 2:
        fail("the generated server.crt is missing the CA/intermediate chain")

    for index, block in enumerate(certificate_blocks):
        certificate_file = directory / f"certificate-{index}.pem"
        certificate_file.write_text(block + "\n", encoding="utf-8")
        run_checked([openssl, "x509", "-in", str(certificate_file), "-noout"])

    run_checked([openssl, "pkey", "-in", str(key), "-noout"])

    cert_public_key = run_checked(
        [openssl, "x509", "-in", str(crt), "-pubkey", "-noout"]
    )
    key_public_key = run_checked([openssl, "pkey", "-in", str(key), "-pubout"])
    if cert_public_key.strip() != key_public_key.strip():
        fail("the downloaded certificate and private key do not match")

    return certificate_dates(crt)


def validate_candidate(pack: dict[str, Any], source: str) -> CertificateCandidate:
    full_chain, private_key, common_name = build_files(pack)
    with tempfile.TemporaryDirectory(prefix="backloop-candidate-") as temp_name:
        temp_dir = Path(temp_name)
        (temp_dir / "server.crt").write_text(full_chain, encoding="utf-8")
        (temp_dir / "server.pem").write_text(private_key, encoding="utf-8")
        not_before, not_after = validate_with_openssl(temp_dir)

    now = datetime.now(timezone.utc)
    if now < not_before:
        fail(f"certificate is not valid until {not_before.isoformat()}")
    if now >= not_after:
        fail(f"certificate expired at {not_after.isoformat()}")

    return CertificateCandidate(
        source=source,
        full_chain=full_chain,
        private_key=private_key,
        common_name=common_name,
        not_before=not_before,
        not_after=not_after,
    )


def fetch_candidates(
    sources: tuple[str, ...],
) -> tuple[list[CertificateCandidate], list[str]]:
    candidates: list[CertificateCandidate] = []
    failures: list[str] = []

    for source in sources:
        try:
            pack = download_pack(source)
            candidate = validate_candidate(pack, source)
            candidates.append(candidate)
            print(
                "accepted TLS candidate from "
                f"{source}: notBefore={candidate.not_before.isoformat()}, "
                f"notAfter={candidate.not_after.isoformat()}"
            )
        except Exception as error:
            failures.append(f"{source}: {error}")

    return candidates, failures


def newest_candidate(candidates: list[CertificateCandidate]) -> CertificateCandidate:
    if not candidates:
        fail("no usable certificate candidates were supplied")

    def preferred(lhs: CertificateCandidate, rhs: CertificateCandidate) -> CertificateCandidate:
        lhs_dominates = (
            lhs.not_before >= rhs.not_before
            and lhs.not_after >= rhs.not_after
            and (lhs.not_before > rhs.not_before or lhs.not_after > rhs.not_after)
        )
        rhs_dominates = (
            rhs.not_before >= lhs.not_before
            and rhs.not_after >= lhs.not_after
            and (rhs.not_before > lhs.not_before or rhs.not_after > lhs.not_after)
        )
        if lhs_dominates:
            return lhs
        if rhs_dominates:
            return rhs

        # If issuance and expiration move in opposite directions, prefer the
        # longer-lived identity rather than sacrificing expiration just for a
        # later notBefore date.
        if lhs.not_after != rhs.not_after:
            return lhs if lhs.not_after > rhs.not_after else rhs
        if lhs.not_before != rhs.not_before:
            return lhs if lhs.not_before > rhs.not_before else rhs
        return lhs if lhs.source <= rhs.source else rhs

    winner = candidates[0]
    for candidate in candidates[1:]:
        winner = preferred(winner, candidate)
    return winner


def first_certificate(text: str) -> str | None:
    match = re.search(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        text,
        flags=re.DOTALL,
    )
    if match is None:
        return None
    return match.group(0).strip() + "\n"


def existing_identity(output_dir: Path) -> tuple[str, datetime, datetime] | None:
    crt = output_dir / "server.crt"
    if not crt.exists():
        return None

    try:
        key = output_dir / "server.pem"
        if not key.exists():
            return None

        text = crt.read_text(encoding="utf-8")
        leaf = first_certificate(text)
        if leaf is None:
            return None

        openssl = require_openssl()
        run_checked([openssl, "pkey", "-in", str(key), "-noout"])
        cert_public_key = run_checked(
            [openssl, "x509", "-in", str(crt), "-pubkey", "-noout"]
        )
        key_public_key = run_checked([openssl, "pkey", "-in", str(key), "-pubout"])
        if cert_public_key.strip() != key_public_key.strip():
            fail("the existing certificate and private key do not match")

        not_before, not_after = certificate_dates(crt)
        return leaf, not_before, not_after
    except Exception as error:
        print(
            f"warning: could not inspect existing TLS identity; it may be replaced: {error}",
            file=sys.stderr,
        )
        return None


def should_install(output_dir: Path, candidate: CertificateCandidate) -> bool:
    installed = existing_identity(output_dir)
    if installed is None:
        return True

    installed_leaf, installed_not_before, installed_not_after = installed
    candidate_leaf = first_certificate(candidate.full_chain)
    if candidate_leaf == installed_leaf:
        return False

    if (
        candidate.not_before < installed_not_before
        or candidate.not_after < installed_not_after
    ):
        print(
            "refusing TLS certificate downgrade: "
            f"installed notBefore={installed_not_before.isoformat()}, "
            f"notAfter={installed_not_after.isoformat()}; "
            f"candidate notBefore={candidate.not_before.isoformat()}, "
            f"notAfter={candidate.not_after.isoformat()}",
            file=sys.stderr,
        )
        return False

    return True


def write_atomically(output_dir: Path, candidate: CertificateCandidate) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="backloop-certs-",
        dir=output_dir.parent,
    ) as temp_name:
        temp_dir = Path(temp_name)
        (temp_dir / "server.crt").write_text(candidate.full_chain, encoding="utf-8")
        (temp_dir / "server.pem").write_text(candidate.private_key, encoding="utf-8")
        (temp_dir / "commonName.txt").write_text(candidate.common_name, encoding="utf-8")
        validate_with_openssl(temp_dir)

        for name in ("server.crt", "server.pem", "commonName.txt"):
            os.replace(temp_dir / name, output_dir / name)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} OUTPUT_DIR [PACK_URL ...]", file=sys.stderr)
        return 2

    output_dir = Path(argv[1]).resolve()
    sources = tuple(dict.fromkeys(argv[2:] or DEFAULT_SOURCES))

    try:
        candidates, failures = fetch_candidates(sources)
        if not candidates:
            fail(
                "unable to download a usable backloop.dev certificate pack:\n  "
                + "\n  ".join(failures)
            )

        candidate = newest_candidate(candidates)
        if should_install(output_dir, candidate):
            write_atomically(output_dir, candidate)
            print(
                "backloop.dev certificate identity updated from "
                f"{candidate.source} "
                f"(notBefore={candidate.not_before.isoformat()}, "
                f"notAfter={candidate.not_after.isoformat()})"
            )
        else:
            print(
                "backloop.dev certificate identity left unchanged; the installed "
                "identity is the same or newer"
            )
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
