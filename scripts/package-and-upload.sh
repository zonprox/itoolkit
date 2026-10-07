#!/usr/bin/env bash
# ==============================================================================
# package-and-upload.sh
# Release packaging and multi-provider public upload helper for IToolkit.
# Creates clean standalone IToolkit.zip and uploads to public host (onlyfiles.com / storage.to).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse command line options and positional parameters
SKIP_UPLOAD=false
ZIP_PATH=""
PROVIDER=""

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
                echo "[Error] --provider requires an argument (auto, parallel, onlyfiles, or storage.to)." >&2
                exit 1
            fi
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [ZIP_PATH] [PROVIDER]"
            echo ""
            echo "Options:"
            echo "  --skip-upload       Create archive locally without uploading"
            echo "  --provider=NAME     Target provider (auto, parallel, onlyfiles, storage.to)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Positional Arguments (optional):"
            echo "  ZIP_PATH            Path for output archive (default: IToolkit.zip)"
            echo "  PROVIDER            Provider if not specified via --provider (default: auto)"
            exit 0
            ;;
        *)
            if [ -z "$ZIP_PATH" ]; then
                ZIP_PATH="$1"
            elif [ -z "$PROVIDER" ]; then
                PROVIDER="$1"
            fi
            shift
            ;;
    esac
done

ZIP_PATH="${ZIP_PATH:-$REPO_ROOT/IToolkit.zip}"
PROVIDER="${PROVIDER:-auto}"

echo "================================================================================"
echo "          IToolkit Bash Release Packaging & Public Cloud Distribution           "
echo "================================================================================"
echo "  Repository Root : $REPO_ROOT"
echo "  Output Archive  : $ZIP_PATH"
echo "  Target Provider : $PROVIDER"
echo "  Upload Mode     : $(if [ "$SKIP_UPLOAD" = true ]; then echo "Skip (Local Only)"; else echo "Upload Requested"; fi)"
echo "================================================================================"

# If PowerShell Core (pwsh) is available, prioritize the PowerShell packaging engine
if command -v pwsh >/dev/null 2>&1 && [ -f "$REPO_ROOT/Build-IToolkitPackage.ps1" ]; then
    echo "[Info] Utilizing PowerShell packaging engine via pwsh..."
    PWSH_ARGS=(-NoProfile -File "$REPO_ROOT/Build-IToolkitPackage.ps1" -DestinationPath "$ZIP_PATH" -Provider "$PROVIDER" -Force)
    if [ "$SKIP_UPLOAD" = true ]; then
        PWSH_ARGS+=(-SkipUpload)
    else
        PWSH_ARGS+=(-Upload)
    fi
    pwsh "${PWSH_ARGS[@]}"
    exit 0
fi

# Fallback: Pure Bash Staging & Zip Generation
echo "[1/4] Staging production runtime files in temporary workspace..."
TEMP_STAGE="$(mktemp -d /tmp/itoolkit_pkg_XXXXXX)"
trap 'rm -rf "$TEMP_STAGE"' EXIT

CONTENT_DIR="$TEMP_STAGE/Content"
mkdir -p "$CONTENT_DIR"
mkdir -p "$CONTENT_DIR/Modules"

# Whitelist root production files
for f in IToolkit.psd1 IToolkit.psm1 Start-IToolkit.ps1 Run-IToolkit.bat README.md; do
    if [ -f "$REPO_ROOT/$f" ]; then
        cp -p "$REPO_ROOT/$f" "$CONTENT_DIR/"
        echo "  + Staged root file: $f"
    fi
done

# Whitelist production modules
MODULES=(Core Outlook Office Printers Backup Accounts ExternalTools TUI)
for mod in "${MODULES[@]}"; do
    if [ -d "$REPO_ROOT/Modules/$mod" ]; then
        cp -r "$REPO_ROOT/Modules/$mod" "$CONTENT_DIR/Modules/"
        echo "  + Staged module: Modules/$mod"
    fi
done

# Sanitize staging: remove accidental logs, temps, or backups
echo "[2/4] Sanitizing package contents..."
find "$CONTENT_DIR" -type f \( -name "*.log" -o -name "*.tmp" -o -name "*.bak" -o -name "*.orig" -o -name "RegistryBackup_*.reg" -o -name ".DS_Store" -o -name "Thumbs.db" \) -delete 2>/dev/null || true

# Assert no prohibited paths exist
if find "$CONTENT_DIR" -type d \( -name ".git" -o -name ".agents" -o -name ".codebase-memory" -o -name "Tests" -o -name "Build" -o -name "scripts" -o -name "Logs" -o -name "Backups" \) | grep -q .; then
    echo "[Error] Security assertion failed: Disallowed development directory found in staging!" >&2
    exit 1
fi

# Create ZIP archive
echo "[3/4] Creating standalone ZIP archive: $ZIP_PATH..."
rm -f "$ZIP_PATH"

if command -v zip >/dev/null 2>&1; then
    (cd "$CONTENT_DIR" && zip -qr "$ZIP_PATH" .)
