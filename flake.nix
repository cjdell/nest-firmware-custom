{
  description = "Nest on-device protocol server + a self-contained firmware image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, rust-overlay }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # The GTVHacker kernel is 2.6.37 and is built with the 2008 ARM
      # toolchain vendored in the attack tree. That toolchain is 32-bit x86
      # (i686) — see firmware/README.md for why that forces qemu-i386.
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            targets = [ "armv7-unknown-linux-musleabi" ];
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              rustToolchain
              pkgs.pkg-config
              pkgs.python3
            ];
            shellHook = ''
              echo "nest dev shell — cargo $(cargo --version | cut -d' ' -f2)"
              echo "server:  ./build server   (or cargo build --release --manifest-path nest-ondevice-server/Cargo.toml)"
              echo "image:   ./build firmware"
              echo "compare: ./build repro"
            '';
          };
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          lib = pkgs.lib;

          rustTarget = "armv7-unknown-linux-musleabi";
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            targets = [ rustTarget ];
          };
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };

          # The server itself. armv7-unknown-linux-musleabi is the Nest's
          # soft-float (ld-linux.so.3) ABI; a static musl binary needs no
          # device libc. rust-lld + link-self-contained keeps the cross
          # build working on a bare Mac with no ARM linker installed.
          #
          # buildRustPackage's hooks force `--target <host>`, so the build and
          # install phases are spelled out here and drive cargo directly with
          # CARGO_BUILD_TARGET set to the device triple.
          # Only build inputs are hashed, so editing the README/tests does not
          # invalidate the server (and therefore the kernel/firmware) build.
          serverSrc = lib.fileset.toSource {
            root = ./nest-ondevice-server;
            fileset = lib.fileset.unions [
              ./nest-ondevice-server/Cargo.toml
              ./nest-ondevice-server/Cargo.lock
              ./nest-ondevice-server/src
            ];
          };

          nest-ondevice = rustPlatform.buildRustPackage {
            pname = "nest-ondevice";
            version = "0.1.0";
            src = serverSrc;
            cargoLock.lockFile = ./nest-ondevice-server/Cargo.lock;
            doCheck = false;

            CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABI_LINKER = "rust-lld";
            CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABI_RUSTFLAGS =
              "-C linker-flavor=ld.lld -C link-self-contained=yes";

            buildPhase = ''
              runHook preBuild
              export CARGO_BUILD_TARGET=${rustTarget}
              cargo build --offline --release -j"$NIX_BUILD_CORES"
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 target/${rustTarget}/release/nest-ondevice \
                "$out/bin/nest-ondevice"
              runHook postInstall
            '';

            meta = {
              description = "Nest device-protocol server (armv7 soft-float musl)";
              license = lib.licenses.mit;
              mainProgram = "nest-ondevice";
            };
          };
        in
        {
          inherit nest-ondevice;
          default = nest-ondevice;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
          import ./firmware { inherit pkgs lib nest-ondevice; }
        )
      );
    };
}
