#!/usr/bin/env bash
set -euo pipefail

# ── config ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.dl-model-venv"
PYTHON=""

# ── find python3 ─────────────────────────────────────────────────────────────

find_python() {
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver="$("$cmd" --version 2>&1 | grep -oP '\d+\.\d+')"
            local major minor
            major="${ver%%.*}"
            minor="${ver##*.}"
            if (( major == 3 && minor >= 9 )); then
                PYTHON="$cmd"
                return 0
            fi
        fi
    done
    return 1
}

# ── bootstrap venv + deps ────────────────────────────────────────────────────

setup_env() {
    if [ ! -d "$VENV_DIR" ]; then
        echo "==> First run: creating Python venv at ${VENV_DIR} ..."
        "$PYTHON" -m venv "$VENV_DIR"
    fi

    # activate
    source "${VENV_DIR}/bin/activate"

    # install / upgrade huggingface_hub if missing or outdated
    if ! python -c "import huggingface_hub" &>/dev/null; then
        echo "==> Installing huggingface_hub ..."
        pip install --quiet --upgrade huggingface_hub
    fi
}

# ── embedded python script ───────────────────────────────────────────────────

run_download() {
    python - "$@" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""Fast parallel download of models from Hugging Face Hub (safetensors or GGUF)."""

import argparse
import os
import sys

from huggingface_hub import HfApi, snapshot_download


# ── paths ────────────────────────────────────────────────────────────────────

SAFETENSORS_ROOT = "/shared/models"
GGUF_ROOT = "/shared/models/gguf"


def resolve_local_dir(repo_id: str, local_name: str | None, is_gguf: bool) -> str:
    if is_gguf:
        return GGUF_ROOT  # flat — all .gguf files live side by side
    name = local_name or repo_id.split("/")[-1].lower()
    return os.path.join(SAFETENSORS_ROOT, name)


# ── repo inspection ─────────────────────────────────────────────────────────

def list_gguf_files(repo_id: str, token: str | None) -> list[str]:
    api = HfApi()
    siblings = api.model_info(repo_id, token=token).siblings
    return [s.rfilename for s in siblings if s.rfilename.endswith(".gguf")]


def build_gguf_patterns(all_gguf: list[str], pattern: str) -> list[str]:
    pat = pattern.lower()
    return [f for f in all_gguf if pat in f.lower()]


# ── download ─────────────────────────────────────────────────────────────────

def download_fast(
    repo_id: str,
    local_dir: str,
    token: str | None,
    max_workers: int = 8,
    allow_patterns: list[str] | None = None,
) -> None:
    snapshot_download(
        repo_id=repo_id,
        local_dir=local_dir,
        token=token,
        max_workers=max_workers,
        tqdm_class=None,
        allow_patterns=allow_patterns,
    )


# ── CLI ──────────────────────────────────────────────────────────────────────

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Fast parallel download — MSI Claw 8 AI+ (/shared/models).",
        epilog=(
            "Examples:\n"
            "  download_model_fast.sh Qwen/Qwen2.5-72B-Instruct\n"
            "  download_model_fast.sh bartowski/Qwen2.5-72B-Instruct-GGUF --gguf Q4_K_M\n"
            "  download_model_fast.sh some/model --workers 16\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("repo_id", help="Hugging Face repo (e.g. Qwen/Qwen2.5-72B-Instruct)")
    p.add_argument("local_name", nargs="?", default=None, help="Override output folder name")
    p.add_argument(
        "--gguf",
        metavar="PATTERN",
        default=None,
        help="Download GGUF quant matching PATTERN (e.g. Q4_K_M). "
             "Saves flat to /shared/models/gguf/",
    )
    p.add_argument(
        "--workers",
        type=int,
        default=8,
        help="Number of parallel download threads (default: 8)",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    token = os.environ.get("HF_TOKEN")
    is_gguf = args.gguf is not None
    local_dir = resolve_local_dir(args.repo_id, args.local_name, is_gguf)

    allow_patterns = None
    if is_gguf:
        print(f"Scanning {args.repo_id} for GGUF files...")
        all_gguf = list_gguf_files(args.repo_id, token)
        if not all_gguf:
            print("Error: no .gguf files found in this repo.", file=sys.stderr)
            return 1

        matched = build_gguf_patterns(all_gguf, args.gguf)
        if not matched:
            print(f"Error: no GGUF files matching '{args.gguf}'. Available:", file=sys.stderr)
            for f in all_gguf:
                print(f"  {f}", file=sys.stderr)
            return 1

        print(f"Matched {len(matched)} file(s):")
        for f in matched:
            print(f"  {f}")
        allow_patterns = matched

    print(f"\nDownloading {args.repo_id} -> {local_dir}")
    print(f"Using {args.workers} parallel workers...")

    try:
        download_fast(args.repo_id, local_dir, token, args.workers, allow_patterns)
        print("\nDownload complete!")
        os.system(f"ls -lh {local_dir}")
        os.system(f"du -sh {local_dir}")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        print(f"Partial download saved to: {local_dir}", file=sys.stderr)
        print("Resume by running the same command again.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
PYTHON_SCRIPT
}

# ── main ─────────────────────────────────────────────────────────────────────

if ! find_python; then
    echo "Error: Python 3.9+ is required but not found." >&2
    echo "" >&2
    echo "Install it with one of:" >&2
    echo "  sudo dnf install python3        # Fedora / Nobara" >&2
    echo "  sudo pacman -S python            # Arch / CachyOS" >&2
    echo "  sudo apt install python3 python3-venv  # Ubuntu / Debian" >&2
    exit 1
fi

setup_env
run_download "$@"