elif command -v python3 >/dev/null 2>&1; then
    (cd "$CONTENT_DIR" && python3 -c '
import zipfile, os, sys
dest = sys.argv[1]
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk("."):
        for file in files:
            full_path = os.path.join(root, file)
            arcname = os.path.normpath(full_path)
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

# Public Cloud Upload
UPLOAD_URL=""
if [ "$SKIP_UPLOAD" = true ]; then
    echo "[4/4] Upload skipped (--skip-upload requested; local package build only)."
else
    echo "[4/4] Uploading to public cloud hosting service..."

    upload_onlyfiles() {
        local target="$1"
        local resp
        resp="$(curl -s -F "file=@$target" -F "expire=0" https://api.onlyfiles.com/v1/upload 2>/dev/null || true)"
        if [ -n "$resp" ]; then
            local full_url
            full_url="$(echo "$resp" | grep -o 'https://onlyfiles\.com/[^"]*' | head -n 1 || true)"
            echo "$full_url"
        fi
    }

    upload_storage_to() {
        local target="$1"
        local fname
        fname="$(basename "$target")"
        local fsize
        fsize="$(stat -c %s "$target" 2>/dev/null || wc -c < "$target")"
        fsize="$(echo "$fsize" | tr -d ' ')"

        local init_json
        init_json="$(curl -m 30 -s -X POST "https://storage.to/api/upload/init" \
            -H "Content-Type: application/json" \
            -H "User-Agent: curl/7.88.1" \
            -d "{\"filename\":\"$fname\",\"size\":$fsize,\"content_type\":\"application/zip\"}" 2>/dev/null || true)"

        local upload_url
        upload_url="$(echo "$init_json" | grep -o '"upload_url":"[^"]*' | cut -d'"' -f4 || true)"
        local r2_key
        r2_key="$(echo "$init_json" | grep -o '"r2_key":"[^"]*' | cut -d'"' -f4 || true)"

        if [ -z "$upload_url" ] || [ -z "$r2_key" ]; then
            return
        fi

        local put_status
        put_status="$(curl -m 60 -s -o /dev/null -w "%{http_code}" -X PUT -T "$target" -H "Content-Type: application/zip" "$upload_url" 2>/dev/null || true)"
        if [ "$put_status" != "200" ]; then
            return
        fi

        local confirm_json
        confirm_json="$(curl -m 30 -s -X POST "https://storage.to/api/upload/confirm" \
            -H "Content-Type: application/json" \
            -H "User-Agent: curl/7.88.1" \
            -d "{\"filename\":\"$fname\",\"size\":$fsize,\"content_type\":\"application/zip\",\"r2_key\":\"$r2_key\"}" 2>/dev/null || true)"

        local file_url
        file_url="$(echo "$confirm_json" | grep -o '"url":"[^"]*' | cut -d'"' -f4 || true)"
        if [[ "$file_url" =~ ^https?://storage\.to/ ]]; then
            echo "$file_url"
        fi
    }

    ONLYFILES_URL=""
    STORAGE_TO_URL=""

    if [ "$PROVIDER" = "onlyfiles" ]; then
        ONLYFILES_URL="$(upload_onlyfiles "$ZIP_PATH")"
        UPLOAD_URL="$ONLYFILES_URL"
    elif [ "$PROVIDER" = "storage.to" ] || [ "$PROVIDER" = "storageto" ]; then
        STORAGE_TO_URL="$(upload_storage_to "$ZIP_PATH")"
        UPLOAD_URL="$STORAGE_TO_URL"
    else
        # auto or parallel mode: run onlyfiles and storage.to in parallel
        echo "  Attempting parallel upload (onlyfiles.com + storage.to)..."
        TMP_ONLY="$(mktemp)"
        TMP_STORAGE="$(mktemp)"
        upload_onlyfiles "$ZIP_PATH" > "$TMP_ONLY" 2>/dev/null &
        PID1=$!
        upload_storage_to "$ZIP_PATH" > "$TMP_STORAGE" 2>/dev/null &
        PID2=$!
        wait "$PID1" 2>/dev/null || true
        wait "$PID2" 2>/dev/null || true
        ONLYFILES_URL="$(cat "$TMP_ONLY" 2>/dev/null | tr -d '\r\n')"
        STORAGE_TO_URL="$(cat "$TMP_STORAGE" 2>/dev/null | tr -d '\r\n')"
        rm -f "$TMP_ONLY" "$TMP_STORAGE"

        UPLOAD_URL="${ONLYFILES_URL:-$STORAGE_TO_URL}"
    fi
fi

echo "================================================================================"
echo "                        IToolkit Release Summary                                "
echo "================================================================================"
echo "  Archive Path : $ZIP_PATH"
echo "  File Size    : $FILE_SIZE bytes"
echo "  SHA-256 Hash : $SHA256"
if [ "$SKIP_UPLOAD" = true ]; then
    echo "  Upload       : Skipped (Local package build only)"
    echo "================================================================================"
    echo "  Distribution Ready: Standalone package created at $ZIP_PATH."
elif [ -n "${ONLYFILES_URL:-}" ] || [ -n "${STORAGE_TO_URL:-}" ] || [ -n "$UPLOAD_URL" ]; then
    if [ -n "${ONLYFILES_URL:-}" ]; then
        echo "  Download URL (OnlyFiles) : $ONLYFILES_URL"
    fi
    if [ -n "${STORAGE_TO_URL:-}" ]; then
        echo "  Download URL (Storage.to) : $STORAGE_TO_URL"
    fi
    if [ -z "${ONLYFILES_URL:-}" ] && [ -z "${STORAGE_TO_URL:-}" ] && [ -n "$UPLOAD_URL" ]; then
        echo "  Download URL             : $UPLOAD_URL"
    fi
    echo "================================================================================"
    echo "  Distribution Ready: Download and extract on Windows 10/11,"
    echo "  then run Run-IToolkit.bat or Start-IToolkit.ps1."
else
    echo "  [Warning] Public upload failed or timed out. Archive preserved locally."
fi
echo "================================================================================"
