# WireSockUI

WireSockUI is a lightweight WinForms interface for managing WireSock tunnels through the WireSock SDK `wgbooster.dll` API. It is intended for installations that provide the driver, the C++ CLI/service components, and `wgbooster.dll` directly.

WireSockUI does not talk to the newer WireSock Secure Connect service API. Keep using this project when you need the direct SDK/DLL integration model.

## Requirements

- Windows 10 or later with a matching-architecture WireSock SDK installation.
- `wgbooster.dll` installed through the WireSock SDK/minimal installer. Application-adjacent copies are intentionally ignored.
- The WireSock driver installed and usable by the current system.
- .NET Framework 4.7.2 or later for x86 and x64, or .NET Framework 4.8.1 or later for ARM64. .NET Framework 4.8.1 is the first release with a native ARM64 CLR.
- Administrator privileges. Start the signed native `WireSockUI.exe` host; `WireSockUI.Managed.dll` is a library and is not an application entry point. The host owns the UAC boundary, removes CLR/AppDomain injection environment variables, validates and locks the complete runtime payload, and then starts the .NET Framework CLR inside the same process with `WireSockUI.exe.config`. The elevated token must belong to the account signed in to the current desktop session; over-the-shoulder UAC credentials from a different administrator are rejected so per-user autorun and notification artifacts cannot be redirected to that account.
- Installation through an official architecture- and flavor-specific MSI. The supported locations are the fixed, private `%ProgramFiles%\WireSock Foundation WireSock UI` leaf for x64/ARM64 and `%ProgramFiles(x86)%\WireSock Foundation WireSock UI` for x86. Network shares, mapped drives, removable media, reparse-point paths, user-writable copies, extracted build artifacts, and portable ZIP deployments are unsupported and rejected.

Before loading the CLR, the native host validates its local fixed-drive path, owner and DACL, link and reparse state, architecture, `WireSockUI.exe.config`, and every file named by its embedded canonical payload manifest. Each manifest entry includes the exact relative path, size, and SHA-256 digest. Unexpected files and missing or changed payload files fail closed, and validated directories and files remain open for the lifetime of the process so they cannot be replaced between verification and use. Managed startup performs a second bounded validation of the elevated runtime and registered SDK location.

At startup WireSockUI looks for `wgbooster.dll` in this order:

1. WireSock Secure Connect SDK registry install locations under `HKLM\Software\WireSock Foundation\WireSock Secure Connect`.
2. WireSock Secure Connect Pro SDK registry install locations under `HKLM\Software\WireSock Foundation\WireSock Secure Connect Pro`.
3. The legacy WireSock VPN Client registry location under `HKLM\SOFTWARE\NTKernelResources\WinpkFilterForVPNClient`.

For each registered install location it checks `sdk`, `bin`, and the install root. WireSockUI validates the directory, `wgbooster.dll`, and executable/DLL companion ownership and ACLs, then loads the exact validated DLL with a restricted DLL search path instead of changing the machine-wide environment or relying on `PATH`. A signed WireSockUI launcher therefore cannot be repackaged with an arbitrary adjacent SDK DLL. SDK companion validation is limited to 1,024 entries per candidate directory.

## Configuration Notes

WireSock-specific directives use the current SDK's exact, case-sensitive `#@ws:` comment-extension syntax:

```ini
#@ws:AllowedApps = app.exe
#@ws:DisallowedIPs = 192.168.1.0/24
#@ws:VirtualAdapterMode = false
#@ws:Socks5ProxyAllTraffic = false
```

Plain WireGuard keys are still parsed normally. WireSockUI validates current SDK fields such as script hooks, masking parameters, SOCKS5 settings, and profile-level `VirtualAdapterMode` while preserving the file-based profile workflow. Direct `wgbooster.dll` integration does not implement `BypassLanTraffic`; specify the LAN prefixes to bypass with `#@ws:DisallowedIPs` in `[Peer]` instead.

The elevated native engine receives only the exact, allowlisted `[Interface]` and `[Peer]` directives understood by this WireSockUI/SDK contract. Unknown sections and keys—including future script-like directives—are rejected; upgrade WireSockUI and the SDK together when adopting a new native directive.

