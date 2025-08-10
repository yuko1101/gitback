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
              remotes = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      url = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "URL of the remote repository";
                      };
                      urlFile = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Path to a file containing the URL of the remote repository";
                      };
                    };
                  }
                );
                default = [ ];
                description = "Git remotes to push to (or fetch from), first one is used for fetching";
              };
            };
          };
        }
      );
    };
  };

  config =
    let
      gitCredentialHelper = pkgs.writeScript "git-credential-gitback" ''
        #!${pkgs.nushell}/bin/nu --stdin
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
          wants = lib.optional (value.gitConfig.remotes != [ ]) "network-online.target";
          after = lib.optional (value.gitConfig.remotes != [ ]) "network-online.target";
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
                    "credential.helper=${gitCredentialHelper} ${value.gitConfig.credentialFile}"
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
                  ${git}/bin/git init -b main # TODO: consider getting branch name from config or generating it to avoid conflicts
                  # TODO: more initialization steps if needed (e.g. encrypting the git repository with git-crypt)
                '';
                backupScript = pkgs.writeScript "gitback-backup-${name}" ''
                  #!${pkgs.nushell}/bin/nu
                  let name = r##'${name}'##
                  let value = r##'${builtins.toJSON value}'## | from json

                  cd $value.gitPath

                  let should_commit = ${git}/bin/git status -s -uall ./data/ | is-not-empty
                  if $should_commit {
                    print $'Committing changes for ($name)'
                    ${git}/bin/git add ./data/
                    ${git}/bin/git commit -m $'Backup at (date now | format date %+)'
                  } else {
                    print $'No changes to commit for ($name)'
                  }

                  print $'Pushing changes for ($name)'
                  for e in ($value.gitConfig.remotes | enumerate) {
                    let i = $e.index;
                    let remote = $e.item;
                    let url = $remote.url | default { 
                      if $remote.urlFile != null { 
                        open --raw $remote.urlFile | str trim
                      } else {
                        null
                      }
                    }
                    if $url == null {
                      print $'No URL provided for remote ($i), skipping...'
                      continue
                    }
                    ${git}/bin/git push $url main
                  }
                '';
                mainScript = pkgs.writeScript "gitback-main-${name}" ''
                  #!${pkgs.nushell}/bin/nu
                  let name = r##'${name}'##
                  let value = r##'${builtins.toJSON value}'## | from json

                  cd $value.gitPath
                  let should_init = try {
                    ${git}/bin/git rev-parse --is-inside-work-tree o+e> /dev/null
                    false
                  } catch {
                    true
                  }
                  if $should_init {
                    print $'Initializing git repository for ($name)'
                    ${initScript}
                    print $'Initialization completed for ($name)'
                  }

                  print $'Backing up ($name)'
                  ${backupScript}
                  print $'Backup completed for ($name)'
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
