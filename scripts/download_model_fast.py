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
    """Return all .gguf filenames in a repo."""
    api = HfApi()
    siblings = api.model_info(repo_id, token=token).siblings
    return [s.rfilename for s in siblings if s.rfilename.endswith(".gguf")]


def build_gguf_patterns(all_gguf: list[str], pattern: str) -> list[str]:
    """Filter GGUF files matching the user-supplied pattern (case-insensitive).

    Handles both single files and split shards
    (e.g. model-Q4_K_M-00001-of-00003.gguf).
    """
    pat = pattern.lower()
    matched = [f for f in all_gguf if pat in f.lower()]
    return matched


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
        description="Fast parallel download of a model from Hugging Face Hub.",
        epilog=(
            "Examples:\n"
            "  python download_model_fast.py Qwen/Qwen2.5-72B-Instruct\n"
            "  python download_model_fast.py bartowski/Qwen2.5-72B-Instruct-GGUF --gguf Q4_K_M\n"
            "  python download_model_fast.py some/model --workers 16\n"
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

    print(f"\nDownloading {args.repo_id} → {local_dir}")
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
