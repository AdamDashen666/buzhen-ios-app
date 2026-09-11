from pathlib import Path

root = Path("source/CodexPad")
pbx_path = root / "CodexPad.xcodeproj/project.pbxproj"
pbx = pbx_path.read_text()

build_id = "F0A1B2C3D4E5F60718293A4B"
ref_id = "A1B2C3D4E5F60718293A4B5C"

if "ModelAutoSelector.swift in Sources" not in pbx:
    build_anchor = '\t\tDED57E3A1C9E12972041B783 /* AgentTools.swift in Sources */ = {isa = PBXBuildFile; fileRef = 2229EDF85325CA5D6D2B38E9 /* AgentTools.swift */; };'
    file_anchor = '\t\t2229EDF85325CA5D6D2B38E9 /* AgentTools.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentTools.swift; sourceTree = "<group>"; };'
    group_anchor = '\t\t\t\t2229EDF85325CA5D6D2B38E9 /* AgentTools.swift */,'
    sources_anchor = '\t\t\tDED57E3A1C9E12972041B783 /* AgentTools.swift in Sources */,'

    for anchor in (build_anchor, file_anchor, group_anchor, sources_anchor):
        if anchor not in pbx:
            raise RuntimeError(f"Xcode project anchor missing: {anchor}")

    pbx = pbx.replace(
        build_anchor,
        build_anchor + f'\n\t\t{build_id} /* ModelAutoSelector.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* ModelAutoSelector.swift */; }};',
        1,
    )
    pbx = pbx.replace(
        file_anchor,
        file_anchor + f'\n\t\t{ref_id} /* ModelAutoSelector.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ModelAutoSelector.swift; sourceTree = "<group>"; }};',
        1,
    )
    pbx = pbx.replace(group_anchor, group_anchor + f'\n\t\t\t\t{ref_id} /* ModelAutoSelector.swift */,', 1)
    pbx = pbx.replace(sources_anchor, sources_anchor + f'\n\t\t\t{build_id} /* ModelAutoSelector.swift in Sources */,', 1)
    pbx_path.write_text(pbx)

# Keep the Release build warning-clean for the background file I/O helpers.
store_path = root / "CodexPad/Services/WorkspaceStore.swift"
store = store_path.read_text()
for old in (
    '        try await Self.runFileIO(root: root) { url in\n            try WorkspaceFileService(rootURL: url).writeText(path: path, content: textToSave, createIfMissing: false)',
    '        try await Self.runFileIO(root: root) { url in\n            try WorkspaceFileService(rootURL: url).writeText(path: path, content: content, createIfMissing: createIfMissing)',
    '        try await Self.runFileIO(root: root) { url in\n            try WorkspaceFileService(rootURL: url).delete(path: path)',
    '        try await Self.runFileIO(root: root) { url in\n            try WorkspaceFileService(rootURL: url).move(from: from, to: to)',
):
    if old in store:
        store = store.replace(old, old.replace('        try await', '        _ = try await'), 1)
store_path.write_text(store)

# Hard verification: the model selector must be both referenced and compiled by the app target.
final_pbx = pbx_path.read_text()
if final_pbx.count("ModelAutoSelector.swift") < 4:
    raise RuntimeError("ModelAutoSelector.swift was not fully added to the Xcode app target")
print("Applied CodexPad Xcode target integration fix")
