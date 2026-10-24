#!/usr/bin/env bash
# ==============================================================================
# package-and-upload.sh
# Release packaging and public cloud upload helper for iToolKit.
# Compiles native C# .NET 8 win-x64 standalone single-file executable,
# packages clean iToolKit.zip, and uploads to storage.to.
# ==============================================================================
set -euo pipefail

# Ensure .NET SDK in PATH and invariant globalization mode for non-Windows hosts
export PATH="$HOME/.dotnet:$PATH"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse command line options and positional parameters
SKIP_UPLOAD=false
ZIP_PATH=""
PROVIDER="storage.to"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-upload)
            SKIP_UPLOAD=true
            shift
            ;;
        --provider=*)
            PROVIDER="${1#*=}"
            shift
            ;;
        --provider)
            if [ $# -ge 2 ]; then
                PROVIDER="$2"
                shift 2
            else
                echo "[Error] --provider requires an argument (storage.to)." >&2
                exit 1
            fi
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [ZIP_PATH]"
            echo ""
            echo "Options:"
            echo "  --skip-upload       Create archive locally without uploading"
            echo "  --provider=NAME     Target provider (default: storage.to)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Positional Arguments (optional):"
            echo "  ZIP_PATH            Path for output archive (default: iToolKit.zip)"
            exit 0
            ;;
        *)
            if [ -z "$ZIP_PATH" ]; then
                ZIP_PATH="$1"
            fi
            shift
            ;;
    esac
done

ZIP_PATH="${ZIP_PATH:-$REPO_ROOT/iToolKit.zip}"

echo "================================================================================"
echo "          iToolKit Bash Release Packaging & Public Cloud Distribution           "
echo "================================================================================"
echo "  Repository Root : $REPO_ROOT"
echo "  Output Archive  : $ZIP_PATH"
echo "  Target Provider : storage.to"
echo "  Upload Mode     : $(if [ "$SKIP_UPLOAD" = true ]; then echo "Skip (Local Only)"; else echo "Upload Requested"; fi)"
echo "================================================================================"

# Validate .NET SDK presence
if ! command -v dotnet >/dev/null 2>&1; then
    echo "[Error] .NET SDK (dotnet) not found in PATH." >&2
    exit 1
fi

# Step 1: Clean-slate .NET compilation & publication
echo "[1/4] Compiling and publishing self-contained win-x64 release via .NET SDK..."
STAGE_DIR="$(mktemp -d /tmp/itoolkit_publish_XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

dotnet publish "$REPO_ROOT/src/IToolkit.App/IToolkit.App.csproj" \
    -c Release \
    -r win-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:IncludeAllContentForSelfExtract=true \
    -p:EnableWindowsTargeting=true \
    -o "$STAGE_DIR"

if [ ! -f "$STAGE_DIR/iToolKit.exe" ]; then
    echo "[Error] Build artifact $STAGE_DIR/iToolKit.exe was not created." >&2
    exit 1
fi

