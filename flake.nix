{
  # Every image IBIRAPAY runs for its Spark network is built here from source (this repo + the pinned
  # vendor/* submodules); nothing upstream-prebuilt is pulled. Toolchains come from cache.nixos.org.
  #   nix build .#operator-oci   local/spark-operator:<rev>  (spark-operator + spark-frost-signer + atlas + migrations)
  #   nix build .#ldk-server-oci local/ldk-server:<rev>      (ldk-server + ldk-server-cli)
  #   nix build .#oci            local/open-ssp:<rev>
  #   nix build .#caddy-oci      local/spark-caddy:<rev>     (TLS front for the SSP, static certs, no ACME)
  #   nix build .#postgres-oci   local/spark-postgres:<rev>  (operator DBs)
  #   nix build .#lego-oci       local/spark-lego:<rev>      (ACME DNS-01 for the operator + SSP certs)
  # From a git checkout the submodules must be inside the flake source: `nix build '.?submodules=1#oci'`.
  # The deploy builds from a `git archive` tree (each submodule archived at its pin) plus a REV file.
  description = "IBIRAPAY Spark operators + SSP";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      tag = self.rev or (if builtins.pathExists ./REV
        then lib.removeSuffix "\n" (builtins.readFile ./REV) else "dirty");

      # go.mod says `go 1.27.0`; nixpkgs' default go is older.
      spark-operator = (pkgs.buildGoModule.override { go = pkgs.go_1_27; }) {
        pname = "spark-operator";
        version = "0-unstable";
        src = ./vendor/spark/spark;
        subPackages = [ "bin/operator" ];
        vendorHash = "sha256-LyEzEfL29dXoHsKa7agQBJWokDyiKkDfe5yFeQrPK08=";
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.zeromq ]; # pebbe/zmq4 (cgo)
        env.GOTOOLCHAIN = "local";
        ldflags = [ "-s" "-w" ];
        doCheck = false; # the suites need Postgres + bitcoind: run in spark-lab
        postInstall = ''
          mv $out/bin/operator $out/bin/spark-operator
          mkdir -p $out/share/spark
          cp -r so/ent/migrate/migrations $out/share/spark/migrations
          cp -r so/entephemeral/migrate/migrations $out/share/spark/ephemeral_migrations
        '';
      };

      # spark-frost's build.rs reads ../../protos, so the source is the whole vendor/spark tree.
      spark-frost-signer = pkgs.rustPlatform.buildRustPackage {
        pname = "spark-frost-signer";
        version = "0-unstable";
        src = lib.fileset.toSource {
          root = ./vendor/spark;
          fileset = lib.fileset.unions [ ./vendor/spark/signer ./vendor/spark/protos ];
        };
        cargoRoot = "signer";
        buildAndTestSubdir = "signer";
        cargoLock = { lockFile = ./vendor/spark/signer/Cargo.lock; allowBuiltinFetchGit = true; };
        cargoBuildFlags = [ "-p" "spark-frost-signer" ];
        nativeBuildInputs = [ pkgs.protobuf ];
        doCheck = false;
      };

      ldk-server = pkgs.rustPlatform.buildRustPackage {
        pname = "ldk-server";
        version = "0-unstable";
        src = ./vendor/ldk-server;
        cargoLock = { lockFile = ./vendor/ldk-server/Cargo.lock; allowBuiltinFetchGit = true; };
        cargoBuildFlags = [ "-p" "ldk-server" "-p" "ldk-server-cli" ];
        nativeBuildInputs = [ pkgs.protobuf pkgs.pkg-config ];
        buildInputs = [ pkgs.openssl ]; # openssl-sys
        doCheck = false;
      };

      # Same inputs as ssp.Dockerfile: path deps reach into vendor/breez-sdk and vendor/spark/signer.
      open-ssp = pkgs.rustPlatform.buildRustPackage {
        pname = "open-ssp";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Cargo.toml ./Cargo.lock ./src
            ./vendor/breez-sdk ./vendor/spark/signer ./vendor/spark/protos
          ];
        };
        cargoLock = {
          lockFile = ./Cargo.lock;
          allowBuiltinFetchGit = true;
          # this rev is no longer on any frost branch, so builtins.fetchGit cannot find it; fetchgit by sha can
          outputHashes."frost-core-2.1.0" = "sha256-U8KCu1wVofNQBeN4zuIgmxN5lSKj/6YXu7J4o5oIvbQ=";
        };
        cargoBuildFlags = [ "--bin" "open-ssp" ];
        nativeBuildInputs = [ pkgs.protobuf ];
        doCheck = false; # covered by `cargo regtest test` in spark-lab
      };

      certs = "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

      # initdb on an empty data dir (superuser password from a mounted file), then postgres. Network clients
      # (internal compose network only) use scram; the local socket uses peer auth, so admin SQL runs through
      # `docker exec` with no password anywhere. postgres needs a passwd entry for its uid: the deploy mounts one.
      postgresEntry = pkgs.writeShellScript "spark-postgres-entry" ''
        set -eu
        export PATH=${pkgs.postgresql_16}/bin:${pkgs.coreutils}/bin
        data=/var/lib/postgresql/data
        if [ ! -s "$data/PG_VERSION" ]; then
          initdb -D "$data" -U postgres --auth-local=peer --auth-host=scram-sha-256 \
            --pwfile=/run/secrets/pg-superuser
          echo "host all all all scram-sha-256" >> "$data/pg_hba.conf"
        fi
        exec postgres -D "$data" -c listen_addresses='*' -c unix_socket_directories=/tmp \
          -c password_encryption=scram-sha-256
      '';
    in
    {
      packages.${system} = {
        default = open-ssp;
        inherit spark-operator spark-frost-signer ldk-server open-ssp;

        # The operator spawns no shell; atlas applies the migrations from /share/spark before it starts.
        operator-oci = pkgs.dockerTools.buildLayeredImage {
          name = "local/spark-operator";
          inherit tag;
          contents = [ spark-operator spark-frost-signer pkgs.atlas pkgs.cacert ];
          config = {
            Entrypoint = [ "/bin/spark-operator" ];
            Env = [ certs ];
          };
        };

        ldk-server-oci = pkgs.dockerTools.buildLayeredImage {
          name = "local/ldk-server";
          inherit tag;
          contents = [ ldk-server pkgs.cacert ];
          config = {
            Entrypoint = [ "/bin/ldk-server" ];
            Env = [ certs ];
          };
        };

        oci = pkgs.dockerTools.buildLayeredImage {
          name = "local/open-ssp";
          inherit tag;
          contents = [ open-ssp pkgs.cacert ];
          config = {
            Entrypoint = [ "/bin/open-ssp" ];
            Env = [ certs "SSP_DATA_DIR=/data" ];
          };
        };

        postgres-oci = pkgs.dockerTools.buildLayeredImage {
          name = "local/spark-postgres";
          inherit tag;
          contents = [ pkgs.postgresql_16 pkgs.coreutils pkgs.bash ]; # initdb popen()s /bin/sh
          config = {
            Entrypoint = [ "${postgresEntry}" ];
            Env = [ "PGDATA=/var/lib/postgresql/data" ];
          };
        };

        lego-oci = pkgs.dockerTools.buildLayeredImage {
          name = "local/spark-lego";
          inherit tag;
          contents = [ pkgs.lego pkgs.cacert ];
          config = {
            Entrypoint = [ "/bin/lego" ];
            Env = [ certs ];
          };
        };

        caddy-oci = pkgs.dockerTools.buildLayeredImage {
          name = "local/spark-caddy";
          inherit tag;
          contents = [ pkgs.caddy ];
          config.Entrypoint = [ "/bin/caddy" ];
        };
      };
    };
}
