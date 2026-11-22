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

## 2. Check what is in place

    bash scripts/check-signing.sh TEAMID

It lists the certificates, the notarisation profile and the two lines below, and says
"Ready." when nothing is missing. It changes nothing.

## 3. Switch the publisher (two lines)

- `scripts/sign-id.sh`: `SENTINEL_PUBLISHER_TEAM="TEAMID"`.
- `install.sh`: `PUBLISHER_TEAM="TEAMID"`. It then accepts the self-signed builds and that
  team's Developer ID builds.

From then on `scripts/publish-release.sh` works as before, but `release.sh`:

- signs only with that team's Developer ID Application certificate, with the hardened runtime
  and a secure timestamp, and refuses to release without it;
- notarises and staples the app and the .dmg (profile `system-sentinel`, or `NOTARY_PROFILE`);
- builds `dist/System-Sentinel-VERSION.pkg` (`scripts/build-pkg.sh`), signed with the Developer
  ID Installer certificate, notarised and stapled.

Until the switch, `release.sh` signs with the self-signed certificate and stops if a
Developer ID is forced on it (`ALLOW_OTHER_SIGNER=1` for a test build), so nothing switches by
accident because a certificate turned up in the keychain. The .pkg is built either way:
unsigned before the switch, which Jamf and Kandji deploy as it is and Intune takes as an
"unmanaged macOS PKG".

The .pkg always installs to `/Applications/System Sentinel.app`, owned by root. It is not
relocatable, so it never upgrades a stray copy elsewhere instead. It quits a running copy first
and starts the new one for the person logged in afterwards.

The in-app updater needs no change. It accepts only builds that meet the running copy's
designated requirement, so Developer ID builds update to Developer ID builds.

## Privacy profile

    bash scripts/make-pppc.sh [APP] [--full-disk-access]

writes `dist/SystemSentinel-Privacy.mobileconfig`, tied to the app's own signature: today the
self-signed certificate, after the switch the Team ID. Make a new one after the switch. It
approves Apple Events to Finder, Google Chrome and System Events, never Terminal.

## 4. Roll out

1. Existing self-signed copies reject a Developer ID build as an update, because it has a
   different signer. That is the updater working as designed. Install the first Developer ID
   build through MDM as a fresh install over the old one.
2. Upload these profiles before the app:
   - `docs/SystemSentinel-Managed.mobileconfig` (settings and login item);
   - the privacy profile from `scripts/make-pppc.sh`, made from the Developer ID build. Add
     `--full-disk-access` only if Storage needs it. **Do not pre-approve Terminal**: that lets
     the app run any shell command.
3. Keep `DisableSelfUpdate` on. MDM delivers each new .pkg.
4. Once every Mac runs the Developer ID build, stop using the self-signed certificate for
   System Sentinel and delete it from the build keychain.
