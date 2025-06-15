{ config, lib, ... }:
let
  cfg = config.skarabox.disks;

  inherit (lib) mkIf mkOption optionals optionalString types;
in
{
  options.skarabox.disks = {
    rootPool = mkOption {
      description = "ZFS root pool where the OS is stored.";
      type = with types; submodule {
        options = {
          name = mkOption {
            description = "Name of the root pool";
            type = types.str;
            default = "root";
          };

          disk1 = mkOption {
            description = "SSD disk on which to install. Required";
            type = types.str;
            example = "/dev/nvme0n1";
          };

          disk2 = mkOption {
            description = "Mirror SSD disk on which to install. Optional. Boot partition will be mirrored too.";
            type = types.nullOr types.str;
            example = "/dev/nvme0n2";
            default = null;
          };

          reservation = mkOption {
            description = ''
              Disk size to reserve for ZFS internals. Should be between 10% and 15% of available size as recorded by zpool.

              To get available size on zpool:

                 zfs get -Hpo value available <pool name>

              Then to set manually, if needed:

                 sudo zfs set reservation=100G <pool name>
            '';
            type = types.str;
            example = "100G";
          };
        };
      };
    };

    dataPool = mkOption {
      description = "ZFS pool to store important data.";
      default = {};
      type = with types; submodule {
        options = {
          enable = lib.mkEnableOption "the data pool on other hard drives." // {
            default = false;
          };

          name = mkOption {
            description = "Name of the data pool";
            type = types.str;
            default = "zdata";
          };

          disk1 = mkOption {
            description = "First disk on which to install the data pool.";
            type = types.str;
            example = "/dev/sda";
            default = "";
          };

          disk2 = mkOption {
            description = "Second disk on which to install the data pool.";
            type = types.str;
            example = "/dev/sdb";
            default = "";
          };

          reservation = mkOption {
            description = ''
              Disk size to reserve for ZFS internals. Should be between 5% and 10% of available size as recorded by zpool.

              To get available size on zpool:

                 zfs get -Hpo value available <pool name>

              Then to set manually, if needed:

                 sudo zfs set reservation=100G <pool name>
            '';
            type = types.str;
            example = "1T";
            default = "100G";
          };
        };
      };
    };

    dataPools = mkOption {
      description = "Advanced ZFS data pools configuration with RAIDZ and cache support.";
      type = with types; attrsOf (submodule {
        options = {
          enable = lib.mkEnableOption "this data pool" // {
            default = true;
          };

          mode = mkOption {
            description = "ZFS pool redundancy mode.";
            type = types.enum [ "mirror" "raidz1" "raidz2" "raidz3" ];
            example = "raidz2";
            default = "mirror";
          };

          disks = mkOption {
            description = "List of disks to use for this pool.";
            type = with types; listOf str;
            example = [ "/dev/sdb" "/dev/sdc" "/dev/sdd" "/dev/sde" ];
          };

          cache = mkOption {
            description = "Cache device configuration for L2ARC and/or SLOG.";
            type = with types; submodule {
              options = {
                enable = lib.mkEnableOption "cache device";

                device = mkOption {
                  description = "Cache device path.";
                  type = types.str;
                  example = "/dev/sda";
                };

                l2arc = mkOption {
                  description = "Enable L2ARC (read cache) on this device.";
                  type = types.bool;
                  default = true;
                };

                slog = mkOption {
                  description = "Enable SLOG (write cache) on this device.";
                  type = types.bool;
                  default = true;
                };
              };
            };
            default = { enable = false; };
          };

          reservation = mkOption {
            description = ''
              Disk size to reserve for ZFS internals. Should be between 5% and 10% of available size as recorded by zpool.

              To get available size on zpool:
                
                zfs get -Hpo value available <pool name>

              Then to set manually, if needed:

                sudo zfs set reservation=100G <pool name> 
            '';
            type = types.str;
            example = "1T";
          };

          datasets = mkOption {
            description = "Additional datasets to create in this pool.";
            type = with types; attrsOf (submodule {
              options = {
                type = mkOption {
                  description = "Dataset type.";
                  type = types.enum [ "zfs_fs" ];
                  default = "zfs_fs";
                };

                mountpoint = mkOption {
                  description = "Where to mount this dataset.";
                  type = types.str;
                  example = "/srv/media";
                };

                options = mkOption {
                  description = "ZFS dataset options.";
                  type = with types; attrsOf str;
                  default = { mountpoint = "legacy"; };
                };
              };
            });
            default = {};
          };
        };
      });
      default = {};
    };

    initialBackupDataset = mkOption {
      description = "Create the backup dataset.";
      type = types.bool;
      default = true;
    };
  };

  config = 
    let
      # Validation: ensure dataPools and dataPool are not both used
      usingDataPool = cfg.dataPool.enable;
      usingDataPools = cfg.dataPools != {};
      
      # Helper function to validate disk counts for RAID modes
      validateDiskCount = poolName: pool:
        let
          diskCount = builtins.length pool.disks;
          minDisks = {
            mirror = 2;
            raidz1 = 3;
            raidz2 = 4;
            raidz3 = 5;
          };
          required = minDisks.${pool.mode};
        in
          if diskCount < required then
            throw "Pool '${poolName}' with mode '${pool.mode}' requires at least ${toString required} disks, but only ${toString diskCount} provided"
          else true;
          
      # Validate all pools
      poolValidations = lib.mapAttrsToList validateDiskCount (lib.filterAttrs (_: pool: pool.enable) cfg.dataPools);

      # Helper functions for dataPools
      enabledDataPools = lib.filterAttrs (_: pool: pool.enable) cfg.dataPools;

      # Create disk configurations for dataPools
      mkDataPoolDisk = poolName: diskPath: diskIndex: {
        type = "disk";
        device = diskPath;
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = poolName;
              };
            };
          };
        };
      };

      # Generate disk configurations for all dataPools
      dataPoolDisks = lib.listToAttrs (
        lib.flatten (
          lib.mapAttrsToList (poolName: pool:
            lib.imap0 (diskIndex: diskPath: {
              name = "${poolName}_disk${toString diskIndex}";
              value = mkDataPoolDisk poolName diskPath diskIndex;
            }) pool.disks
          ) enabledDataPools
        )
      );
      
      # Create zpool configurations for dataPools
      mkDataPoolZpool = poolName: pool: {
        type = "zpool";
        mode = pool.mode;
        options = {
          ashift = "12";
          autotrim = "on";
        };
        rootFsOptions = {
          encryption = "on";
          keyformat = "passphrase";
          keylocation = "file:///tmp/${poolName}_passphrase";
          compression = "lz4";
          canmount = "off";
          xattr = "sa";
          atime = "off";
          acltype = "posixacl";
          recordsize = "1M";
          "com.sun:auto-snapshot" = "false";
          mountpoint = "none";
        };
        preCreateHook = ''
          pname=$name
        '';
        postCreateHook = ''
          zfs set keylocation="file:///persist/${poolName}_passphrase" $pname
          ${optionalString pool.cache.enable (
            if pool.cache.l2arc && pool.cache.slog then
              ''
              # Create partitions for both cache and log
              sgdisk --clear ${pool.cache.device}
              sgdisk --new=1:0:+32G --typecode=1:8300 --change-name=1:slog ${pool.cache.device}
              sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:cache ${pool.cache.device}
              partprobe ${pool.cache.device}
              udevadm settle
              zpool add $pname log ${pool.cache.device}-part1
              zpool add $pname cache ${pool.cache.device}-part2
              ''
            else if pool.cache.l2arc then
              ''
              zpool add $pname cache ${pool.cache.device}
              ''
            else if pool.cache.slog then
              ''
              zpool add $pname log ${pool.cache.device}
              ''
            else ""
          )};
        '';
        datasets = {
          "reserved" = {
            options = {
              canmount = "off";
              mountpoint = "none";
              reservation = pool.reservation;
            };
            type = "zfs_fs";
          };
        } // pool.datasets;
      };

      # Generate zpool configurations for all dataPools
      dataPoolZpools = lib.mapAttrs mkDataPoolZpool enabledDataPools;

      # Generate fileSystems entries for dataPools
      dataPoolFileSystems = lib.listToAttrs (
        lib.flatten (
          lib.mapAttrsToList (poolName: pool:
            lib.mapAttrsToList (datasetName: dataset: {
              name = dataset.mountpoint;
              value = { options = [ "nofail" ]; };
            }) pool.datasets
          ) enabledDataPools
        )
      );

      # Copy passphrase files for dataPools
      dataPoolPassphraseHooks = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (poolName: pool:
          "cp /tmp/${poolName}_passphrase /mnt/persist/${poolName}_passphrase"
        ) enabledDataPools
      );

    in {
      # Validation assertions
      assertions = [
        {
          assertion = !(usingDataPool && usingDataPools);
          message = "Cannot use both 'dataPool' and 'dataPools' options. Please use only one.";
        }
      ] ++ map (validation: {
        assertion = validation;
        message = "Disk validation failed";
      }) poolValidations;

      disko.devices = {
        disk = let
          hasRaid = cfg.rootPool.disk2 != null;

          mkRoot = { disk, id ? "" }: {
            type = "disk";
            device = disk;
            content = {
              type = "gpt";
              partitions = {
                ESP = {
                  size = "500M";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    mountpoint = "/boot${id}";
                    # Otherwise you get https://discourse.nixos.org/t/security-warning-when-installing-nixos-23-11/37636/2
                    mountOptions = [ "umask=0077" ];
                    # Copy the host_key needed for initrd in a location accessible on boot.
                    # It's prefixed by /mnt because we're installing and everything is mounted under /mnt.
                    # We're using the same host key because, well, it's the same host!
                    postMountHook = ''
                      cp /tmp/host_key /mnt/boot${id}/host_key
                    '';
                  };
                };
                zfs = {
                  size = "100%";
                  content = {
                    type = "zfs";
                    pool = cfg.rootPool.name;
                  };
                };
              };
            };
          };

          mkDataDisk = dataDisk: {
            type = "disk";
            device = dataDisk;
            content = {
              type = "gpt";
              partitions = {
                zfs = {
                  size = "100%";
                  content = {
                    type = "zfs";
                    pool = cfg.dataPool.name;
                  };
                };
              };
            };
          };
        in {
          root = mkRoot { disk = cfg.rootPool.disk1; };
          # Second root must have id=-backup.
          root1 = mkIf hasRaid (mkRoot { disk = cfg.rootPool.disk2; id = "-backup"; });
          data1 = mkIf cfg.dataPool.enable (mkDataDisk cfg.dataPool.disk1);
          data2 = mkIf cfg.dataPool.enable (mkDataDisk cfg.dataPool.disk2);
        } // dataPoolDisks; # Add dataPools disks

        zpool = {
          ${cfg.rootPool.name} = {
            type = "zpool";
            mode = if cfg.rootPool.disk2 != null then "mirror" else "";
            options = {
              ashift = "12";
              autotrim = "on";
            };
            rootFsOptions = {
              encryption = "on";
              keyformat = "passphrase";
              keylocation = "file:///tmp/root_passphrase";
              compression = "lz4";
              canmount = "off";
              xattr = "sa";
              atime = "off";
              acltype = "posixacl";
              recordsize = "1M";
              "com.sun:auto-snapshot" = "false";
            };
            # Need to use another variable name otherwise I get SC2030 and SC2031 errors.
            preCreateHook = ''
              pname=$name
            '';
            # Needed to get back a prompt on next boot.
            # See https://github.com/nix-community/nixos-anywhere/issues/161#issuecomment-1642158475
            postCreateHook = ''
              zfs set keylocation="prompt" $pname
            '';

            # Follows https://grahamc.com/blog/erase-your-darlings/
            datasets = {
              # TODO: compute percentage automatically in postCreateHook
              "reserved" = {
                options = {
                  canmount = "off";
                  mountpoint = "none";
                  # TODO: compute this value using percentage
                  reservation = cfg.rootPool.reservation;
                };
                type = "zfs_fs";
              };

              "local/root" = {
                type = "zfs_fs";
                mountpoint = "/";
                options.mountpoint = "legacy";
                postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^${cfg.rootPool.name}/local/root@blank$' || zfs snapshot ${cfg.rootPool.name}/local/root@blank";
              };

              "local/nix" = {
                type = "zfs_fs";
                mountpoint = "/nix";
                options.mountpoint = "legacy";
              };

              "safe/home" = {
                type = "zfs_fs";
                mountpoint = "/home";
                options.mountpoint = "legacy";
              };

              "safe/persist" = {
                type = "zfs_fs";
                mountpoint = "/persist";
                # It's prefixed by /mnt because we're installing and everything is mounted under /mnt.
                options.mountpoint = "legacy";
                postMountHook = optionalString cfg.dataPool.enable ''
                  cp /tmp/data_passphrase /mnt/persist/data_passphrase
                '' + optionalString usingDataPools dataPoolPassphraseHooks;
              };
            };
          };

          ${cfg.dataPool.name} = mkIf cfg.dataPool.enable {
            type = "zpool";
            mode = "mirror";
            options = {
              ashift = "12";
              autotrim = "on";
            };
            rootFsOptions = {
              encryption = "on";
              keyformat = "passphrase";
              keylocation = "file:///tmp/data_passphrase";
              compression = "lz4";
              canmount = "off";
              xattr = "sa";
              atime = "off";
              acltype = "posixacl";
              recordsize = "1M";
              "com.sun:auto-snapshot" = "false";
              mountpoint = "none";
            };
            # Need to use another variable name otherwise I get SC2030 and SC2031 errors.
            preCreateHook = ''
              pname=$name
            '';
            postCreateHook = ''
              zfs set keylocation="file:///persist/data_passphrase" $pname;
            '';
            datasets = {
              # TODO: create reserved dataset automatically in postCreateHook
              "reserved" = {
                options = {
                  canmount = "off";
                  mountpoint = "none";
                  # TODO: compute this value using percentage
                  reservation = cfg.dataPool.reservation;
                };
                type = "zfs_fs";
              };
            } // lib.optionalAttrs cfg.initialBackupDataset {
              "backup" = {
                type = "zfs_fs";
                mountpoint = "/srv/backup";
                options.mountpoint = "legacy";
              };
              # TODO: create datasets automatically upon service installation (e.g. Nextcloud, etc.)
              #"nextcloud" = {
              #  type = "zfs_fs";
              #  mountpoint = "/srv/nextcloud";
              #};
            };
          };
        } // dataPoolZpools; # Add dataPools zpools
      };

      # Combine fileSystems
      fileSystems = {
        "/srv/backup" = mkIf (cfg.dataPool.enable && cfg.initialBackupDataset) {
          options = [ "nofail" ];
	};

        # This is needed to make the /boot*/host_key available early
        # enough to be able to decrypt the sops file on boot,
        # when the /etc/shadow file is first generated.
        # We assume mkRoot will always be called with at least id=1.
        "/boot".neededForBoot = true;
        "/boot-backup" = mkIf (cfg.rootPool.disk2 != null) { neededForBoot = true; };
      } // dataPoolFileSystems;

      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportRoot = false;
      
      # To import the zpool automatically
      boot.zfs.extraPools =
        optionals cfg.dataPool.enable [ cfg.dataPool.name ] ++
        lib.mapAttrsToList (poolName: _: poolName) enabledDataPools;

      # Follows https://grahamc.com/blog/erase-your-darlings/
      # https://github.com/NixOS/nixpkgs/pull/346247/files
      boot.initrd.postResumeCommands = lib.mkAfter ''
        zfs rollback -r ${cfg.rootPool.name}/local/root@blank
      '';

      # Setup Grub to support UEFI.
      # nodev is for UEFI.
      boot.loader.grub = {
        enable = true;
        efiSupport = true;
        efiInstallAsRemovable = true;

        mirroredBoots = lib.mkForce ([
          {
            path = "/boot";
            devices = [ "nodev" ];
          }
        ] ++ (optionals (cfg.rootPool.disk2 != null) [
          {
            path = "/boot-backup";
            devices = [ "nodev" ];
          }
        ]));
      };

      services.zfs.autoScrub.enable = true;
    };
}
