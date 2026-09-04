//! The behaviour factory.
//!
//! An atomic behaviour is one decision the system makes — how to chunk, how
//! to blend two scores, when to re-index — described by three YAML files in
//! its own folder under `src/behaviors/`:
//!
//! ```
//! src/behaviors/chunking/
//!   manifest.yml   identity: name, version, stability, composition, parity
//!   schema.yml     shape and rules: fields, types, constraints, invariants
//!   config.yml     values: what this profile actually wants
//!   ops.zig        (optional) hand-written pure derivations
//! ```
//!
//! `behaviors.zig` hands those three documents to `module.Module`, which
//! reads them **while the compiler runs** and returns a namespace whose
//! `Config` struct exists nowhere in the source tree. Field names, field
//! types, default values and the body of `validate()` are all derived from
//! the descriptors, so the generated module is exactly as cheap as a
//! hand-written struct — the YAML never reaches the binary.
//!
//! Why split three ways rather than one file: the three change for different
//! reasons and by different people. Rules change when the algorithm changes;
//! values change per deployment; identity changes when a behaviour is
//! promoted, renamed or recomposed. Keeping them apart is what makes a
//! behaviour genuinely swappable — point the factory at a different
//! `config.yml` and you get a different module out, with the same rules.
//!
//! Submodules:
//!
//!   * `yaml`     — an allocation-free YAML subset parser that runs at comptime
//!   * `schema`   — `schema.yml` → field/constraint/invariant IR
//!   * `manifest` — `manifest.yml` → identity IR
//!   * `module`   — the generator itself

pub const yaml = @import("factory/yaml.zig");
pub const schema = @import("factory/schema.zig");
pub const manifest = @import("factory/manifest.zig");
pub const module = @import("factory/module.zig");

/// Convenience re-exports for the two things callers touch most.
pub const Sources = module.Sources;
pub const Module = module.Module;

test {
    _ = yaml;
    _ = schema;
    _ = manifest;
    _ = module;
}
