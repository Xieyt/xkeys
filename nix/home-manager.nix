{ config, lib, pkgs, ... }:

let
  cfg = config.programs.xkeys;
  vocabulary = import ./keys.nix;

  # Key and modifier names are checked here, at evaluation time, so a typo
  # fails the rebuild instead of silently disabling one swap at runtime. The
  # lists come straight out of the Swift source via `just gen-nix-keys`.
  # xkeys matches names case-insensitively, so the module accepts what the
  # app accepts rather than inventing a stricter rule.
  anyCase = names: lib.unique (names ++ map lib.toLower names);
  keyType = lib.types.enum (anyCase vocabulary.keys);
  modifierType = lib.types.enum (anyCase vocabulary.modifiers);

  scopeOption = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "gk61";
    description = ''
      Limit this rule to one keyboard. A case-insensitive substring of the
      product name, so "gk61" matches "gk61 pro 48". Null means every
      keyboard. Run `xkeys keys` to list the attached keyboards.
    '';
  };

  swapType = lib.types.submodule {
    options = {
      from = lib.mkOption {
        type = keyType;
        example = "CapsLock";
        description = "The key you press.";
      };
      to = lib.mkOption {
        type = keyType;
        example = "Escape";
        description = "The key the driver sends instead.";
      };
      on = scopeOption;
    };
  };

  chordType = lib.types.submodule {
    options = {
      when = lib.mkOption {
        type = keyType;
        example = "LeftCommand";
        description = ''
          The trigger key, named as your finger presses it rather than as any
          swap renames it. xkeys reads the trigger off the keyboard device,
          which sits below the driver swap and reports the physical key.
        '';
      };
      hold = lib.mkOption {
        type = lib.types.nonEmptyListOf modifierType;
        example = [ "Command" "Control" "Option" "Shift" ];
        description = "Modifiers painted onto every other key while the trigger is held.";
      };
      hide = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Swallow the trigger's own keystroke so a bare tap types nothing.
          Cannot be limited to one keyboard: by the time the keystroke reaches
          the event tap it carries a key and no device.
        '';
      };
      on = scopeOption;
    };
  };

  settings = {
    swaps = map (s: lib.filterAttrs (_: v: v != null) s) cfg.swaps;
    chords = map (c: lib.filterAttrs (_: v: v != null) c) cfg.chords;
  };

in {
  options.programs.xkeys = {
    enable = lib.mkEnableOption "the xkeys keyboard agent";

    swaps = lib.mkOption {
      type = lib.types.listOf swapType;
      default = [ ];
      example = lib.literalExpression ''
        [ { from = "CapsLock"; to = "Escape"; }
          { from = "LeftCommand"; to = "F20"; on = "Apple Internal"; }
        ]
      '';
      description = "One-to-one key swaps, applied in the HID driver.";
    };

    chords = lib.mkOption {
      type = lib.types.listOf chordType;
      default = [ ];
      example = lib.literalExpression ''
        [ { when = "LeftCommand"; hold = [ "Command" "Control" "Option" "Shift" ]; } ]
      '';
      description = ''
        Trigger keys that paint real modifier flags onto the keys pressed
        while they are held, so apps outside your window manager can bind
        them.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Left null on purpose. nixpkgs ships Swift 5.10 on darwin and xkeys
        needs Swift 6, so there is nothing to build from. Install the app once
        with `just install` from a clone; this module owns the config file,
        the launch agent, and nothing else.
      '';
    };

    appPath = lib.mkOption {
      type = lib.types.str;
      default = "/Applications/xkeys.app";
      description = "Where `just install` put the app bundle.";
    };

    launchAgent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start xkeys at login.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          let keys = map (s: "${s.from}|${toString s.on}") cfg.swaps;
          in lib.length (lib.unique keys) == lib.length keys;
        message = "programs.xkeys: a key is swapped twice with the same scope.";
      }
      {
        assertion =
          let keys = map (c: "${c.when}|${toString c.on}") cfg.chords;
          in lib.length (lib.unique keys) == lib.length keys;
        message = "programs.xkeys: a key triggers two chords with the same scope.";
      }
    ];

    xdg.configFile."xkeys/config.json".text = builtins.toJSON settings;

    launchd.agents.xkeys = lib.mkIf cfg.launchAgent {
      enable = true;
      config = {
        Label = "com.xieyt.xkeys";
        ProgramArguments = [ "${cfg.appPath}/Contents/MacOS/xkeys" ];
        RunAtLoad = true;
        # Restart on crash, but not when the user quits from the menu.
        KeepAlive = {
          Crashed = true;
          SuccessfulExit = false;
        };
        ProcessType = "Interactive";
        LimitLoadToSessionType = "Aqua";
        StandardOutPath = "/tmp/xkeys.out.log";
        StandardErrorPath = "/tmp/xkeys.err.log";
      };
    };
  };
}
