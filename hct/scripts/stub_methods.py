#!/usr/bin/env python3
"""Replace the bodies of HCTApi methods that use Android-10 stack APIs / ActivityManager$StackInfo.

Signatures, access flags and the method list are untouched: only the region between `.method ...`
and `.end method` is rewritten into a minimal stub (no logging, no framework call, adjusted
.registers). Methods are matched by their exact signature (name+descriptor), which is unique per class.

Usage: stub_methods.py <smali file> [<smali file> ...]
"""
import re
import sys

# signature -> stub body (everything after the .method directive)
STUBS = {
    # gone in A14: IActivityManager.getAllStackInfos() -> empty list, never null (callers iterate)
    "getAllStackInfos()Ljava/util/List;": [
        "    .registers 1",
        "",
        "    new-instance v0, Ljava/util/ArrayList;",
        "",
        "    invoke-direct {v0}, Ljava/util/ArrayList;-><init>()V",
        "",
        "    return-object v0",
    ],
    # gone: IActivityManager.getFocusedStackInfo() -> no focused stack info
    "getFocusedStackInfo()Landroid/app/ActivityManager$StackInfo;": [
        "    .registers 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ],
    # StackInfo-typed readers: no instruction may touch Landroid/app/ActivityManager$StackInfo;
    "getFocusedStackId()I": [
        "    .registers 1",
        "",
        "    const/4 v0, -0x1",
        "",
        "    return v0",
    ],
    "getFocusedStackpackage()Ljava/lang/String;": [
        "    .registers 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ],
    "getStackComponentName(I)Landroid/content/ComponentName;": [
        "    .registers 2",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ],
    "getStackTopPackage(I)Ljava/lang/String;": [
        "    .registers 2",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ],
    "isVisibleFreeForm()Z": [
        "    .registers 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
    # gone: IActivityTaskManager.getStackInfo(II) used to pick the split-screen windowing mode
    "isWindowAppInSplitScreenPrimary(Landroid/content/Context;)Z": [
        "    .registers 2",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
    "isWindowAppInSplitScreenSecondary(Landroid/content/Context;)Z": [
        "    .registers 2",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
    # gone: IActivityManager/IActivityTaskManager stack control methods -> do nothing
    "moveStackToDisplay(II)V": [
        "    .registers 2",
        "",
        "    return-void",
    ],
    "removeStack(I)V": [
        "    .registers 1",
        "",
        "    return-void",
    ],
    "setFocusedStack(I)V": [
        "    .registers 1",
        "",
        "    return-void",
    ],
    # HCT-added AIDL (IActivityTaskManager.switchDualScreen / hasSecondScreenActivityStack):
    # no A14 equivalent, so the client-side wrappers become inert
    "switchDualScreen()V": [
        "    .registers 1",
        "",
        "    return-void",
    ],
    "hasSecondScreenActivityStack()Z": [
        "    .registers 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
    # DisplayMetrics.setToDefaultsDensity(IF) was an HCT-added member; the wrapper just hands
    # back the Resources it was given (ContextImpl.setResources() hook must not see null)
    "getHCTResource(Landroid/content/Context;Landroid/content/res/Resources;Ljava/lang/String;)"
    "Landroid/content/res/Resources;": [
        "    .registers 3",
        "",
        "    return-object p1",
    ],
}

METHOD_START = re.compile(r"^\.method\b")
METHOD_END = re.compile(r"^\.end method\b")


def signature_of(method_line):
    m = re.search(r"(\w[\w$]*\((?:[A-Za-z0-9_/.$\[\];]*)\)[A-Za-z0-9_/.$\[\];]*)$",
                  method_line.strip())
    return m.group(1) if m else None


def stub_file(path):
    lines = open(path, "r", encoding="utf-8").read().splitlines(True)
    out = []
    done = []
    i = 0
    while i < len(lines):
        if METHOD_START.match(lines[i]):
            sig = signature_of(lines[i])
            end = i
            while not METHOD_END.match(lines[end]):
                end += 1
            if sig in STUBS:
                out.append(lines[i])
                out.append("".join(s + "\n" for s in STUBS[sig]))
                # blank line before .end method, like baksmali's output
                out.append("\n")
                out.append(lines[end])
                done.append(sig)
                i = end + 1
                continue
        out.append(lines[i])
        i += 1
    if done:
        open(path, "w", encoding="utf-8").write("".join(out))
    return done


def main():
    for p in sys.argv[1:]:
        done = stub_file(p)
        print(f"{p}: {len(done)} method bodies stubbed")
        for s in done:
            print("  " + s)


if __name__ == "__main__":
    main()
