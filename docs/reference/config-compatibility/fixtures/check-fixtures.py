"""Offline integrity check for synthetic research artifacts, not a config engine."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent
load = lambda name: json.loads((root / name).read_text(encoding="utf-8"))
base = load("base.yaml")
expected = load("expected-mobile.yaml")
catalog = load("cases.json")
assert catalog["syntheticOnly"] and not catalog["networkAllowed"]
assert not catalog["examplesRunnable"]
assert len({case["id"] for case in catalog["cases"]}) == len(catalog["cases"])
for case in catalog["cases"]:
    for key in ("file", "baseFile", "expectedFile", "providerSnapshotFile"):
        if key in case:
            load(case[key])
assert expected["proxies"] == base["proxies"], "node fields changed"
groups = {g["name"]: g for g in expected["proxy-groups"]}
assert len(groups) == len(expected["proxy-groups"]), "duplicate groups"
nodes = {p["name"] for p in expected["proxies"]}
targets = nodes | set(groups) | {"DIRECT", "REJECT"}
for group in groups.values():
    assert all(ref in targets for ref in group.get("proxies", []))
for rule in expected["rules"]:  # These fixtures contain only simple DOMAIN/MATCH.
    assert rule.split(",")[0] in {"DOMAIN", "MATCH"}
    assert rule.split(",")[-1] in targets
assert expected["rules"][-2:] == base["rules"], "base precedence changed"
pool = lambda g: sorted(n for n in nodes if re.search(g.get("filter", ".*"), n)
                        and not re.search(g["exclude-filter"], n))
assert "filter" not in groups["全网优选"]
assert "德国 SYN A" in pool(groups["全网优选"])
assert "HK SYN A" in pool(groups["香港优选"])
auto = groups["ChatGPT自动"]
assert auto["type"] == "fallback" and "proxies" not in auto
assert pool(auto) == ["美国 SYN A", "美国 SYN B"]
assert auto["expected-status"] == "200" and not auto["lazy"]
assert groups["Google自动"]["proxies"] == ["日本优选", "新加坡优选", "美国优选"]
assert groups["AI普通服务"]["proxies"][0] == "日本优选"
assert groups["AI普通服务"]["proxies"][-1] == "全网优选"
for name in ["香港优选", "新加坡优选", "日本优选", "美国优选", "全网优选"]:
    assert groups[name]["type"] == "url-test"
    assert pool(groups[name]), "empty required region"
provider = load("provider-config.yaml")
assert "proxy-providers" in provider and "rules" in provider
assert set(load("provider-payload.yaml")) == {"proxies"}
assert catalog["mergeDialect"] == "clash-verge-merge-2.5.8"
merge_base = load("merge-base.yaml")
overlay = load("merge.yaml")
merge_expected = load("merge-expected.yaml")
# Check declared artifacts, not a reimplementation of the Merge algorithm.
for key in ("proxies", "proxy-groups", "listeners"):
    assert merge_expected[key] == overlay[key], "named array must replace"
    assert len(merge_expected[key]) < len(merge_base[key])
assert "udp" not in merge_expected["proxies"][0], "old named fields leaked"
assert "fallback" in merge_expected["dns"]
assert merge_expected["dns"]["fallback"] is None, "null key must remain"
for key in ("nameserver-policy", "fallback-filter"):
    assert merge_expected["dns"][key] == overlay["dns"][key]
assert merge_expected["hosts"] == overlay["hosts"]
assert merge_expected["dns"]["nameserver"] == merge_base["dns"]["nameserver"]
assert merge_expected["tun"] == {"mtu": 1500, "stack": "mixed"}
for doc in [root / "usage.md", root.parent / "spec.md", root.parent / "engine-interface.md"]:
    for link in re.findall(r"\]\(([^)]+)\)", doc.read_text(encoding="utf-8")):
        if "://" not in link:
            assert (doc.parent / link.split("#")[0]).exists(), f"broken link: {link}"
print(f"PASS: {len(catalog['cases'])} scenario declarations; synthetic pools, references, preservation, Verge Merge expectations and links")
