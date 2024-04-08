with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    gdb
    zlib
    # For linter script on push hook
    python3
  ];
}