Amnezia 2.0 padding values `S1` through `S4` must be in the range `0..1279`. When any Amnezia padding/header option is present, `S1`, `S2`, and `H1` through `H4` are required; `S3` and `S4` remain optional. `H1` through `H4` accept fixed decimal values or inclusive decimal ranges and must not overlap after blank/zero values resolve to their WireGuard defaults. `Jmin` and `Jmax` must be specified together with `Jmin < Jmax`, and pre-handshake size/delay settings require either `Jc` or `Id`. Protocol imitation accepts the SDK's short and long protocol names, such as `quic`/`quic_initial` and `stun`/`stun_request`.

## Migration Notes

- Configuration section names, recognized key names, and `#@ws:` are validated with the same casing as the current SDK. Correct older lowercase or colon-less directives before activation.
- Unknown sections and directives are rejected instead of being passed through to the elevated native parser. Update WireSockUI and the WireSock SDK together before using a newly introduced configuration key.
- Save profiles as valid UTF-8. A leading UTF-8 byte-order mark (BOM) is accepted by the current SDK and WireSock UI; UTF-16 and UTF-32 profiles remain unsupported.
- Empty comma-separated items in `Address`, `AllowedIPs`, and `DisallowedIPs` are ignored to match the current SDK route parser. Required `Address` and `AllowedIPs` lists must still contain at least one usable entry, and non-empty malformed routes are rejected. Empty DNS list items remain invalid so the UI does not silently accept an unusable resolver configuration.
- `BypassLanTraffic`, `Table`, legacy `I1` through `I5`, and `Socks5Username` are rejected because the direct current `wgbooster.dll` parser does not apply them. Use `DisallowedIPs` and `Socks5ProxyUsername` where applicable.
- User-scoped cosmetic settings are upgraded once after installing a new application version. Because the native-host/managed-library layout changes the `LocalFileSettingsProvider` application identity, startup also performs a bounded, read-only search for the previous `WireSockUI.exe_Url_*` and `WireSockUI.exe_StrongName_*` identities under local AppData. Only known, size-limited setting values are imported; reparse points, hard links, malformed XML, and unrelated identities are ignored. Autorun is never inferred from `user.config` because the verified Task Scheduler definition is authoritative. Auto-connect, last profile, adapter mode, and Kill Switch preferences are stored in administrator-protected `%ProgramData%\WireSockUI\PrivilegedSettings.xml`; importing legacy protected values still requires explicit confirmation.
- Profiles that remain writable by non-administrative users after startup hardening are not listed or activated. ACL hardening failures now stop initialization instead of continuing with a privileged, mutable configuration.

Profiles are stored in `%ProgramData%\WireSockUI\Configs` with an administrators-only ACL because WireSockUI runs elevated. Existing profiles from the older per-user `%AppData%\WireSockUI\Configs` folder are copied into `%ProgramData%\WireSockUI\PendingLegacyProfiles` and presented for explicit review in the full profile editor. Migration uses one consolidated confirmation and opens at most 20 pending profiles per launch; remaining profiles stay staged for the next launch. The legacy source remains untouched until the reviewed profile is saved successfully; approval then removes the staged copy and original source. Name collisions are never overwritten automatically, including names that differ only by letter case on case-sensitive Windows directories. Legacy migration, manual import, catalog loading, activation, and editing enforce a 1 MiB profile limit and reject reparse-point sources; trim larger profiles before using them. Address/route lists are additionally capped at 256 KiB and 4,096 values, application lists at 64 KiB and 1,024 values, and scalar, endpoint, key, numeric, Boolean, and script values have field-specific limits before UI or native processing. The active, legacy, and pending profile catalogs are each limited to 1,024 directory entries, including non-profile files and subdirectories, so startup cannot be stalled by an unbounded directory; archive unused entries before exceeding that limit. The tray menu renders at most 50 profiles and directs larger catalogs to the main window. Startup ACL hardening also stops when a secured data-tree traversal exceeds 4,096 entries. Profile files that are reparse points are not loaded, imported, saved over, or activated; app-owned reparse-point files in the secured profile tree are removed during startup hardening, and unsafe directories or failed ACL updates stop startup. Script hooks are displayed and require confirmation before the reviewed profile can be saved or activated.

