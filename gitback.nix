{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.gitback;
in
{
  options.services.gitback = {
    enable = lib.mkEnableOption "GitBack service";
    backups = lib.mkOption {
      description = "Configuration for backups";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            gitPath = lib.mkOption {
              type = lib.types.str;
              description = "Path to the git repository to back up";
            };
            targetPath = lib.mkOption {
              type = lib.types.str;
              description = "Path to mount into the git repository";
            };
            schedule = lib.mkOption {
              type = lib.types.str;
              default = "daily";
              description = "Systemd timer schedule for the backup service (Calendar Events section in `man systemd.time` for details)";
            };
            user = lib.mkOption {
              type = lib.types.str;
              description = "User under which the backup service runs";
            };
            group = lib.mkOption {
              type = lib.types.str;
              description = "Group under which the backup service runs";
            };
            gitConfig = {
              userName = lib.mkOption {
                type = lib.types.str;
                description = "Git username for commits";
              };
              userEmail = lib.mkOption {
                type = lib.types.str;
                description = "Git email for commits";
              };
              credentialFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Path to the git credential file";
              };
              # TODO: add remote option
            };
          };
        }
      );
    };
  };

  config =
    let
      gitCredentialHelper = pkgs.writeScript "git-credential-helper" ''
        #!${pkgs.nushell}/bin/nu
        ${builtins.readFile ./scripts/git-credential-helper.nu}
      '';
      genConfig = name: value: {
        systemd.tmpfiles.rules = [
          "d '${value.gitPath}' 0700 ${value.user} ${value.group} - -"
        ];

        fileSystems."${value.gitPath}/data" = {
          device = "${value.targetPath}";
          fsType = "none";
          options = [
            "bind"
            "ro"
          ];
        };

        systemd.services."gitback-${name}" = {
          description = "GitBack Backup Service for ${name}";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart =
              let
                gitArgs =
                  [
                    "-c"
                    "user.name=${value.gitConfig.userName}"
                    "-c"
                    "user.email=${value.gitConfig.userEmail}"
                  ]
                  ++ lib.optionals (value.gitConfig.credentialFile != null) [
                    "-c"
                    "credential.helper=\"${gitCredentialHelper} ${value.gitConfig.credentialFile}\""
                  ];
                git = pkgs.writeScriptBin "git" ''
                  #!${pkgs.nushell}/bin/nu
                  def --wrapped main [...args] {
                    ${pkgs.git}/bin/git ${lib.concatMapStringsSep " " (e: "r##'${e}'##") gitArgs} ...$args
                  }
                '';
                initScript = pkgs.writeScript "gitback-init-${name}" ''
                  #!${pkgs.nushell}/bin/nu
                  let name = r##'${name}'##
                  let value = r##'${builtins.toJSON value}'## | from json

                  cd $value.gitPath
                  ${git}/bin/git init
                  # TODO: more initialization steps if needed
                '';
                backupScript = pkgs.writeScript "gitback-backup-${name}" ''
                  #!${pkgs.nushell}/bin/nu
                  let name = r##'${name}'##
                  let value = r##'${builtins.toJSON value}'## | from json

                  # TODO: implement the backup logic
                '';
                mainScript = pkgs.writeScript "gitback-main-${name}" ''
                  #!${pkgs.nushell}/bin/nu
                  let name = r##'${name}'##
                  let value = r##'${builtins.toJSON value}'## | from json

                  let should_init = try {
                    ${git}/bin/git rev-parse --is-inside-work-tree o+e> /dev/null
                    false
                  } catch {
                    true
                  }
                  if $should_init {
                    print $'Initializing git repository for ($name)'
                    ${initScript}
                  }

                  print $'Backing up ($name)'
                  ${backupScript}
                '';
              in
              mainScript;
            User = value.user;
            Group = value.group;
          };
        };

        systemd.timers."gitback-${name}" = {
          description = "GitBack Backup Timer for ${name}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = value.schedule;
            Persistent = true;
            Unit = "gitback-${name}.service";
          };
        };
      };
      generated = lib.concatMapAttrs genConfig cfg.backups;
    in
    lib.mkIf cfg.enable {
      inherit (generated) systemd fileSystems; # to avoid infinite recursion with config
    };
}
