fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    let udl_path = format!("{manifest_dir}/minigit_core.udl");
    uniffi::generate_scaffolding_for_crate(&udl_path, "minigit_core").unwrap();
}
