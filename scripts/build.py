#!/usr/bin/env python3
"""Build a deterministic standalone installer; no external Python dependencies."""
import base64
import gzip
import hashlib
import io
import pathlib
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
payload = ROOT / "files"
paths = sorted(p for p in payload.rglob("*") if p.is_file())
manifest = "".join(p.relative_to(payload).as_posix() + "\n" for p in paths)
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w", format=tarfile.USTAR_FORMAT) as tar:
    for name, data in [
        ("manifest", manifest.encode()),
        *((f"payload/{p.relative_to(payload).as_posix()}", p.read_bytes()) for p in paths),
    ]:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o644
        info.mtime = 0
        tar.addfile(info, io.BytesIO(data))
compressed_buffer = io.BytesIO()
# GzipFile emits a stable OS header across Python 3.9/3.12; gzip.compress(mtime=0)
# can delegate that header to platform zlib on some Python versions.
with gzip.GzipFile(filename="", mode="wb", fileobj=compressed_buffer, mtime=0, compresslevel=9) as gz:
    gz.write(archive.getvalue())
compressed = compressed_buffer.getvalue()
sha = hashlib.sha256(compressed).hexdigest()
b64 = base64.encodebytes(compressed).decode()
function = f"""extract_payload() {{
\tbase64 -d > "$STAGE/payload.tar.gz" <<'TSLAN_PAYLOAD_BASE64'
{b64}TSLAN_PAYLOAD_BASE64
\tactual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{{print $1}}')
\t[ "$actual" = '{sha}' ] || die "Embedded payload checksum mismatch"
\ttar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}}
"""
template = (ROOT / "scripts/install.template.sh").read_text()
assert template.count("# PAYLOAD_FUNCTION") == 1
result = template.replace("# PAYLOAD_FUNCTION", function)
temporary_installer = ROOT / ".install.sh.build"
temporary_installer.write_text(result)
temporary_installer.chmod(0o755)
temporary_installer.replace(ROOT / "install.sh")
(ROOT / "SHA256SUMS").write_text(hashlib.sha256(result.encode()).hexdigest() + "  install.sh\n")
print(f"Built install.sh ({len(result.encode())} bytes); payload SHA256 {sha}")
