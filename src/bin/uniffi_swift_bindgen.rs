use std::process;

use uniffi_bindgen::bindings::{SwiftBindingsOptions, generate_swift_bindings};

fn main() {
    if let Err(err) = run() {
        eprintln!("failed to generate swift bindings: {err:?}");
        process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let library_path = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("missing library path argument"))?;
    let out_dir = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("missing output directory argument"))?;

    let module_name = args.next();

    let options = SwiftBindingsOptions {
        generate_swift_sources: true,
        generate_headers: true,
        generate_modulemap: true,
        library_path: library_path.into(),
        out_dir: out_dir.into(),
        module_name,
        ..Default::default()
    };

    generate_swift_bindings(options)
}