# Sanitize stage directory: remove PDB debug files and stage README.md
rm -f "$STAGE_DIR"/*.pdb
if [ -f "$REPO_ROOT/README.md" ]; then
    cp "$REPO_ROOT/README.md" "$STAGE_DIR/README.md"
fi

# Step 2: Standalone ZIP Archive Packaging
echo "[2/4] Packaging standalone ZIP archive: $ZIP_PATH..."
rm -f "$ZIP_PATH"
mkdir -p "$(dirname "$ZIP_PATH")"

if command -v zip >/dev/null 2>&1; then
    (cd "$STAGE_DIR" && zip -qr "$ZIP_PATH" .)
elif command -v python3 >/dev/null 2>&1; then
    (cd "$STAGE_DIR" && python3 -c '
import zipfile, os, sys
dest = sys.argv[1]
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for root, dirs, files in os.walk("."):
        for file in files:
            full_path = os.path.join(root, file)
            arcname = os.path.relpath(full_path, ".")
            zf.write(full_path, arcname)
' "$ZIP_PATH")
else
    echo "[Error] Neither zip nor python3 is available to create ZIP archive." >&2
    exit 1
fi

if [ ! -f "$ZIP_PATH" ]; then
    echo "[Error] Failed to create ZIP archive at $ZIP_PATH." >&2
    exit 1
fi

FILE_SIZE="$(stat -c %s "$ZIP_PATH" 2>/dev/null || stat -f %z "$ZIP_PATH")"
SHA256="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"

echo "  -> Archive created: $ZIP_PATH ($FILE_SIZE bytes)"
echo "  -> SHA-256 Checksum: $SHA256"

# Step 3: Public Cloud Upload (storage.to)
STORAGE_TO_URL=""

if [ "$SKIP_UPLOAD" = true ]; then
    echo "[3/4] Upload skipped (--skip-upload requested; local package build only)."
else
    echo "[3/4] Uploading to storage.to..."

    upload_storage_to() {
        local target="$1"
        python3 - "$target" <<'PYEOF'
import json, os, sys, urllib.request

target = sys.argv[1]
fname = os.path.basename(target)
fsize = os.path.getsize(target)
headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
}

try:
    req = urllib.request.Request(
        "https://storage.to/api/upload/init",
        data=json.dumps({"filename": fname, "size": fsize, "content_type": "application/zip"}).encode(),
        headers=headers,
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        init_data = json.loads(resp.read().decode())

    if not init_data.get("success"):
        sys.exit(0)

    r2_key = init_data["r2_key"]
    upload_type = init_data.get("type", "single")

    if upload_type == "single":
        with open(target, "rb") as f:
            data = f.read()
        put_req = urllib.request.Request(init_data["upload_url"], data=data, method="PUT")
        put_req.add_header("Content-Type", "application/zip")
        with urllib.request.urlopen(put_req, timeout=300) as put_resp:
            if put_resp.status not in (200, 201, 204):
                sys.exit(0)
    elif upload_type == "multipart":
        upload_id = init_data["upload_id"]
        part_size = int(init_data["part_size"])
        total_parts = int(init_data["total_parts"])
        urls = init_data.get("initial_urls", {})
        completed_parts = []
        with open(target, "rb") as f:
            for part_num in range(1, total_parts + 1):
                chunk = f.read(part_size)
                part_url = urls.get(str(part_num))
                if not part_url:
                    p_req = urllib.request.Request(
                        "https://storage.to/api/upload/parts",
                        data=json.dumps({"upload_id": upload_id, "part_numbers": [part_num]}).encode(),
                        headers=headers,
                        method="POST"
                    )
                    with urllib.request.urlopen(p_req, timeout=30) as p_resp:
                        part_url = json.loads(p_resp.read().decode())["urls"][str(part_num)]
                put_req = urllib.request.Request(part_url, data=chunk, method="PUT")
                with urllib.request.urlopen(put_req, timeout=300) as put_resp:
                    etag = put_resp.headers.get("ETag") or put_resp.headers.get("etag") or ""
                    completed_parts.append({"partNumber": part_num, "etag": etag})

        comp_req = urllib.request.Request(
            "https://storage.to/api/upload/complete-multipart",
            data=json.dumps({"upload_id": upload_id, "parts": completed_parts}).encode(),
            headers=headers,
            method="POST"
        )
        with urllib.request.urlopen(comp_req, timeout=60) as comp_resp:
            comp_data = json.loads(comp_resp.read().decode())
            if not comp_data.get("success"):
                sys.exit(0)

    conf_req = urllib.request.Request(
        "https://storage.to/api/upload/confirm-batch",
        data=json.dumps({
            "files": [{"filename": fname, "size": fsize, "content_type": "application/zip", "r2_key": r2_key}],
            "collection_id": None,
            "upload_speed": None
        }).encode(),
        headers=headers,
        method="POST"
    )
    with urllib.request.urlopen(conf_req, timeout=30) as conf_resp:
        conf_data = json.loads(conf_resp.read().decode())
        file_url = conf_data.get("results", {}).get("0", {}).get("file", {}).get("url", "")
        if file_url.startswith("http"):
            print(file_url)
except Exception:
    pass
PYEOF
    }

    STORAGE_TO_URL="$(upload_storage_to "$ZIP_PATH" | tr -d '\r\n')"
fi

# Step 4: Summary Output
echo "================================================================================"
echo "                        iToolKit Release Summary                                "
echo "================================================================================"
echo "  Archive Path : $ZIP_PATH"
echo "  File Size    : $FILE_SIZE bytes"
echo "  SHA-256 Hash : $SHA256"
if [ "$SKIP_UPLOAD" = true ]; then
    echo "  Upload       : Skipped (Local package build only)"
    echo "================================================================================"
    echo "  Distribution Ready: Standalone package created at $ZIP_PATH."
elif [ -n "${STORAGE_TO_URL:-}" ]; then
    echo "  Download URL (Storage.to) : $STORAGE_TO_URL"
    echo "================================================================================"
    echo "  Distribution Ready: Download and extract iToolKit.zip on Windows 10/11 x64,"
    echo "  then run iToolKit.exe directly."
else
    echo "  [Warning] Public upload failed or timed out. Archive preserved locally."
fi
echo "================================================================================"
