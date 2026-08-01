#!/usr/bin/env python3
"""Filter a SWE-bench text dataset down to a subset of instance ids."""

import argparse
from datasets import load_from_disk, DatasetDict


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--text-dataset", required=True)
    p.add_argument("--ids", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--split", default="test")
    args = p.parse_args()

    ds = load_from_disk(args.text_dataset)
    wanted = {x.strip() for x in open(args.ids) if x.strip()}
    subset = ds[args.split].filter(lambda x: x["instance_id"] in wanted)

    missing = wanted - set(subset["instance_id"])
    print(f"kept {len(subset)} / {len(ds[args.split])} from split {args.split}")
    if missing:
        print(f"WARNING: {len(missing)} requested ids not found: {sorted(missing)}")

    # run_api loads with load_from_disk and indexes [split], so keep the DatasetDict shape.
    DatasetDict({args.split: subset}).save_to_disk(args.output)
    print(f"saved -> {args.output}")


if __name__ == "__main__":
    main()