The legacy `%AppData%` source may be an absolute redirected or network profile path; it is treated only as an untrusted, bounded read source. Privileged `%ProgramData%` storage must remain on a local fixed drive. Because the secured profiles directory is not readable by an ordinary Explorer process, Settings copies and displays its path instead of attempting to open it unelevated.

Profile edits and imports are staged in the administrator-owned `%ProgramData%\WireSockUI\Configs\.transactions` directory. Rename intent is journaled with write-through file operations before the visible profile name changes. The next startup completes or safely abandons an interrupted rename and removes app-owned temporary files, including temporary files left by older WireSockUI versions. Do not place user-managed files in `.transactions`.

Runtime state that can be written by the elevated process, including protected connection settings and the native recovery marker, is kept under the secured `%ProgramData%\WireSockUI` folder rather than per-user AppData. The UWP notification icon is stored under a dedicated `%ProgramData%\WireSockUI-Notifications` folder with a read-only Users ACL so the toast platform can load it without allowing unelevated writes.

Elevated autorun and SDK DLL loading are available only when the target file, containing directory, and replacement-sensitive ancestor path are administrator-owned. Install WireSockUI and the SDK into administrator-owned locations.

Driver ownership remains coordinated with the SDK CLI/service through the shared `Global\WiresockClientService` object. WireSock UI validates that object's owner and access rules and fails closed when it was pre-created with an incompatible or untrusted security descriptor; close the process that owns the conflicting object before retrying. Because this fixed global name is an SDK compatibility primitive and Windows cannot replace a kernel object while another process holds it, an ordinary process can squat on the name and deny WireSock UI startup. The squatting object is never trusted and cannot grant driver control, but eliminating this availability risk requires a coordinated SDK/service bootstrap or protected-private-namespace change.

Autorun tasks are scoped to the current Windows user and have no execution-time limit. Inspection and mutation run in a serialized helper process with hard operation deadlines; a timed-out mutating helper is terminated as a process tree and further mutation remains blocked until the final Task Scheduler state is verified. Opening and saving Settings migrates a validated older WireSockUI autorun task to the current launcher definition. A lone regular file at the legacy per-user Startup shortcut name is not trusted as proof that autorun was enabled and defaults to off. WireSockUI never deletes that opaque artifact or replaces it with a protected elevated task without explicit cleanup or migration confirmation; deletion is deferred until the rest of the Settings transaction commits. Settings are applied as a compensating transaction: autorun, runtime log level, Kill Switch state, and persisted preferences are rolled back together when a later step fails. When compensation verifies the native state, WireSockUI clears the temporary recovery latch and restores the previous connection state and monitor instead of requiring an application restart.

This release applies the same trust requirement to the complete WireSockUI application payload. Replace an existing portable installation with the matching official MSI; copying the files into Program Files is not a supported installation or upgrade path. The installer establishes the protected directory ACL, and the native host independently verifies the installed payload on every launch.

Profiles containing `PreUp`, `PostUp`, `PreDown`, or `PostDown` script hooks require confirmation before import/save and again before activation. Treat script-hook profiles as privileged code.

Script-hook confirmation displays every complete command in a scrollable, read-only view, escapes invisible control and bidirectional-formatting characters, and defaults to rejection. Profile names are limited to a single Windows filesystem component of at most 250 characters.

The Settings dialog includes an optional Kill Switch toggle. When enabled, WireSockUI calls the `wgbooster.dll` network-lock API before creating the tunnel, preserves the native lock during reconnect/profile-switch cleanup, and clears the lock through normal tunnel cleanup when disconnecting. The option is off by default so existing SDK/minimal installations keep their current behavior.

If a native connect or cleanup call does not return, WireSockUI marks the state as indeterminate and disables further tunnel operations. It does not issue a concurrent reset against the process-global SDK while the original call is still executing. Once that call returns, WireSockUI performs sequence-checked cleanup and records a secured recovery marker if the outcome remains uncertain. Recovery markers are replaced atomically and carry operation ownership, so an older late completion cannot remove or overwrite a newer failure record. A successful compensation or preserved-lock retry clears the corresponding recovery state immediately. Shutdown cleanup timeouts do not block process exit; the next elevated launch always queries the global network-lock state, including when no marker could be written. Use **Reset Kill Switch** from the tray menu while disconnected or in recovery mode if network access remains blocked.

