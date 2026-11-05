{
  description = "Revue: a native macOS app for reviewing code";

  inputs.nixpkgs.url = "nixpkgs";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      swiftPkgs = pkgs.swiftPackages;

      grammars = {
        bash = "sh,bash,zsh,.bashrc,.zshrc,.envrc";
        c = "";
        cpp = "cc,cpp,cxx,hpp,hxx,hh,mm";
        c-sharp = "cs";
        clojure = "clj,cljs,cljc,edn";
        cmake = "";
        css = "";
        dart = "";
        diff = "diff,patch";
        dockerfile = "Dockerfile,dockerfile,Containerfile";
        elixir = "";
        elm = "";
        erlang = "";
        fish = "fish";
        go = "";
        gomod = "go.mod";
        graphql = "graphql,gql";
        haskell = "";
        html = "";
        java = "";
        javascript = "js,mjs,cjs,jsx";
        json = "";
        julia = "";
        just = "justfile,Justfile,just";
        kotlin = "kt,kts";
        lua = "";
        make = "Makefile,makefile,GNUmakefile,mk";
        markdown = "";
        nix = "";
        ocaml = "ml";
        php = "";
        proto = "";
        python = "";
        r = "";
        ruby = "Gemfile,Rakefile,rake,gemspec";
        rust = "";
        scala = "";
        scheme = "";
        sql = "sql";
        svelte = "svelte";
        swift = "";
        toml = "toml,Cargo.lock,uv.lock,poetry.lock";
        tsx = "";
        typescript = "mts,cts";
        vim = "";
        vue = "vue";
        xml = "xml,plist,svg,xsd,xib,storyboard,csproj";
        yaml = "";
        zig = "";
      };

      syntaxRuntime = pkgs.runCommand "revue-syntax-runtime"
        {
          nativeBuildInputs = [ pkgs.jq pkgs.bash ];
          grammarsFile = pkgs.writeText "grammars" (lib.concatStrings (lib.mapAttrsToList (attr: types:
            let g = pkgs.tree-sitter-grammars."tree-sitter-${attr}";
            in "${attr} ${g} ${g.src} ${types}\n") grammars));
        }
        "bash ${./nix/syntax-runtime.sh}";

      mkRevue = { pname, git }: swiftPkgs.stdenv.mkDerivation {
        inherit pname;
        version = lib.fileContents ./VERSION;
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Package.swift
            ./Package.resolved
            ./Sources
            ./Tests
            ./bundle.sh
            ./VERSION
            ./icon/AppIcon.icns
          ];
        };
        nativeBuildInputs = [
          swiftPkgs.swift
          swiftPkgs.swiftpm
        ];
        buildInputs = [ pkgs.apple-sdk_26 ];

        configurePhase = (pkgs.swiftpm2nix.helpers ./nix/swiftpm).configure;

        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR
          swift build -c release --disable-sandbox --product RevueApp
          swift build -c release --disable-sandbox --product revue
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out/Applications $out/bin
          bash ./bundle.sh "$(swift build -c release --show-bin-path)" $out/Applications "${git}" ${syntaxRuntime}
          ln -s $out/Applications/Revue.app/Contents/Helpers/revue $out/bin/revue
          runHook postInstall
        '';

        meta = {
          description = "Native macOS code review app";
          platforms = [ system ];
          mainProgram = "revue";
        };
      };

      revue = mkRevue { pname = "revue"; git = "${pkgs.git}/bin/git"; };
      release = mkRevue { pname = "revue-release"; git = ""; };
    in
    {
      packages.${system} = {
        default = revue;
        inherit revue release syntaxRuntime;
      };

      apps.${system}.default = {
        type = "app";
        program = "${revue}/bin/revue";
      };

      devShells.${system}.default = pkgs.mkShell.override { stdenv = swiftPkgs.stdenv; } {
        packages = [
          swiftPkgs.swift
          swiftPkgs.swiftpm
          swiftPkgs.swift-format
          pkgs.apple-sdk_26
          pkgs.git
        ];
        REVUE_SYNTAX = syntaxRuntime;
      };
    };
}
