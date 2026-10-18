{ lib, stdenv, swift, swiftpm }:

stdenv.mkDerivation (finalAttrs: {
  pname = "xkeys";
  version = "1.0.0";

  src = lib.cleanSourceWith {
    src = ../.;
    # Keep the store path stable across edits to things the build ignores.
    filter = path: type:
      let base = baseNameOf path; in
      !(builtins.elem base [ ".build" ".git" "result" ".direnv" ]);
  };

  nativeBuildInputs = [ swift swiftpm ];

  # arm64 only. The config this is written for dropped Intel support, and a
  # universal build doubles compile time for nobody.
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    swift build -c release --disable-sandbox
    runHook postBuild
  '';

  # A bare binary is not an installable app: the menu bar agent needs its
  # bundle, and the bundle identifier is what macOS attaches the Accessibility
  # and Input Monitoring grants to.
  installPhase = ''
    runHook preInstall

    app=$out/Applications/xkeys.app
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" $out/bin

    bin="$(swift build -c release --disable-sandbox --show-bin-path)/xkeys"
    cp "$bin" "$app/Contents/MacOS/xkeys"
    cp Info.plist "$app/Contents/Info.plist"
    cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

    # The version in the plist has to match the one compiled in, or `xkeys
    # --version` and Finder disagree.
    /usr/bin/plutil -replace CFBundleVersion -string "${finalAttrs.version}" "$app/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleShortVersionString -string "${finalAttrs.version}" "$app/Contents/Info.plist"

    # Swift links against the OS runtime in /usr/lib/swift - every dylib in
    # the binary resolves there, none in the store - but SwiftPM still stamps
    # the build toolchain's library directory in as a search path. Nix scans
    # outputs for store paths, finds that one string, and concludes the 496 KB
    # app needs the compiler: swiftc, lldb and the Apple SDK, 2.98 GiB, in
    # every system closure. The compiler's own default is not to add it.
    #
    # Deleting a load command invalidates the signature, so re-sign ad-hoc;
    # activation re-signs with the machine identity anyway.
    for rp in $(otool -l "$app/Contents/MacOS/xkeys" |
                  awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' |
                  grep '^/nix/store/'); do
      install_name_tool -delete_rpath "$rp" "$app/Contents/MacOS/xkeys"
    done
    /usr/bin/codesign --force --sign - --identifier com.xieyt.xkeys "$app"

    # Reachable on PATH for `xkeys doctor`, `keys`, `check` and `watch`.
    ln -s "$app/Contents/MacOS/xkeys" $out/bin/xkeys

    runHook postInstall
  '';

  # Signed at activation with the machine's stable identity, not here: the
  # store copy would otherwise carry a signature that changes with every
  # rebuild, and macOS keys the permission grants to the identity.
  dontFixup = true;

  meta = {
    description = "Driver-level key swaps, external keyboard replay, and modifier chords for macOS";
    homepage = "https://github.com/Xieyt/xkeys";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "xkeys";
  };
})
