{ config, lib, pkgs, ... }:

let
  cfg = config.services.xkeys;
in {
  options.services.xkeys = {
    enable = lib.mkEnableOption "installing xkeys.app and signing it at activation";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The xkeys package whose app bundle is installed.";
    };

    signingIdentity = lib.mkOption {
      type = lib.types.str;
      default = "xkeys-codesign";
      description = ''
        Name of the local code-signing identity used to sign xkeys.

        macOS attaches the Accessibility and Input Monitoring grants to the
        signature, so a stable identity is what lets those grants survive a
        rebuild. An ad-hoc signature changes every build, which makes every
        rebuild look like a brand new app and re-prompts for both.

        Share one identity across several self-signed apps by giving them the
        same name here.
      '';
    };

    manageSigningIdentity = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Create `signingIdentity` in the System keychain on first activation
        if it is missing, and trust it for code signing. Idempotent: made
        once, reused forever. Set false to manage the identity yourself.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];

      # Installed by hand rather than through nix-darwin's own app handling,
      # which copies bundles into "/Applications/Nix Apps" and re-signs them.
      # The permission grants are keyed to the bundle identifier plus the
      # signing identity, so anything that re-signs behind our back drops
      # them. Same reasoning as rift's module.
      system.activationScripts.applications.text = lib.mkAfter ''
        app_source="${cfg.package}/Applications/xkeys.app"
        app_target="/Applications/xkeys.app"
        sign="${cfg.signingIdentity}"
        keychain=/Library/Keychains/System.keychain

        echo "installing xkeys.app..." >&2
        # The app may be running and holding its own binary open, so stop it
        # before the bundle is replaced.
        /usr/bin/pkill -x xkeys 2>/dev/null || true
        rm -rf "$app_target"
        ${pkgs.rsync}/bin/rsync -a "$app_source/" "$app_target/"
        chmod -R u+w "$app_target"

        if [ "$sign" != "-" ] && ! /usr/bin/security find-certificate -c "$sign" "$keychain" >/dev/null 2>&1; then
          echo "xkeys: identity '$sign' unavailable; signing ad-hoc (permissions will be re-prompted)." >&2
          sign="-"
        fi
        /usr/bin/codesign --force --sign "$sign" --identifier com.xieyt.xkeys "$app_target"
        echo "✓ xkeys.app signed with $sign" >&2
      '';
    })

    (lib.mkIf cfg.manageSigningIdentity {
      # Root already, so no sudo. The certificate is created once and then
      # found on every later activation.
      system.activationScripts.postActivation.text = lib.mkAfter ''
      sign="${cfg.signingIdentity}"
      keychain=/Library/Keychains/System.keychain

      if ! /usr/bin/security find-certificate -c "$sign" "$keychain" >/dev/null 2>&1; then
        echo "xkeys: creating code-signing identity '$sign'..." >&2
        cdir=$(mktemp -d)
        printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$sign" > "$cdir/c.cnf"

        # /usr/bin/openssl, never one from nixpkgs or Homebrew: OpenSSL 3
        # writes an AES/SHA-256 PKCS#12 the Security framework refuses with
        # "MAC verification failed", and its -legacy escape hatch does not
        # exist in the LibreSSL that ships with macOS. The explicit
        # 3DES/SHA-1 flags below are understood by both.
        if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
             -keyout "$cdir/k.pem" -out "$cdir/c.pem" -config "$cdir/c.cnf" -extensions v3 >/dev/null 2>&1 \
           && /usr/bin/openssl pkcs12 -export -inkey "$cdir/k.pem" -in "$cdir/c.pem" \
             -out "$cdir/c.p12" -passout pass:xkeys -name "$sign" \
             -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
           && /usr/bin/security import "$cdir/c.p12" -k "$keychain" -P xkeys -A -T /usr/bin/codesign >/dev/null 2>&1 \
           && /usr/bin/security add-trusted-cert -d -r trustRoot -p codeSign -k "$keychain" "$cdir/c.pem" >/dev/null 2>&1; then
          echo "xkeys: identity '$sign' created. Sign with: just signing_cert=$sign install" >&2
        else
          echo "xkeys: WARNING could not create identity '$sign'; xkeys will be ad-hoc signed" >&2
          echo "       and macOS will re-prompt for permissions on every build." >&2
        fi
        rm -rf "$cdir"
      fi
      '';
    })
  ];
}
