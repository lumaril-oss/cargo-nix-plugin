# Evaluate with: nix-instantiate --eval --strict --expr 'import ./tests/profile-eval.nix { lib = (import <nixpkgs> {}).lib; }'
{ lib }:
let
  flags = (import ../lib/cargo-profile.nix { nixpkgs = { inherit lib; }; }).mkCargoFlags {
    cargoToml = ./profile-fixture/Cargo.toml;
    profile = "ci";
    workspaceMemberNames = [ "app" ];
  };
  args = flags.forCrate { isHost = false; rustcTargetSpec = "x86_64-unknown-linux-gnu"; } {
    crateName = "example-dep";
    crateBin = [ ];
  };
in
assert args.codegenUnits == 8;
assert lib.elem "-Copt-level=2" args.extraRustcOpts;
assert lib.elem "-Clto=off" args.extraRustcOpts;
true