Bounded diagnostic logs are written to `%ProgramData%\WireSockUI\Logs\WireSockUI.log`. The current log is limited to 1 MiB with three rotated archives, uses an administrators-only ACL, and redacts WireGuard private keys, preshared keys, SOCKS5 passwords, and URI credentials. Native UI logs are also bounded and drained in batches; retained native records are limited to 4,096 UTF-16 code units and carry a `[truncated]` suffix when shortened. The log view reports how many entries were dropped when either queue is saturated. Include these logs when reporting startup, recovery, or SDK-loading failures.

## Compatibility Notes

- The native `wgbooster.dll` ABI is expected to match the current SDK headers, including log levels, network-lock exports, and `drop_tunnel(..., preserve_network_lock)`.
- The production application deliberately does not support `Any CPU`: every runnable build must have an x86, x64, or ARM64 native host and matching managed payload. Only the managed test project reference opts into a managed-only `Any CPU` build. Hosted managed and STA WinForms tests execute both classic and UWP variants on x86, x64, and ARM64 runners, while real-driver smoke tests use the corresponding x86-, x64-, and ARM64-workload SDK pools.
- WireSockUI uses the same global direct-client event name as the C++ CLI/service to avoid running side by side with another direct SDK tunnel owner.
- The newer WireSock Secure Connect service stack is intentionally out of scope for this project.

## Building

```powershell
dotnet restore WireSockUI.sln -p:Platform=x64 -m:1
dotnet run --project WireSockUI.Tests\WireSockUI.Tests.csproj --configuration Release --framework net472-windows
dotnet build WireSockUI.sln --configuration Release -p:Platform=x64 -p:UseSharedCompilation=false -m:1
dotnet build WireSockUI.sln --configuration "Release UWP" -p:Platform=x64 -p:UseSharedCompilation=false -m:1
dotnet publish WireSockUI\WireSockUI.csproj --configuration Release --framework net472-windows --no-self-contained --no-restore -p:Platform=x64 -p:UseSharedCompilation=false -m:1
```

Release builds require the Visual C++ Build Tools and Windows SDK. `scripts\Build-NativeBootstrap.ps1` compiles the architecture-matched `WireSockUI.exe`, embeds the canonical path/size/SHA-256 payload manifest and native application manifest, and verifies the linked manifest and version resources. The managed output is `WireSockUI.Managed.dll`; the native host loads its public hosted entry point in-process under `WireSockUI.exe.config`.

Build an MSI only from a completed architecture-specific publish directory after signing its native host. For example:

```powershell
dotnet restore WireSockUI.Installer\WireSockUI.Installer.wixproj --locked-mode
.\scripts\Build-Msi.ps1 `
  -Platform x64 `
  -Version 1.2.3 `
  -Flavor no-uwp `
  -PayloadDirectory .\bin\x64\Release\net472-windows\publish `
  -OutputDirectory .\artifacts\msi `
  -NoRestore
```

Use `x86`, `x64`, or `ARM64` with `no-uwp` or `uwp`. `-AllowUnsignedPayload` exists only for local installer testing; supported releases require an Authenticode-signed native host and a separately signed MSI. See [WireSockUI.Installer/README.md](WireSockUI.Installer/README.md) for package validation and disposable-machine installation tests.

Use `-- --list-tests` to list test names or `-- --filter "profile catalog"` to run a focused subset with full exception diagnostics. Each executed test has a two-minute timeout, and CI jobs have explicit overall timeouts so a deadlock reports the active test instead of occupying a runner indefinitely.

The single-node `-m:1` solution build avoids a silent MSBuild failure that can happen when recent .NET SDKs schedule the WinForms app and the test project reference concurrently.

