{ nixpkgs }:

let
  # System-independent library. Pure evaluation — nothing here builds a
  # derivation, so consumers need no `pkgs`.
  lib = {
    # Derives cargo-nix-plugin build arguments from the files cargo itself
    # reads.
    #
    # cargo-nix-plugin compiles every crate by invoking rustc directly, and
    # reads neither [profile.*] nor .cargo/config.toml. Anything set there
    # is invisible to `nix build` unless it is replayed as an explicit
    # buildRustCrate argument, so a profile's `lto` or `codegen-units` can
    # silently apply to `cargo build --release` and not to the nix-built
    # binary. Deriving the arguments here keeps one source of truth: edit
    # the profile or the target rustflags, and both build paths follow.
    #
    # Flag placement mirrors `cargo build --release -v`, which scopes all
    # of it to target units. Under a profile of `opt-level = 3`,
    # `codegen-units = 1`, `lto = true`:
    #
    #   target dep rlib   -Copt-level=3 -Ccodegen-units=1 -Clinker-plugin-lto
    #   target bin        -Copt-level=3 -Ccodegen-units=1 -Clto=fat
    #   target proc-macro
    #   cdylib, dylib,
    #   and their deps    -Copt-level=3 -Ccodegen-units=1 and no more:
    #                     rustc links these, and a link consumes its
    #                     dependencies' objects, so the bitcode-only output
    #                     -Clinker-plugin-lto asks for is unusable across
    #                     that closure — while an LTO'd binary depending on
    #                     the same crate still needs its bitcode. Only
    #                     rustc's default emits both. Needs
    #                     `linkingCrateClosure`.
    #   host build.rs     neither codegen-units nor lto — cargo compiles
    #                     host units under build-override, which inherits
    #                     neither
    #
    # The one deliberate divergence is .cargo/config.toml's rustflags.
    # Given no --target, cargo applies those to host units as well; here
    # they reach target units only, so a `-Ctarget-cpu` never reaches build
    # scripts and proc-macros executing on a builder older than the
    # deployment target.
    #
    # Returns { forCrate, relaxOpts }. `forCrate` is a function from
    # per-unit context ({ isHost, rustcTargetSpec }) to a buildRustCrate-args
    # transformer, shaped to slot into cargo-nix-plugin's
    # `buildRustCrateForPkgs`. `relaxOpts` gives back the cost knobs for
    # units built only to be checked, never shipped.
    mkCargoFlags =
      {
        lib ? nixpkgs.lib,
        # Workspace root Cargo.toml, source of [profile.<profile>].
        cargoToml,
        # .cargo/config.toml, source of the per-target rustflags. Optional.
        cargoConfig ? null,
        # Profile to replay, resolved through `inherits` as cargo does. Its
        # chain must end at `release`: build-rust-crate compiles with
        # `release = true`, so that is what its output corresponds to.
        profile ? "release",
        # Crates whose rustc invocations link binaries — the units that
        # receive the profile's `-Clto`. Cross-crate LTO only takes effect
        # there: rustc accepts -Clto while emitting an rlib but ignores it.
        # Every other target unit gets the rlib half of the same setting
        # instead, which is what decides whether it carries bitcode.
        #
        # null (the default) auto-detects: cargo-nix-plugin resolves every
        # dependency edge to a lib-only variant marked by an explicit
        # `crateBin = [ ]`, and omits crateBin on the with-bins roots it
        # exposes as workspaceMembers.<name>.build, so a call without a
        # crateBin argument is one that links whatever binaries the crate
        # has. A pure-lib member's root variant then carries an -Clto
        # rustc ignores; dependency derivations are untouched either way.
        # Set a list of crate names to pin the targeting instead.
        binCrateNames ? null,
        # Workspace member crate names, which [profile.*.package."*"] must
        # exclude to match cargo. Only consulted when the profile has that
        # wildcard. null (the default) derives them from [workspace].members
        # by reading each member's own [package].name.
        workspaceMemberNames ? null,
        # Crates whose library target is a proc-macro, cdylib or dylib,
        # closed over their dependencies. rustc links those units, and a
        # link consumes its dependencies' objects too, so nothing in the
        # closure can be built bitcode-only. `-Clinker-plugin-lto` is
        # withheld from all of it, and not replayed at all while this is
        # null, since guessing wrong breaks the build.
        # `nix-cargo-metadata.lib.linkingCrateClosureNames` computes it.
        linkingCrateClosure ? null,
      }:
      let
        cargoTomlContents = builtins.fromTOML (builtins.readFile cargoToml);
        profiles = cargoTomlContents.profile or { };

        # cargo's built-in profiles that are not roots, and what they inherit
        # when the manifest leaves `inherits` unset.
        predefinedParents = {
          bench = "release";
          test = "dev";
          doc = "dev";
          debug = "dev";
        };

        isDefined = n: n == "release" || n == "dev" || profiles ? ${n} || predefinedParents ? ${n};

        # The profile tables `name` resolves through, leaf first, validated as
        # cargo validates them.
        chainOf =
          seen: name:
          let
            table = profiles.${name} or { };
            parent = table.inherits or (predefinedParents.${name} or null);
          in
          if name == "release" then
            lib.throwIf (table ? inherits)
              "nix-cargo-flags: `inherits` must not be specified in root profile `release`"
              [
                table
              ]
          else if name == "dev" then
            throw "nix-cargo-flags: profile `${profile}` resolves to the `dev` root, which this module cannot replay; build-rust-crate compiles as release"
          else if !isDefined name then
            throw "nix-cargo-flags: profile `${name}` is not defined in ${toString cargoToml}"
          else if parent == null then
            throw "nix-cargo-flags: profile `${name}` is missing an `inherits` directive, which cargo requires of every profile except `dev` and `release`"
          else if lib.elem parent seen then
            throw "nix-cargo-flags: profile inheritance loop detected with profile `${name}` inheriting `${parent}`"
          else if !isDefined parent then
            throw "nix-cargo-flags: profile `${name}` inherits from `${parent}`, but that profile is not defined"
          else
            [ table ] ++ chainOf (seen ++ [ parent ]) parent;

        # cargo merges key by key, child over parent, and merges each
        # package override table the same way.
        settings = builtins.removeAttrs (lib.foldl' lib.recursiveUpdate { } (
          lib.reverseList (chainOf [ profile ] profile)
        )) [ "inherits" ];
        config = if cargoConfig == null then { } else builtins.fromTOML (builtins.readFile cargoConfig);

        # [profile.<p>.package.<name>] tables, split off so the rest of the
        # profile can be read as the flat set of settings it was before.
        packageOverrides = settings.package or { };
        rootSettings = builtins.removeAttrs settings [ "package" ];

        workspaceMembers =
          if workspaceMemberNames != null then
            workspaceMemberNames
          else
            let
              dir = builtins.dirOf cargoToml;
              nameOf =
                p:
                if lib.hasInfix "*" p then
                  throw "nix-cargo-flags: [workspace].members entry ${p} is a glob, which this module does not expand; pass workspaceMemberNames to resolve [profile.${profile}.package.\"*\"]"
                else
                  (builtins.fromTOML (builtins.readFile (dir + "/${p}/Cargo.toml"))).package.name;
            in
            map nameOf (cargoTomlContents.workspace.members or [ ])
            # A root [package] is a member of its own workspace.
            ++ lib.optional (cargoTomlContents ? package) cargoTomlContents.package.name;

        # cargo resolves a named override first, and applies the wildcard to
        # dependencies only.
        settingsFor =
          crateName:
          rootSettings
          // (packageOverrides.${crateName} or (
            # Short-circuits so a workspace whose members this module
            # cannot resolve still evaluates when no wildcard needs them.
            if packageOverrides ? "*" && !(lib.elem crateName workspaceMembers) then
              packageOverrides."*"
            else
              { }
          )
          );

        onOff = v: if v then "on" else "off";

        # cargo: true/"fat" -> fat, "thin" -> thin, "off" -> off and no
        # bitcode, false -> rustc's default thin-local LTO, and no bitcode
        # either since no later unit can link it.
        ltoOpts =
          v:
          if v == true || v == "fat" then
            [ "-Clto=fat" ]
          else if v == "thin" then
            [ "-Clto=thin" ]
          else if v == "off" then
            [
              "-Clto=off"
              "-Cembed-bitcode=no"
            ]
          else if v == false then
            [ "-Cembed-bitcode=no" ]
          else
            throw "nix-cargo-flags: unrecognised [profile.${profile}] lto = ${builtins.toJSON v}";

        # cargo: true -> 2, false -> 0, anything else passed through (0-2,
        # "line-tables-only", "full").
        debuginfoOpts = v: [
          "-Cdebuginfo=${
            if v == true then
              "2"
            else if v == false then
              "0"
            else
              toString v
          }"
        ];

        # Profile keys that map onto a rustc flag. These are appended after
        # build-rust-crate's own -Copt-level, and rustc takes the last
        # occurrence of a repeated -C option, so an explicit profile
        # opt-level wins.
        profileOptsFor =
          s:
          lib.optionals (s ? "opt-level") [ "-Copt-level=${toString s."opt-level"}" ]
          ++ lib.optionals (s ? "debug") (debuginfoOpts s."debug")
          ++ lib.optionals (s ? "debug-assertions") [
            "-Cdebug-assertions=${onOff s."debug-assertions"}"
          ]
          ++ lib.optionals (s ? "overflow-checks") [
            "-Coverflow-checks=${onOff s."overflow-checks"}"
          ]
          ++ lib.optionals (s ? "panic") [ "-Cpanic=${s."panic"}" ];

        ltoOptsForBin = lib.optionals (rootSettings ? "lto") (ltoOpts rootSettings."lto");

        # The rlib half of the profile's `lto`, which rustc does not take
        # from the binary's flags. cargo emits the rlibs feeding an LTO'd
        # link as bitcode with no machine code, and drops the bitcode it
        # would otherwise embed once nothing can consume it; an rlib built
        # without either carries an object file and a copy of its bitcode.
        # `-Clinker-plugin-lto` is inert only on a unit that never links: it
        # makes rustc emit bitcode and no machine code, which is what the
        # rlibs feeding an LTO'd link want, and what a unit that links
        # cannot use. rustc turns it into a `-plugin-opt` the linker must
        # understand — Apple's ld rejects the option outright, GNU ld takes
        # it and then cannot read the bitcode object — so this is fatal
        # everywhere, not on one platform.
        #
        # Which crates link is not in the buildRustCrate args:
        # cargo-nix-plugin passes `procMacro` but leaves it false for every
        # crate, and `crateType` reads `["lib"]` for a proc-macro as for an
        # rlib. `cargo metadata` has it, so the caller supplies the answer.
        ltoWantsPluginLto =
          let
            v = rootSettings."lto" or null;
          in
          v == true || v == "fat" || v == "thin";

        rlibLtoOpts =
          crateName:
          let
            v = rootSettings."lto" or null;
          in
          if v == null then
            [ ]
          else if ltoWantsPluginLto then
            if linkingCrateClosure == null then
              [ ]
            else if lib.elem crateName linkingCrateClosure then
              # rustc's default — an object file and a copy of its bitcode —
              # is the only output that serves both consumers a crate in
              # this closure can have. The proc-macro linking it needs the
              # object; an LTO'd binary depending on it needs the bitcode,
              # and a crate can be both. cargo escapes the conflict by
              # building the two uses as separate units.
              [ ]
            else
              [ "-Clinker-plugin-lto" ]
          else
            ltoOpts v;

        # cargo prefers the target-specific list over [build].rustflags and
        # never merges the two.
        rustflagsFor =
          rustcTargetSpec: config.target.${rustcTargetSpec}.rustflags or (config.build.rustflags or [ ]);

        # `strip` needs no flag: build-rust-crate sets
        # dontStrip = !release, so stdenv's fixupPhase already strips the
        # release binary. The corollary is that a `strip = false` would not
        # be honoured.
        covered = [ "strip" ];
        mapped = [
          "opt-level"
          "debug"
          "debug-assertions"
          "overflow-checks"
          "panic"
          "lto"
          "codegen-units"
        ];

        # Keys a package override may not set, per cargo. They decide how
        # the final artifact is linked rather than how one unit compiles, so
        # cargo rejects the manifest outright; matching that here keeps the
        # error at eval instead of a divergence at build.
        overrideForbidden = [
          "lto"
          "panic"
          "rpath"
        ];

        overrideKeys =
          pred:
          lib.concatMap (n: map (k: "package.${n}.${k}") (pred (builtins.attrNames packageOverrides.${n}))) (
            builtins.attrNames packageOverrides
          );

        forbidden = overrideKeys (lib.intersectLists overrideForbidden);
        unhandled =
          lib.subtractLists (mapped ++ covered) (builtins.attrNames rootSettings)
          ++ overrideKeys (lib.subtractLists (mapped ++ covered));

        # A package override carrying codegen-units is a cost knob to give
        # back too, even where the root profile leaves it at the default.
        anySetsCodegenUnits =
          rootSettings ? "codegen-units"
          || lib.any (o: o ? "codegen-units") (builtins.attrValues packageOverrides);

        relaxOpts' =
          {
            lto ? "off",
            codegen-units ? 16,
          }:
          lib.optionals (rootSettings ? "lto") (ltoOpts lto)
          # rustc takes the last occurrence, and `-Clto` is a different
          # option from the one that put an rlib in bitcode. Emitted
          # whatever the target, since it only undoes a flag.
          ++ lib.optionals ltoWantsPluginLto [ "-Clinker-plugin-lto=no" ]
          ++ lib.optionals anySetsCodegenUnits [
            "-Ccodegen-units=${toString codegen-units}"
          ];
      in
      lib.throwIf (forbidden != [ ])
        "nix-cargo-flags: [profile.${profile}] ${lib.concatStringsSep ", " forbidden} is not a setting cargo allows in a package override"
        # Anything new in the profile that this module does not know how to
        # replay is a silent cargo/nix divergence, so say so at eval time
        # rather than build it wrong.
        lib.warnIf
        (unhandled != [ ])
        "nix-cargo-flags: [profile.${profile}] ${lib.concatStringsSep ", " unhandled} is not replayed into the nix build; cargo honours it, `nix build` will not"
        {
          # Arguments to merge into one buildRustCrate call.
          forCrate =
            { isHost, rustcTargetSpec }:
            args:
            let
              linksBins =
                if binCrateNames != null then lib.elem args.crateName binCrateNames else !(args ? crateBin);
              crateSettings = settingsFor args.crateName;
              extraOpts = lib.optionals (!isHost) (
                profileOptsFor crateSettings
                ++ (if linksBins then ltoOptsForBin else rlibLtoOpts args.crateName)
                ++ rustflagsFor rustcTargetSpec
              );
            in
            args
            // lib.optionalAttrs (!isHost && crateSettings ? "codegen-units") {
              # This also reaches the crate's own build.rs, which
              # build-rust-crate compiles in the same derivation from the
              # same setting. cargo leaves that one at the default; it
              # costs a little build time and cannot affect the artifact.
              codegenUnits = crateSettings."codegen-units";
            }
            // lib.optionalAttrs (extraOpts != [ ]) {
              extraRustcOpts = (args.extraRustcOpts or [ ]) ++ extraOpts;
            };

          # Flags that give back the profile's build-time cost when appended
          # after `forCrate`'s output. build-rust-crate emits extraRustcOpts
          # last and rustc takes the last occurrence of a repeated -C option,
          # so these win over what forCrate placed — which is the only lever
          # available on a unit cargo-nix-plugin derives by overriding an
          # already-built crate, after the buildRustCrateForPkgs hook has run:
          #
          #   (cargoNix.workspaceMembers.foo.buildTests).override {
          #     extraRustcOpts = cargoFlags.relaxOpts { };
          #   }
          #
          # Scoped to `lto` and `codegen-units`: they cost build time without
          # changing what a check observes. opt-level and the
          # .cargo/config.toml rustflags stay put — -Ctarget-cpu decides which
          # instructions a unit is compiled for, so relaxing it would stop the
          # check from exercising the code that ships.
          #
          # Values take cargo's profile spellings, normalised as everywhere
          # else here, and only keys the profile itself set are emitted:
          # unset means forCrate placed no flag to override, and
          # build-rust-crate already defaults to codegen-units = 16.
          relaxOpts = relaxOpts';

        };
  };

in
lib
