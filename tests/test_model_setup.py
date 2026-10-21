import hashlib
import io
import json
import plistlib
from pathlib import Path

import audience_package
import build_native
import download_models
import generate_project
import phonon_package
import pytest
import setup
from bundle_runtime import bundle_models
from mobile_app.duo import CAST


def phonon_files(root):
    for name in phonon_package.PHONON_FILES:
        path = root / "models/phonon" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"phonon fixture")
    for path in phonon_package.voice_files(root):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"voice fixture")


def audience_files(root, release="rc2.1"):
    package = root / "models/audience"
    for name in audience_package.MODELS:
        (package / name / "Data").mkdir(parents=True, exist_ok=True)
    (package / "tokenizer.json").write_text("{}")
    (package / "config.json").write_text(json.dumps({"render_version": "addressee-tt-0.6"}))
    (package / "coreml.json").write_text(json.dumps({"release": release}))


def test_audience_package_is_validated_and_compiled_once(tmp_path, monkeypatch):
    with pytest.raises(RuntimeError, match="models/audience/.*AudienceEncoder.mlpackage"):
        audience_package.validate_audience(tmp_path)
    audience_files(tmp_path, release="rc1")
    with pytest.raises(RuntimeError, match="'rc1'"):
        audience_package.validate_audience(tmp_path)
    audience_files(tmp_path)
    assert audience_package.validate_audience(tmp_path)["release"] == "rc2.1"
    compiled = []

    def compile_model(args, **kwargs):
        compiled.append(args)
        source, out = Path(args[-2]), Path(args[-1])
        (out / source.name.replace(".mlpackage", ".mlmodelc")).mkdir()

    monkeypatch.setattr(audience_package.subprocess, "run", compile_model)
    bundle = tmp_path / "App.app"
    audience_package.bundle_audience(bundle, tmp_path)
    audience_package.bundle_audience(bundle, tmp_path)
    assert [args[:3] for args in compiled] == [["xcrun", "coremlcompiler", "compile"]] * 2
    assert sorted(p.name for p in (bundle / "audience").iterdir()) == [
        "AudienceEncoder.mlmodelc",
        "AudienceHead.mlmodelc",
        "config.json",
        "coreml.json",
        "tokenizer.json",
    ]


def test_setup_requires_and_bundles_the_voices_the_cast_speaks_in():
    assert phonon_package.PHONON_VOICES == tuple(character.voice for character in CAST.values())
    assert all(path.is_file() for path in phonon_package.voice_files())


def test_packaging_requires_phonon_and_copies_only_model_assets(tmp_path):
    bundle = tmp_path / "App.app"
    with pytest.raises(RuntimeError, match="models/phonon/"):
        bundle_models(bundle, root=tmp_path)
    phonon_files(tmp_path)
    package = tmp_path / "models/phonon"
    for extra in [
        "voices/en_us_Marlowe.safetensors",
        "voices/voices.jsonl",
        "default-voice.safetensors",
        "tokenizer.model",
    ]:
        (package / extra).parent.mkdir(parents=True, exist_ok=True)
        (package / extra).write_bytes(b"not bundled")
    (bundle / "phonon").mkdir(parents=True)
    (bundle / "phonon/stale.bin").write_bytes(b"stale")
    bundle_models(bundle, root=tmp_path)
    bundled = sorted(
        str(path.relative_to(bundle / "phonon"))
        for path in (bundle / "phonon").rglob("*")
        if path.is_file()
    )
    assert bundled == [
        "config.json",
        "model.q8.gguf",
        "tokenizer.json",
        "voices/Angel_F01.safetensors",
        "voices/Devil_01.safetensors",
    ]


