#!/usr/bin/env python3
"""Fetch and validate the backloop.dev TLS identity used by the iOS app build."""

from __future__ import annotations

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


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def require_string(pack: dict[str, Any], key: str) -> str:
    value = pack.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"missing or empty JSON field: {key}")
    return value


def fetch_pack(sources: tuple[str, ...]) -> tuple[dict[str, Any], str]:
    failures: list[str] = []
    for source in sources:
        try:
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
            return decoded, source
        except Exception as error:
            failures.append(f"{source}: {error}")

    fail("unable to download the backloop.dev certificate pack:\n  " + "\n  ".join(failures))


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


def validate_with_openssl(directory: Path) -> None:
    openssl = shutil.which("openssl")
    if openssl is None:
        print("warning: openssl not found; PEM marker validation only", file=sys.stderr)
        return

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


def write_atomically(
    output_dir: Path,
    full_chain: str,
    private_key: str,
    common_name: str,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="backloop-certs-",
        dir=output_dir.parent,
    ) as temp_name:
        temp_dir = Path(temp_name)
        (temp_dir / "server.crt").write_text(full_chain, encoding="utf-8")
        (temp_dir / "server.pem").write_text(private_key, encoding="utf-8")
        (temp_dir / "commonName.txt").write_text(common_name, encoding="utf-8")
        validate_with_openssl(temp_dir)

        for name in ("server.crt", "server.pem", "commonName.txt"):
            os.replace(temp_dir / name, output_dir / name)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} OUTPUT_DIR [PACK_URL ...]", file=sys.stderr)
        return 2

    output_dir = Path(argv[1]).resolve()
    sources = tuple(argv[2:]) or DEFAULT_SOURCES

    try:
        pack, source = fetch_pack(sources)
        full_chain, private_key, common_name = build_files(pack)
        write_atomically(output_dir, full_chain, private_key, common_name)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"backloop.dev certificate identity updated from {source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
