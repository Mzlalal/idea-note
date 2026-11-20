fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        build_macos_panels();
    }
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        // The tray menu imports Common Controls v6. Use a linker manifest
        // for the app and for unit tests, which link directly to the library.
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTDEPENDENCY:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'");
        tauri_build::try_build(
            tauri_build::Attributes::new()
                .windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest()),
        )
        .expect("failed to build Tauri application resources");
    } else {
        tauri_build::build();
    }
}

fn build_macos_panels() {
    use std::{env, fs, path::PathBuf, process::Command};

    println!("cargo:rerun-if-changed=macos-panels");
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR"));
    let architecture = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        other => panic!("Unsupported macOS architecture: {other:?}"),
    };
    let target = format!("{architecture}-apple-macosx10.15");
    let mut sources: Vec<_> = fs::read_dir("macos-panels")
        .expect("read macOS panel sources")
        .map(|entry| entry.expect("read Swift source entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "swift"))
        .collect();
    sources.sort();

    let status = Command::new("xcrun")
        .args(["--sdk", "macosx", "swiftc", "-swift-version", "6", "-target", &target])
        .args(["-emit-library", "-static", "-module-name", "LiteNotePanels", "-O", "-o"])
        .arg(out.join("libLiteNotePanels.a"))
        .args(&sources)
        .status()
        .expect("run Swift compiler for macOS panels");
    assert!(status.success(), "Swift could not build the macOS panels");

    let compiler = Command::new("xcrun")
        .args(["--sdk", "macosx", "--find", "swiftc"])
        .output()
        .expect("locate swiftc");
    assert!(compiler.status.success(), "xcrun could not locate swiftc");
    let compiler = String::from_utf8(compiler.stdout).expect("Swift compiler path");
    let toolchain = std::path::Path::new(compiler.trim()).parent().unwrap().parent().unwrap();

    // Rust's optimized link uses -nodefaultlibs. Swift's availability checks
    // still need the platform-version helper provided by Clang's runtime.
    let runtime = Command::new("xcrun")
        .args(["--sdk", "macosx", "clang", "-print-resource-dir"])
        .output()
        .expect("locate Clang runtime");
    assert!(runtime.status.success(), "xcrun could not locate Clang runtime");
    let runtime = String::from_utf8(runtime.stdout).expect("Clang runtime path");
    let runtime = PathBuf::from(runtime.trim()).join("lib/darwin");
    println!("cargo:rustc-link-search=native={}", runtime.display());
    println!("cargo:rustc-link-lib=static=clang_rt.osx");

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-search=native={}", toolchain.join("lib/swift/macosx").display());
    println!("cargo:rustc-link-search=native=/usr/lib/swift");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");

    println!("cargo:rustc-link-lib=static=LiteNotePanels");
    println!("cargo:rustc-link-lib=framework=Carbon");
    println!("cargo:rustc-link-lib=framework=SwiftUI");
    println!("cargo:rustc-link-lib=framework=ApplicationServices");
}