def test_model_download_checks_each_file_and_keeps_another_checkpoint(tmp_path, monkeypatch):
    phonon, audience = download_models.MODELS.values()
    assert set(phonon[4]) == set(phonon_package.PHONON_FILES)
    assert {path.split("/", 1)[0] for path in audience[4]} == {
        *audience_package.MODELS,
        *audience_package.DATA,
    }
    served, models = {}, {}
    for name, (repo, revision, prefix, folder, files) in download_models.MODELS.items():
        pinned = {}
        for path in files:
            url = f"https://huggingface.co/{repo}/resolve/{revision}/{prefix}{path}"
            served[url] = json.dumps(
                {"release": "rc2.1", "render_version": "addressee-tt-0.6", "file": path}
            ).encode()
            pinned[path] = hashlib.sha256(served[url]).hexdigest()
        models[name] = (repo, revision, prefix, folder, pinned)
    monkeypatch.setattr(download_models, "MODELS", models)
    monkeypatch.setattr(download_models, "ROOT", tmp_path)
    requested = []

    def urlopen(url):
        requested.append(url)
        return io.BytesIO(served[url])

    monkeypatch.setattr(download_models.urllib.request, "urlopen", urlopen)

    def download(*flags):
        monkeypatch.setattr("sys.argv", ["download_models.py", *flags])
        download_models.main()

    checkpoint = tmp_path / "models/phonon"
    checkpoint.mkdir(parents=True)
    (checkpoint / "config.json").write_text(
        json.dumps({"model_id": {"sig": "0e03182e", "epoch": 200}})
    )
    with pytest.raises(SystemExit, match="models/phonon/ holds another model \\(0e03182e@200\\)"):
        download()
    assert requested == []
    download("--replace")
    assert requested == list(served)
    assert audience_package.validate_audience(tmp_path)["release"] == "rc2.1"
    requested.clear()
    download()
    assert requested == []
    weights = tmp_path / "models/audience/AudienceHead.mlpackage/Data/com.apple.CoreML/weights"
    (weights / "weight.bin").write_bytes(b"truncated")
    served[
        next(
            url
            for url in served
            if url.endswith("AudienceHead.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        )
    ] = b"corrupted on the way"
    with pytest.raises(SystemExit, match="weight.bin does not match"):
        download()
    assert [path.name for path in weights.iterdir()] == ["weight.bin"]


def test_native_build_compiles_phonon_and_pydantic_core(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(build_native, "ROOT", tmp_path)
    monkeypatch.setattr(build_native, "run", lambda args, **kw: calls.append(args))
    monkeypatch.setattr(build_native.subprocess, "check_output", lambda *a, **kw: "/SDK\n")
    build_native.build("simulator")
    manifests = [str(command[command.index("--manifest-path") + 1]) for command in calls]
    assert any("phonon-ffi" in path for path in manifests)
    assert any("pydantic_core" in path for path in manifests)


def test_project_generation_links_phonon_without_packages(tmp_path, monkeypatch):
    (tmp_path / "src/ios/PipecatVoice").mkdir(parents=True)
    monkeypatch.setattr(generate_project, "ROOT", tmp_path)
    generate_project.main()
    objects = list(generate_project.objects.values())
    assert not any(x["isa"].startswith("XCRemoteSwiftPackage") for x in objects)
    assert not any("packageReferences" in x for x in objects)
    target = [
        x["buildSettings"]
        for x in objects
        if x["isa"] == "XCBuildConfiguration" and "PRODUCT_BUNDLE_IDENTIFIER" in x["buildSettings"]
    ]
    assert len(target) == 2
    for settings in target:
        assert "-lphonon_ffi" in settings["OTHER_LDFLAGS"]
        assert "$(SRCROOT)/native/phonon-ffi/include" in settings["HEADER_SEARCH_PATHS"]
    # Phonon needs no key, so there is no xcconfig to carry one into Info.plist.
    assert not any(x.get("lastKnownFileType") == "text.xcconfig" for x in objects)
    assert not any("baseConfigurationReference" in x for x in objects)
    info = plistlib.loads((tmp_path / "src/ios/PipecatVoice/Info.plist").read_bytes())
    assert "GradiumAPIKey" not in info
    assert info["CADisableMinimumFrameDurationOnPhone"] is True
    bundle_phase = next(x for x in objects if x.get("name") == "Bundle Python, Phonon and Audience")
    assert bundle_phase["outputPaths"] == [
        "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/PythonRuntime.stamp"
    ]
    assert bundle_phase["alwaysOutOfDate"] == 1


def test_project_generation_bundles_the_privacy_manifest(tmp_path, monkeypatch):
    sources = tmp_path / "src/ios/PipecatVoice"
    sources.mkdir(parents=True)
    (sources / "PrivacyInfo.xcprivacy").write_text("<plist/>")
    monkeypatch.setattr(generate_project, "ROOT", tmp_path)
    generate_project.main()
    objects = generate_project.objects
    manifest = next(key for key, x in objects.items() if x.get("path") == "PrivacyInfo.xcprivacy")
    resources = next(x for x in objects.values() if x["isa"] == "PBXResourcesBuildPhase")
    assert any(objects[build]["fileRef"] == manifest for build in resources["files"])


def test_the_privacy_manifest_declares_no_tracking_and_each_required_reason_api():
    path = Path(generate_project.ROOT) / "src/ios/PipecatVoice/PrivacyInfo.xcprivacy"
    manifest = plistlib.loads(path.read_bytes())
    assert manifest["NSPrivacyTracking"] is False
    assert (
        manifest["NSPrivacyTrackingDomains"] == [] and manifest["NSPrivacyCollectedDataTypes"] == []
    )
    reasons = {
        entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
        for entry in manifest["NSPrivacyAccessedAPITypes"]
    }
    # Settings and the profile (UserDefaults), the stage's and the player's clocks (boot time),
    # the embedded Python runtime's module lookups (file timestamps), and its `statfs`, which
    # it links though the app never calls it (disk space).
    assert reasons == {
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
    }


@pytest.mark.parametrize("quoted", [False, True])
def test_project_regeneration_preserves_signing_team(tmp_path, monkeypatch, quoted):
    (tmp_path / "src/ios/PipecatVoice").mkdir(parents=True)
    project = tmp_path / "PipecatVoice.xcodeproj/project.pbxproj"
    project.parent.mkdir()
    project.write_text(
        '"DEVELOPMENT_TEAM" = "ABC1234567";' if quoted else "DEVELOPMENT_TEAM = ABC1234567;"
    )
    monkeypatch.setattr(generate_project, "ROOT", tmp_path)
    generate_project.main()
    targets = [
        obj["buildSettings"]
        for obj in generate_project.objects.values()
        if obj["isa"] == "XCBuildConfiguration"
        and "PRODUCT_BUNDLE_IDENTIFIER" in obj["buildSettings"]
    ]
    assert len(targets) == 2
    assert all(settings["DEVELOPMENT_TEAM"] == "ABC1234567" for settings in targets)


def test_setup_validates_phonon_before_building(tmp_path, monkeypatch):
    (tmp_path / "Vendor/Python.xcframework").mkdir(parents=True)
    (tmp_path / f".build/pydantic_core-{build_native.PYDANTIC_CORE_VERSION}").mkdir(parents=True)
    calls = []
    monkeypatch.setattr(setup, "ROOT", tmp_path)
    monkeypatch.setattr(setup.sys, "argv", ["setup.py", "--platform", "simulator"])
    monkeypatch.setattr(setup, "run", lambda *args: calls.append(tuple(map(str, args))))
    monkeypatch.setattr(setup, "fetch", lambda url, digest: url)
    monkeypatch.setattr(setup, "patch_pipecat", lambda wheel, root: None)
    with pytest.raises(SystemExit, match="models/phonon/"):
        setup.main()
    assert calls == []
    phonon_files(tmp_path)
    with pytest.raises(SystemExit, match="models/audience/"):
        setup.main()
    assert calls == []
    audience_files(tmp_path)
    setup.main()
    native = next(
        call for call in calls if any(x.endswith("scripts/build_native.py") for x in call)
    )
    assert native[-2:] == ("--platform", "simulator")


def test_setup_can_prepare_only_pipecat_without_the_models(tmp_path, monkeypatch):
    calls, prepared = [], []
    monkeypatch.setattr(setup, "ROOT", tmp_path)
    monkeypatch.setattr(setup.sys, "argv", ["setup.py", "--pipecat-only"])
    monkeypatch.setattr(setup, "run", lambda *args: calls.append(args))
    monkeypatch.setattr(setup, "fetch", lambda url, digest: (url, digest))
    monkeypatch.setattr(setup, "patch_pipecat", lambda wheel, root: prepared.append((wheel, root)))
    setup.main()
    assert prepared == [((setup.PIPECAT_URL, setup.PIPECAT_SHA256), tmp_path)]
    assert calls == []
