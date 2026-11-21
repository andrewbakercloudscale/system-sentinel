# Moving to Developer ID signing

Today every copy of System Sentinel trusts one self-signed certificate ("Claude Burst Local
Signing", SHA-1 `8D7FBBB7…`) that lives in one login keychain. Nobody can revoke it. If it
leaks, someone could sign a fake build that installs as an update and keeps the app's privacy
permissions. A company Developer ID certificate fixes this: Apple can revoke it, Gatekeeper
accepts it, and privacy (PPPC) profiles can name the Team ID.

## 1. Get the certificates (company Apple Developer account, about 1 hour)

1. Enrol the organisation in the Apple Developer Program, as an organisation rather than a
   person. You need a D-U-N-S number. The fee is USD 99 a year.
2. In Certificates, IDs & Profiles, create:
   - a **Developer ID Application** certificate, to sign the app;
   - a **Developer ID Installer** certificate, to sign the .pkg for MDM.
3. Make the private keys on a dedicated build Mac or in a hardware token, never on a personal
   laptop. Keep an encrypted offline backup.
4. Save notarisation credentials once:
   `xcrun notarytool store-credentials system-sentinel --apple-id <id> --team-id <TEAMID>`
   Use an app-specific password or an App Store Connect API key.

## 2. Build, notarise and package

`scripts/release.sh` already handles the app. When a Developer ID Application identity is in
the keychain, it signs with the hardened runtime and a secure timestamp, notarises, staples
and checks the result with Gatekeeper:

    NOTARY_PROFILE=system-sentinel bash scripts/release.sh

For MDM, wrap the notarised app in a signed installer that puts it in /Applications, owned
by root:

    pkgbuild --component "build/System Sentinel.app" --install-location /Applications \
      --identifier consulting.cloudscale.systemsentinel.pkg --version <VERSION> \
      --sign "Developer ID Installer: <Company> (<TEAMID>)" dist/System-Sentinel-<VERSION>.pkg
    xcrun notarytool submit dist/System-Sentinel-<VERSION>.pkg --keychain-profile system-sentinel --wait
    xcrun stapler staple dist/System-Sentinel-<VERSION>.pkg

## 3. Switch the publisher in the code

- `scripts/sign-id.sh`: set `SENTINEL_PUBLISHER_ID` to the new certificate's SHA-1, or let
  release.sh pick the Developer ID identity.
- `install.sh`: replace the pinned `certificate leaf` hash with
  `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"`.
- The in-app updater needs no change. It accepts only builds that meet the running copy's
  designated requirement, so Developer ID builds update to Developer ID builds.

## 4. Roll out

1. Existing self-signed copies reject a Developer ID build as an update, because it has a
   different signer. That is the updater working as designed. Install the first Developer ID
   build through MDM as a fresh install over the old one.
2. Upload these profiles before the app:
   - `docs/SystemSentinel-Managed.mobileconfig` (settings and login item);
   - a PPPC profile for bundle id `consulting.cloudscale.systemsentinel` with the code requirement
     `anchor apple generic and identifier "consulting.cloudscale.systemsentinel" and certificate leaf[subject.OU] = "<TEAMID>"`.
     Grant Full Disk Access (`SystemPolicyAllFiles`) only if Storage needs it. For
     Automation, allow Finder and Google Chrome. **Do not pre-approve Terminal**: that lets
     the app run any shell command.
3. Keep `DisableSelfUpdate` on. MDM delivers each new .pkg.
4. Once every Mac runs the Developer ID build, stop using the self-signed certificate for
   System Sentinel and delete it from the build keychain.
