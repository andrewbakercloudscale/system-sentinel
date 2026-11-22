# Fleet rollout checklist

For IT, rolling System Sentinel out to the company's Macs through MDM (Jamf, Intune, Kandji or
similar). Settings are explained in `docs/ENTERPRISE.md`, signing in `docs/SIGNING.md`.

## Before you start

- [ ] Macs run macOS 14 (Sonoma) or later. Apple chips and Intel are both supported.
- [ ] Security has reviewed `docs/ENTERPRISE.md`, mainly "Network traffic" (what leaves the
      Mac, and when) and "Built-in protections".
- [ ] Decide who owns the app internally. They receive each new release and push it.

## 1. Prepare the profiles

- [ ] **Settings profile:** `docs/SystemSentinel-Managed.mobileconfig`.
  - Replace `corp.example.com` in `InternalDomains` with the company's internal DNS suffixes,
    for example `corp.company.com` and `company.local`.
  - Set `PayloadOrganization` to the company name.
  - Keep these on:
    - `DisableSelfUpdate`: only IT installs new versions;
    - `DisableAdminActions`: the app never asks for an administrator password;
    - `DisablePublicDNSLookups`: internal names never go to Cloudflare or Google;
    - `DisableExplain`: no process details go to ChatGPT.
  - `DisableProcessControl`: off lets people quit their own runaway apps. Set it to true to make
    the app read-only.
  - The profile also approves the login item, so people cannot switch it off by mistake.
- [ ] **Privacy profile:** run `bash scripts/make-pppc.sh "/path/to/System Sentinel.app"` on
      the release's app. It writes `dist/SystemSentinel-Privacy.mobileconfig`, which
      pre-approves Finder (empty the Trash) and Chrome (its tab list). Add `--full-disk-access`
      only if people need Storage to size every folder. It never approves Terminal.
- [ ] Upload both profiles. Scope them to the pilot group first.

## 2. Package

- [ ] Download `System-Sentinel-VERSION.pkg` and `SHA256SUMS-VERSION.txt` from
      https://github.com/andrewbakercloudscale/system-sentinel/releases. Check the hash:
      `shasum -a 256 System-Sentinel-VERSION.pkg`.
- [ ] Upload the .pkg to MDM. Until the Developer ID switch the package is unsigned:
  - Jamf and Kandji: deploy it as it is;
  - Intune: use the "macOS app (PKG)" type for unmanaged packages.
- [ ] The package installs to `/Applications`, quits a running copy first, starts the new one
      for the person logged in, and removes copies people installed in `~/Applications`.

## 3. Pilot (10 to 20 Macs, one week)

- [ ] Profiles arrive before the package. Checkup lists "Managed by your organisation
      (MDM)", and switched-off features say "Turned off by your organisation."
- [ ] The red chip shows in the menu bar after install and after a restart.
- [ ] No privacy prompts for Finder or Chrome.
- [ ] Endpoint security (EDR, Zscaler, Netskope and so on) raises no alerts. If it does,
      allow-list by bundle id `consulting.cloudscale.systemsentinel` and the signature in
      `docs/ENTERPRISE.md`.
- [ ] Ask the pilot group: is battery life the same, and is the app useful?

## 4. Roll out in waves

- [ ] Wave 1: about 10% (200 Macs). Wait two working days and check the help desk queue.
- [ ] Wave 2: about 40%.
- [ ] Wave 3: everyone else.
- [ ] A help desk note: what the app is, that it reads but sends nothing, and who owns it.

## 5. Updates

- [ ] Each release is published on GitHub with a .pkg and checksums. The owner tests it on a
      few Macs, then updates the package in MDM. Self-update stays off.

## Rollback

- Remove the app: scope a script that runs
  `pkill -x SystemSentinel; rm -rf "/Applications/System Sentinel.app"`, then remove the
  profiles. History stays in each person's
  `~/Library/Application Support/SystemSentinel` until deleted.
- Go back a version: deploy the earlier release's .pkg. It replaces a newer copy.

## When the Developer ID arrives

- [ ] Follow `docs/SIGNING.md`. The first Developer ID release is signed and notarised.
- [ ] Make a new privacy profile from that release (`scripts/make-pppc.sh`). The old one names
      the old signature.
- [ ] Deploy the new privacy profile and the new .pkg together. The package replaces the old
      app even though the signer changed.