CI checks both the native header/export ABI and the managed P/Invoke declarations against the pinned SDK contract snapshot under `sdk-contract`. The snapshot currently comes from `Wiresock-Foundation/wiresock-vpn-client` revision `a5183451c62b42abe0a5fb67be215bb5a9375603`; update the header, export definition, and `SDK_REVISION` together when intentionally adopting a newer SDK revision. A scheduled drift workflow is loaded only from the protected default branch, enters the protected `wiresock-sdk-contract` environment, and obtains a one-hour repository-scoped GitHub App token with `contents: read`. Configure `WIRESOCK_SDK_READER_CLIENT_ID` as an environment variable and `WIRESOCK_SDK_READER_PRIVATE_KEY` as its environment secret; do not use a long-lived repository PAT. The .NET SDK is pinned by `global.json`, NuGet lock files are committed, and CI restores in locked mode.

Pull requests run hosted contract and all six managed architecture/flavor tests, build and statically validate all six MSI variants, exercise the x86, x64, and ARM64 native hosts' pre-CLR self-tests, and perform architecture-matched MSI install/ACL/repair/uninstall smoke tests on guarded ephemeral Windows runners. They never execute branch code on the elevated SDK hosts. Real SDK integration runs after protected `main` updates, weekly through a pinned hosted caller, and before releases. Both CI and release jobs load the reusable privileged workflow definition from one audited full commit SHA; that workflow derives and validates the exact caller commit/ref before any candidate code reaches an SDK runner. The integration workflow exercises transparent and virtual-adapter lifecycle, network-lock enable/reset behavior, and a complete Amnezia 2.0 profile. Protect the `wiresock-sdk` environment with required reviewers. The canonical repository must be organization-owned because personal repositories cannot own an organization runner group. Place disposable, just-in-time x86-workload and x64-workload pools on x64 hosts plus an ARM64-workload pool on ARM64 hosts in an organization runner group named `wiresock-sdk`. Give them the exact logical routing labels `wiresock-sdk-x86`, `wiresock-sdk-x64`, and `wiresock-sdk-arm64`, restrict that group's workflow access to only the exact `wiresock/WireSockUI/.github/workflows/sdk-integration.yml@b769fc2c75da4eac2138c19cd58a0b59dbb2879a` selected workflow used by the callers, and retain the common `wiresock-sdk` runner label; repository access or labels alone are not a sufficient trust boundary. The hosted runner-policy preflight must confirm the selected-workflow restriction, repository access, architecture labels, minimum runner version, and ephemeral state before privileged work is enabled. Do not reuse a runner after a job. Runners must use version `2.329.0` or newer for the Node.js 24 actions and checkout credential handling. Set `WIRESOCKUI_SDK_INTEGRATION_ENABLED=true` only after all three disposable runner pools and the selected-workflow runner-group policy are available. Protected `main` checks warn and skip real-SDK work when validation is unavailable; release checks remain fail-closed, while scheduled runs remain optional.

Configure `WIRESOCKUI_WGBOOSTER_PATH_X86`, `WIRESOCKUI_WGBOOSTER_PATH_X64`, and `WIRESOCKUI_WGBOOSTER_PATH_ARM64` with trusted installed DLL paths. Configure `WIRESOCKUI_TEST_PROFILE_TRANSPARENT`, `WIRESOCKUI_TEST_PROFILE_VIRTUAL_ADAPTER`, and `WIRESOCKUI_TEST_PROFILE_AMNEZIA` with dedicated, administrator-owned, non-production profiles without script hooks. The Amnezia profile must contain `S1`-`S4`, `H1`-`H4`, `Id`, `Ip`, and `Ib`; the legacy `WIRESOCKUI_TEST_PROFILE` remains a fallback for the two standard modes. The workflow fails when a required profile is missing or mutable by non-administrative users.

Install a dedicated organization GitHub App with only Self-hosted runners (read), expose its `WIRESOCK_SDK_RUNNER_POLICY_CLIENT_ID` variable and `WIRESOCK_SDK_RUNNER_POLICY_PRIVATE_KEY` secret through the protected `wiresock-sdk` environment, and scope its installation to this repository. The hosted preflight uses its short-lived token only to audit the runner group; candidate code never receives that token.

Native state and statistics polling use bounded asynchronous queries. If `wgbooster.dll` does not return before the query timeout, WireSockUI stops issuing additional native operations, records a recovery marker, and requires recovery or restart. Startup also compares the process and `wgbooster.dll` PE architectures so x86/x64/ARM64 mismatches are reported directly.

