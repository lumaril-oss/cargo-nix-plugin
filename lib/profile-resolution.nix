# Resolve Cargo profiles with Cargo's parent-before-child merge semantics.
{ lib }:
{ cargoToml, profile ? "release" }:
let
  manifest = builtins.fromTOML (builtins.readFile cargoToml);
  profiles = manifest.profile or { };
  implicitParents = { bench = "release"; test = "dev"; doc = "dev"; debug = "dev"; };
  exists = name: name == "release" || name == "dev" || builtins.hasAttr name profiles || builtins.hasAttr name implicitParents;
  chain = seen: name:
    let
      table = profiles.${name} or { };
      parent = table.inherits or (implicitParents.${name} or null);
    in
    if builtins.elem name seen then
      throw "cargo-nix-plugin: profile inheritance cycle at ${name}"
    else if !exists name then
      throw "cargo-nix-plugin: undefined Cargo profile ${name}"
    else if name == "release" || name == "dev" then
      if table ? inherits then throw "cargo-nix-plugin: root profile ${name} may not inherit" else [ table ]
    else if parent == null then
      throw "cargo-nix-plugin: custom profile ${name} requires inherits"
    else [ table ] ++ chain (seen ++ [ name ]) parent;
in
  builtins.removeAttrs
    (lib.foldl' lib.recursiveUpdate { } (lib.reverseList (chain [ ] profile)))
    [ "inherits" ]
