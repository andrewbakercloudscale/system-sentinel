# Deploying System Sentinel to a fleet

## Managed settings

Set these booleans with a configuration profile (MDM) for the preference domain
`consulting.cloudscale.systemsentinel`. Only values the profile forces count: `defaults write`
and launch arguments are ignored, so a person cannot turn a policy off.

| Key | Effect when `true` |
|---|---|
| `DisableSelfUpdate` | No update checks, no Install or Reinstall, no "Share with a friend". IT deploys each version. |
| `DisableExplain` | No "Explain with ChatGPT". |
| `DisablePublicDNSLookups` | The DNS map asks only the Mac's own DNS servers: no 1.1.1.1, 8.8.8.8, DNS over HTTPS or root walk. Recommended: without it, a name counts as internal only if it has no dot, a private suffix (.local, .internal, .corp…) or falls under a VPN or search domain, so internal names under your public domain (jira.corp.example.com) can reach public resolvers. |
| `InternalDomains` | An array of your domains (`corp.example.com`, `example.internal`). Names under them are never sent to public DNS, on or off the VPN. Use it if you leave `DisablePublicDNSLookups` off. |
| `DisableProcessControl` | No Kill, Force kill, Auto-kill, memory quit rules or lowering priority. Monitoring and alerts stay. |
| `DisableAdminActions` | Nothing asks for the admin password: no root kills, Free up memory (purge), Low Power Mode, Checkup admin fixes, removing system startup items, or sudo kill commands for Terminal. |
| `autoUpdateCheck` | `false` stops the daily update check (also covered by `DisableSelfUpdate`). |

A ready-to-upload profile with these recommended values and a managed login item (replace the `corp.example.com` placeholder under `InternalDomains` with your own domains) is in
[`SystemSentinel-Managed.mobileconfig`](SystemSentinel-Managed.mobileconfig).

Example payload:

```xml
<dict>
    <key>PayloadType</key><string>consulting.cloudscale.systemsentinel</string>
    <key>PayloadIdentifier</key><string>com.example.systemsentinel.settings</string>
    <key>PayloadUUID</key><string>REPLACE-WITH-A-UUID</string>
    <key>PayloadVersion</key><integer>1</integer>
    <key>DisableSelfUpdate</key><true/>
    <key>DisableExplain</key><true/>
    <key>DisablePublicDNSLookups</key><true/>
    <key>DisableProcessControl</key><false/>
    <key>DisableAdminActions</key><true/>
</dict>
```

## Built-in protections (not settings)

- Security, VPN and device management software (CrowdStrike, Defender, SentinelOne, Forcepoint,
  Netskope, Zscaler, Intune, Jamf and others, see `SecurityAgents.known` and
  `BackgroundItems.managed`) is never killed, auto-killed, slowed or removed as a startup item,
  even with the admin password. It is still reported when it uses a lot of CPU. This matches
  names and paths: it prevents mistakes, it is not a tamper control.
- Admin actions are a fixed list of commands; nothing read from the Mac is put into them unchecked.
  Root never writes into a folder the user can change.
- Every fix that changes a security setting turns protection on, never off.
- Updates are installed only when signed by the publisher's certificate, and never older than
  the running copy. `install.sh` makes the same signature check.
- Signed with the hardened runtime: no code can be injected to borrow its privacy permissions.

## Network traffic

| Destination | When | What is sent |
|---|---|---|
| api.github.com, github.com | Daily update check, and installs | Nothing about the Mac |
| 1.1.1.1 (ping), captive.apple.com (HTTP) | Every few minutes | Nothing about the Mac |
| One fixed test name (`nxdomain-check-7f3a9c2e.system-sentinel-test.com`) via the Mac's DNS | Every 10 minutes | A DNS lookup that should fail |
| github.com, registry.npmjs.org, pypi.org (TLS certificate check) | Every 30 minutes | Nothing about the Mac |
| 1.1.1.1, 8.8.8.8, cloudflare-dns.com, dns.google, root servers | Only when a person maps a public name in the DNS map | That name |
| ip.zscaler.com | Only when a Zscaler tunnel is present | Nothing about the Mac |
| origin.asn.cymru.com (DNS TXT, via the Mac's DNS) | Only in the DNS map and route trace, for public addresses | Those addresses |

No telemetry, analytics or crash reporting is sent anywhere.

## Recommended for a rollout

- Deploy as a package through MDM, with the profile above.
- Grant Full Disk Access with a privacy (PPPC) profile using the code requirement
  `identifier "consulting.cloudscale.systemsentinel" and certificate leaf = H"8d7fbbb7fa351e97aebea46f65d73e69c1adab89"`.
- Better: a Developer ID signed and notarised build, so Gatekeeper and endpoint tools identify
  the publisher by Team ID. Ship the change of signer only together with an update that accepts both.