## Releases

The supported release artifacts are six per-machine MSIs: x86, x64, and ARM64, each in `no-uwp` and `uwp` flavors. Portable ZIPs and loose publish directories are not distributed or supported. The workflow builds the six payloads on hosted runners, signs each root-level native `WireSockUI.exe` through Azure Artifact Signing with OIDC, proves every other payload file (including the unsigned `WireSockUI.Managed.dll`) remains byte-identical, packages and signs all six MSIs, and revalidates every signed cabinet against the launcher's embedded payload manifest and a persistent validation document.

Each MSI is published with a separate SPDX SBOM, `*.msi.validation.json` payload inventory, and SHA-256 sidecars for all three assets. GitHub artifact-provenance attestations cover the MSI, validation document, and SBOM. These metadata files are external release evidence and are not added to the installed runtime. Release publication revalidates the signed annotated tag and every checksum immediately before upload and after publication. An interrupted matching draft is resumed only when its tag, target, title, exact asset inventory, sizes, and digests remain consistent; mismatched, duplicate, or unexpected remote state is rejected. GitHub immutable releases must be enabled before signing, and a published matching immutable release is accepted only after every asset is independently verified with a patched GitHub CLI. Enabling the repository setting does not retroactively make historical releases immutable, so treat older releases as legacy evidence. No exportable PFX or long-lived signing secret is stored in GitHub.

The MSI ProductCode is deterministic for version, architecture, and flavor, while all packages share one UpgradeCode. Reinstalling the identical version/architecture/flavor enters Windows Installer maintenance/repair. A same-version flavor or architecture transition is handled as a major upgrade rather than a side-by-side install; this support is for an explicit transition, not for replacing an already-published package with different bytes. Downgrades are blocked. Close WireSock UI and disable autorun for affected accounts before changing architecture, because x86 and native 64-bit packages use different Program Files roots and per-user scheduled tasks are path-bound.

Uninstall removes only MSI-owned runtime files, installer registry data, and the all-users Start Menu shortcut. It does not enumerate or delete other users' scheduled tasks or notification state, and it preserves application-created profiles, protected preferences, recovery data, and logs under `%ProgramData%`. Disable per-user autorun before uninstalling; remove retained user data separately only when it is no longer needed. Unknown files placed in the installation directory are not recursively deleted.

Protect the `release-signing` environment with independent reviewers, self-review prevention, and protected `release-v*.*.*` tags. The signing job must run only through `wiresock/WireSockUI/.github/workflows/release-signing.yml@b769fc2c75da4eac2138c19cd58a0b59dbb2879a`. Configure the repository OIDC subject template with the exact ordered claims `[repo, context, job_workflow_ref]`, then configure the Azure federated identity for `repo:wiresock/WireSockUI:environment:release-signing:job_workflow_ref:wiresock/WireSockUI/.github/workflows/release-signing.yml@b769fc2c75da4eac2138c19cd58a0b59dbb2879a`. Grant only Certificate Profile Signer. The Artifact Signing endpoint must be an HTTPS root URI on the official `codesigning.azure.net` service; tenant, client, and subscription values must be GUIDs. Set these protected environment variables:

- `AZURE_ARTIFACT_SIGNING_CLIENT_ID`
- `AZURE_ARTIFACT_SIGNING_TENANT_ID`
- `AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID`
- `AZURE_ARTIFACT_SIGNING_ENDPOINT`
- `AZURE_ARTIFACT_SIGNING_ACCOUNT_NAME`
- `AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME`
- `AZURE_ARTIFACT_SIGNING_EXPECTED_SUBJECT`
- `AZURE_ARTIFACT_SIGNING_EXPECTED_TIMESTAMP_SUBJECT`

Both `release-signing` and the separate `release-publish` environment must require independent reviewers, prevent self-review, disable administrator bypass, and allow exactly the custom tag policy `release-v*.*.*`. The release preflight also requires organization ownership and enabled immutable releases. Configure repository Actions policy to require full-SHA action pinning, limit allowed actions to the audited set, and protect `main` with required status checks, stale-review dismissal, approval of the latest push, signed commits, resolved conversations, and administrator enforcement. The required checks must include the dependency audit, SDK contract, all six managed architecture/flavor test variants, all six publish checks, all three native-host smoke variants, all three architecture-matched MSI install smoke variants, architecture isolation, and transition smoke, bound to the GitHub Actions App rather than accepting same-named third-party statuses. Repository rules must restrict creation, update, and deletion of the active `release-v*.*.*` namespace and the retired `v*` namespace.

