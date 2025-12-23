#!/usr/bin/env python3
from pathlib import Path


def read_props(path: Path):
    data = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("!"):
            continue
        # handle key=value or key: value
        sep = "=" if "=" in line else (":" if ":" in line else None)
        if not sep:
            continue
        k, v = line.split(sep, 1)
        data[k.strip()] = v.lstrip()
    return data


def compare(base_path, ro_path, out_prefix):
    base = read_props(base_path)
    ro = read_props(ro_path)

    missing = [k for k in base.keys() if k not in ro]
    extra = [k for k in ro.keys() if k not in base]

    print(f"\n== {out_prefix} ==")
    print(f"Base keys: {len(base)} | RO keys: {len(ro)}")
    print(f"Missing in RO: {len(missing)} | Extra in RO: {len(extra)}")

    Path(f"{out_prefix}.missing.txt").write_text("\n".join(missing), encoding="utf-8")
    Path(f"{out_prefix}.extra.txt").write_text("\n".join(extra), encoding="utf-8")

    # Template with English placeholders for missing keys
    template_lines = []
    for k, v in base.items():
        if k in ro:
            template_lines.append(f"{k}={ro[k]}")
        else:
            template_lines.append(f"{k}={v}  # TODO: translate")
    Path(f"{out_prefix}.ro.template.properties").write_text(
        "\n".join(template_lines) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    compare(
        Path("MessageResources.properties"),
        Path("MessageResources_ro.properties"),
        "MessageResources",
    )
    # compare(
    #     Path("BahmniMessageResources.properties"),
    #     Path("BahmniMessageResources_ro.properties"),
    #     "BahmniMessageResources",
    # )
