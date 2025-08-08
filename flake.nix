{
  inputs = {
  };
  outputs =
    {
      self,
      ...
    }:
    {
      nixosModules = rec {
        gitback = ./gitback.nix;
        default = gitback;
      };
    };
}