Install a dedicated GitHub App on this repository with only repository Administration (read) and Actions (read) permissions so the workflow can inspect immutable-release, environment, Actions, and OIDC policy. Store `RELEASE_POLICY_READER_CLIENT_ID` as an environment variable and `RELEASE_POLICY_READER_PRIVATE_KEY` as an environment secret in both `release-signing` and `release-publish`. Each protected job exchanges them for a short-lived, repository-scoped token; the normal `GITHUB_TOKEN` cannot read all required settings and is not used for this check.

As a mandatory external repository control, every organization or repository ruleset contributing to `main` or to tag update/deletion restrictions must have an empty bypass-actor list. Put active `release-v*.*.*` creation in a separate creation-only ruleset whose bypass list contains only a narrowly scoped, audited release-tagger user, team, or App; never grant broad roles, administrators, or deploy keys this bypass. Keep update and deletion in separate zero-bypass ruleset layers so even the release tagger cannot move or delete a created tag. The retired `v*` namespace must have zero-bypass update/deletion rules and should retain a zero-bypass creation rule to keep it permanently retired. The read-only checker verifies effective rules for the exact active and corresponding legacy tag, requires the active creation ruleset IDs to be disjoint from mutation ruleset IDs, and probes a representative retired tag, but the full wildcard coverage remains an independently audited configuration requirement. GitHub withholds bypass actors from an Administration (read) token, so the checker cannot enumerate their contents. Do not grant the policy-reader App Administration (write) merely to inspect them, because that would turn a read-only release gate into a repository-takeover credential. Classic branch-protection PR bypass allowances are visible to the read-only checker and must remain empty.

Release tags must be signed annotated tags in strict `release-vMAJOR.MINOR.PATCH` form, resolve directly to the current protected `main` tip, and have a GitHub-verified cryptographic signature. Create them with `git tag -s release-vMAJOR.MINOR.PATCH`; lightweight, unsigned, stale-main, moved, or legacy `v*` tags are rejected. The workflow binds the signed tag object's internal name and exact object ID during authorization, then revalidates both after signing approval, immediately before publication, and after publication. Rotate or delete legacy release PAT/PFX secrets (including `MY_GITHUB_PAT`) before enabling the new namespace. Publication uses only the repository `GITHUB_TOKEN`. Until the organization runner group, protected environments, repository rules, signing variables, OIDC claim template, exact reusable-workflow pins, and immutable-release setting are all configured, integration and release execution is intentionally unavailable rather than silently weakening these controls.

## Remaining Runtime Risks

- The ABI contract job does not prove that the installed driver and SDK DLL work together. Keep release-gated real-SDK x86-workload and x64-workload pools on representative x64 hosts and the ARM64-workload pool on representative ARM64 hosts.
- Tunnel start/stop still depends on driver state and Windows networking permissions after elevation succeeds.
- The global `WiresockClientService` event is an SDK compatibility primitive shared with the direct C++ CLI. WireSockUI rejects unexpected owners and broad ACLs, but changing to a private authenticated namespace requires a coordinated SDK change.
- The direct SDK API still requires the managed tunnel coordinator to run elevated. The native launcher prevents mutable pre-CLR startup and untrusted shell activation, while lifecycle, profile, autorun, and UI responsibilities are isolated behind bounded coordinators; a fully medium-integrity UI would require an authenticated broker/service protocol and coordinated SDK ownership changes.
- The `WireSockUI.Tests` harness covers parser/profile validation, native error-sentinel handling, lifecycle cleanup and bounded monitoring through a deterministic native facade, ACL checks, architecture matching, transactional profile renames, reparse-point rejection, and STA construction/disposal of classic and UWP dialogs. Real driver and `wgbooster.dll` validation remains environment-specific and is handled by the SDK Integration workflow.

## License

This project is licensed under the [MIT License](LICENSE).
