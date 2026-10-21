#!/usr/bin/env python3
"""Print the OS / SystemOS / AppOS disk image paths of an IPSW BuildManifest.

  ipsw-paths.py BuildManifest.plist

The Erase identity of the iPhone X (d22ap) is used, like the upstream
tools/mkiosroot.sh expects.
"""
import plistlib
import sys


def main():
    d = plistlib.load(open(sys.argv[1], "rb"))
    best = None
    for ident in d["BuildIdentities"]:
        info = ident.get("Info", {})
        if info.get("DeviceClass") != "d22ap":
            continue
        if info.get("RestoreBehavior") != "Erase":
            continue
        m = ident["Manifest"]
        try:
            paths = {
                "OS": m["OS"]["Info"]["Path"],
                "SystemOS": m["Cryptex1,SystemOS"]["Info"]["Path"],
                "AppOS": m["Cryptex1,AppOS"]["Info"]["Path"],
            }
        except KeyError:
            continue
        if best is None:
            best = paths
    if best is None:
        sys.exit("no d22ap Erase identity in the manifest")
    print(best["OS"], best["SystemOS"], best["AppOS"])


if __name__ == "__main__":
    main()
