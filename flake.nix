{
  description = "Driving an Obsidian vault from the terminal through the official CLI, described by what it actually does";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # The pinned toolbox for check.sh, locally and in CI. A check whose tools come from
      # the registry changes behaviour with zero change in the repository
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            actionlint
            # The vendored check-sh.sh is moving to reading a script as a tree, out of
            # `shfmt --to-json`, with jq flattening that tree into rows. It arrives before
            # the checker that needs it, so the cascade does not deliver a red run
            jq
            # The same binary the formatter output wraps with treefmt. The gate calls it
            # directly, because `nix fmt` needs the flake and a check should not
            nixfmt
            shellcheck
            shfmt
            # runs the JavaScript obsi.sh hands to eval, against a fake app
            nodejs
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
