#!/usr/bin/env python3
"""Fetch a usable, non-revoked loopback TLS identity for the iOS app build."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, NoReturn, Optional
from urllib.parse import urlencode
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class Candidate:
    full_chain: str
    private_key: str
    common_name: str
    source: str


DEFAULT_PROVIDERS: tuple[dict[str, str], ...] = (
    {
        "kind": "pem_pair",
        "label": "127-0-0-1.dev",
        "cert_url": "https://raw.githubusercontent.com/appcove/127-0-0-1.dev/main/cert.pem",
        "key_url": "https://raw.githubusercontent.com/appcove/127-0-0-1.dev/main/key.pem",
        # Use the concrete apex hostname. The published cert covers both this
        # name and *.127-0-0-1.dev, and DNS maps both to 127.0.0.1.
        "hostname": "127-0-0-1.dev",
    },
    {
        "kind": "pack",
        "label": "Backloop primary",
        "url": "https://backloop.dev/pack.json",
    },
    {
        "kind": "pack",
        "label": "Backloop GitHub fallback",
        "url": "https://raw.githubusercontent.com/perki/backloop.dev/gh-pages/pack.json",
    },
)


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def normalize_pem(value: str) -> str:
    return value.strip() + "\n"


def fetch_bytes(url: str, accept: str) -> bytes:
    request = Request(
        url,
        headers={
            "Accept": accept,
            "User-Agent": "Ksign-build/2.0",
        },
    )
    with urlopen(request, timeout=30) as response:
        if not 200 <= response.status < 300:
            fail(f"HTTP {response.status}")
        return response.read()


def fetch_text(url: str) -> str:
    value = fetch_bytes(url, "text/plain,*/*;q=0.8").decode("utf-8")
    if not value.strip():
        fail("provider returned empty text")
    return value


def fetch_json(url: str) -> dict[str, Any]:
    decoded = json.loads(fetch_bytes(url, "application/json").decode("utf-8"))
    if not isinstance(decoded, dict):
        fail("JSON root is not an object")
    return decoded


def require_string(pack: dict[str, Any], key: str) -> str:
    value = pack.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"missing or empty JSON field: {key}")
    return value


def candidate_from_pack(pack: dict[str, Any], source: str) -> Candidate:
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

    return Candidate(
        full_chain=cert + "\n" + ca,
        private_key=normalize_pem(key1 + key2),
        common_name=common_name.strip(),
        source=source,
    )


def candidate_from_pem_pair(provider: dict[str, str]) -> Candidate:
    cert_url = provider["cert_url"]
    key_url = provider["key_url"]
    hostname = provider["hostname"].strip()
    if not hostname:
        fail("provider hostname is empty")
    return Candidate(
        full_chain=normalize_pem(fetch_text(cert_url)),
        private_key=normalize_pem(fetch_text(key_url)),
        common_name=hostname,
        source=provider["label"],
    )


def fetch_candidate(provider: dict[str, str]) -> Candidate:
    kind = provider["kind"]
    if kind == "pem_pair":
        return candidate_from_pem_pair(provider)
    if kind == "pack":
        return candidate_from_pack(fetch_json(provider["url"]), provider["label"])
    fail(f"unknown provider kind: {kind}")


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


def split_certificate_blocks(crt: Path) -> list[str]:
    blocks = re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        crt.read_text(encoding="utf-8"),
        flags=re.DOTALL,
    )
    if len(blocks) < 2:
        fail("server.crt is missing the leaf plus intermediate chain")
    return blocks


def validate_with_openssl(directory: Path) -> tuple[str, str]:
    openssl = shutil.which("openssl")
    if openssl is None:
        fail("openssl is required to validate TLS certificate candidates")

    crt = directory / "server.crt"
    key = directory / "server.pem"
    blocks = split_certificate_blocks(crt)

    certificate_files: list[Path] = []
    for index, block in enumerate(blocks):
        certificate_file = directory / f"certificate-{index}.pem"
        certificate_file.write_text(block + "\n", encoding="utf-8")
        certificate_files.append(certificate_file)
        run_checked([openssl, "x509", "-in", str(certificate_file), "-noout"])

    run_checked([openssl, "pkey", "-in", str(key), "-noout"])

    cert_public_key = run_checked(
        [openssl, "x509", "-in", str(certificate_files[0]), "-pubkey", "-noout"]
    )
    key_public_key = run_checked([openssl, "pkey", "-in", str(key), "-pubout"])
    if cert_public_key.strip() != key_public_key.strip():
        fail("the certificate and private key do not match")

    # Reject candidates that are already expired or not yet valid.
    run_checked([openssl, "x509", "-in", str(certificate_files[0]), "-checkend", "0", "-noout"])

    leaf_der = run_checked(
        [openssl, "x509", "-in", str(certificate_files[0]), "-outform", "DER"]
    )
    fingerprint = hashlib.sha256(leaf_der).hexdigest()
    return fingerprint, certificate_files[0].read_text(encoding="utf-8")


def base_domain(common_name: str) -> str:
    value = common_name.strip()
    return value[2:] if value.startswith("*.") else value


def certspotter_revocation_status(
    fingerprint: str,
    domain: str,
    *,
    max_pages: int = 8,
) -> tuple[Optional[bool], str]:
    """Return (revoked?, detail). None means status could not be confirmed."""

    after: Optional[str] = None
    for _ in range(max_pages):
        params: list[tuple[str, str]] = [
            ("domain", domain),
            ("include_subdomains", "true"),
            ("match_wildcards", "true"),
            ("expand", "revocation"),
        ]
        if after:
            params.append(("after", after))
        url = "https://api.certspotter.com/v1/issuances?" + urlencode(params)

        try:
            payload = fetch_bytes(url, "application/json")
            issuances = json.loads(payload.decode("utf-8"))
        except Exception as error:
            return None, f"Cert Spotter request failed: {error}"

        if not isinstance(issuances, list):
            return None, "Cert Spotter response was not an array"

        for issuance in issuances:
            if not isinstance(issuance, dict):
                continue
            if str(issuance.get("cert_sha256", "")).lower() != fingerprint.lower():
                continue

            revoked = issuance.get("revoked")
            revocation = issuance.get("revocation")
            if revoked is True:
                if isinstance(revocation, dict):
                    when = revocation.get("time", "unknown time")
                    reason = revocation.get("reason", "unknown")
                    return True, f"revoked at {when}, reason code {reason}"
                return True, "revoked"
            if revoked is False:
                checked = None
                if isinstance(revocation, dict):
                    checked = revocation.get("checked_at")
                if not isinstance(checked, str) or not checked:
                    return None, "matching issuance has no revocation-check timestamp"
                try:
                    checked_at = datetime.fromisoformat(checked.replace("Z", "+00:00"))
                    age = (datetime.now(timezone.utc) - checked_at).total_seconds()
                except ValueError:
                    return None, f"invalid revocation-check timestamp: {checked}"
                if age < -600 or age > 24 * 60 * 60:
                    return None, f"non-revoked status is stale (checked {checked})"
                return False, f"not revoked (checked {checked})"
            return None, "matching issuance has no revocation status"

        if not issuances:
            return None, "certificate was not found in Cert Spotter results"
        last = issuances[-1]
        if not isinstance(last, dict) or not last.get("id"):
            return None, "Cert Spotter pagination did not provide an id"
        after = str(last["id"])

    return None, "certificate was not found within the Cert Spotter pagination limit"


def stage_candidate(directory: Path, candidate: Candidate) -> tuple[str, str]:
    (directory / "server.crt").write_text(candidate.full_chain, encoding="utf-8")
    (directory / "server.pem").write_text(candidate.private_key, encoding="utf-8")
    (directory / "commonName.txt").write_text(candidate.common_name + "\n", encoding="utf-8")
    return validate_with_openssl(directory)


def install_staged(output_dir: Path, staged: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for name in ("server.crt", "server.pem", "commonName.txt"):
        os.replace(staged / name, output_dir / name)


def providers_from_argv(argv: list[str]) -> tuple[dict[str, str], ...]:
    # Preserve the old CLI contract: additional arguments are treated as pack
    # URLs. They are tried before the built-in Backloop fallbacks, but after the
    # current 127-0-0-1.dev provider that has a directly published cert/key pair.
    if len(argv) <= 2:
        return DEFAULT_PROVIDERS

    custom = tuple(
        {"kind": "pack", "label": f"Custom pack {index + 1}", "url": url}
        for index, url in enumerate(argv[2:])
    )
    return (DEFAULT_PROVIDERS[0],) + custom + DEFAULT_PROVIDERS[1:]


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} OUTPUT_DIR [PACK_URL ...]", file=sys.stderr)
        return 2

    output_dir = Path(argv[1]).resolve()
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []

    for provider in providers_from_argv(argv):
        label = provider["label"]
        try:
            candidate = fetch_candidate(provider)
            with tempfile.TemporaryDirectory(
                prefix="ksign-tls-candidate-",
                dir=output_dir.parent,
            ) as temp_name:
                staged = Path(temp_name)
                fingerprint, _ = stage_candidate(staged, candidate)
                revoked, detail = certspotter_revocation_status(
                    fingerprint,
                    base_domain(candidate.common_name),
                )
                if revoked is True:
                    fail(f"certificate {fingerprint} is revoked ({detail})")
                if revoked is None:
                    fail(f"revocation status is unknown for {fingerprint} ({detail})")

                install_staged(output_dir, staged)
                print(
                    f"TLS identity updated from {candidate.source}; "
                    f"fingerprint={fingerprint}; revocation={detail}"
                )
                return 0
        except Exception as error:
            failures.append(f"{label}: {error}")
            print(f"warning: {label} rejected: {error}", file=sys.stderr)

    print(
        "error: no usable non-revoked TLS certificate provider remained:\n  "
        + "\n  ".join(failures),
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
