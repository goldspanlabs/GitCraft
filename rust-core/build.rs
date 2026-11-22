fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let udl_path = format!("{manifest_dir}/minigit_core.udl");
    uniffi::generate_scaffolding(&udl_path).unwrap();

    // Ensure checksum symbols match the crate name `minigit_core` even though
    // the parent directory is named `rust-core`.
    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR not set");
    let rs_path = format!("{out_dir}/minigit_core.uniffi.rs");
    let content = std::fs::read_to_string(&rs_path).unwrap();
    let fixed = content.replace(
        "uniffi_rust_core_checksum_",
        "uniffi_minigit_core_checksum_",
    );
    std::fs::write(&rs_path, fixed).unwrap();
}
