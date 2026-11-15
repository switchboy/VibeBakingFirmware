"""Which staged vendor tree the build consumes - the single SHAPE knob (D44 decided Nov 15, D46).

  SHAPE=a10 (default, shape A, the primary) -> vendor/hct4/tree_a10/vendor, staged from the Android 10
      firmware the head unit actually runs (kernel #190, modules vermagic 4.19.111+, manifest target-level 4)
  SHAPE=a11 (shape B, the fallback)         -> vendor/hct4/tree/vendor, staged from the Android 11 package
      (kernel 4.19.193 #24, modules vermagic 4.19.193, manifest target-level 5)

Kernel, `.ko` vermagic and manifest target-level move together, so every consumer has to read the same
knob or an audit tool checks the wrong tree: scripts/prebuilt_vendor.sh, scripts/deploy_device.sh,
scripts/package.sh, scripts/verify_artifacts.sh, BoardConfig.mk's HCT4_KERNEL, and the three auditters
that import this file (vendor_link_closure.py, vendor_abi_check.py, consumer_abi_check.py).
"""
import os

SHAPES = {"a10": ("tree_a10", "Android 10"), "a11": ("tree", "Android 11")}


def shape():
    s = os.environ.get("SHAPE", "a10")
    if s not in SHAPES:
        raise SystemExit("SHAPE must be a10 or a11 (got %r): shape A is the primary, shape B the fallback" % s)
    return s


def staged_vendor_root(tree):
    """The extracted vendor partition the build stages, for the current SHAPE."""
    return os.path.join(tree, "vendor", "hct4", SHAPES[shape()][0], "vendor")


def label():
    """Which stock firmware the staged tree came from - used in reports and generated headers."""
    return SHAPES[shape()][1]
