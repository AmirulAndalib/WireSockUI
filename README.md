# WireSock UI

WireSock UI is a simple Windows desktop client for creating, importing, and controlling WireSock VPN tunnels. It uses the direct WireSock SDK installed with WireSock VPN Client CLI; it is not a client for the newer WireSock Secure Connect service API.

## Install

### 1. Install WireSock VPN Client CLI and SDK

Open Windows Terminal or PowerShell and run:

```powershell
winget install --id NTKERNEL.WireSockVPNClientCLI --exact --source winget
```

This installs the WireSock driver, CLI components, and the SDK `wgbooster.dll` used by WireSock UI. If WinGet is unavailable, download the matching x86, x64, or ARM64 WireSock VPN Client CLI installer from the [official WireSock website](https://www.wiresock.net/).

### 2. Install WireSock UI

Download the MSI for your computer from [WireSock UI Releases](https://github.com/wiresock/WireSockUI/releases):

- `WireSockUI-<version>-win-x64-uwp.msi` — recommended for most Intel/AMD Windows computers.
- `WireSockUI-<version>-win-arm64-uwp.msi` — for Windows on ARM computers.
- `WireSockUI-<version>-win-x86-uwp.msi` — only for 32-bit Windows.
- Choose the corresponding `no-uwp` package if you want the core client without Windows notifications or automatic update checks.

Both flavors install the same desktop UI. The `uwp` flavor adds Windows notifications and automatic update checks.

Starting with version `0.3.0`, WireSock UI releases are intentionally unsigned. Windows therefore displays **Unknown publisher** during installation. Verify the downloaded MSI against its published `.sha256` file when installing from a downloaded copy.

The installer can add WireSock UI to the Start menu and create a desktop shortcut. Both options are selected by default. The UWP flavor uses the installer-owned Start-menu shortcut to register Windows notifications; if you deselect that shortcut, notifications remain disabled and WireSock UI does not recreate it later.

### 3. Add and activate a tunnel

1. Start **WireSock UI** and accept the administrator prompt.
2. Select **Add Tunnel** to import an existing WireGuard/WireSock `.conf` file or create a new profile.
3. Select the profile and click **Activate**.

Do not run the WireSock CLI, service, or another direct-SDK tunnel at the same time. These clients share ownership of the WireSock driver session.

## Requirements

- Windows 10 or later.
- A matching-architecture WireSock VPN Client CLI/SDK installation.
- Administrator privileges.
- .NET Framework 4.7.2 or later for x86/x64, or .NET Framework 4.8.1 or later for ARM64.
- The official WireSock UI MSI. Portable copies and loose publish directories are unsupported.

<details>
<summary>Technical runtime, configuration, migration, and security notes</summary>

### Runtime and SDK discovery

Start the native `WireSockUI.exe` host; `WireSockUI.Managed.dll` is a library and is not an application entry point. Release binaries are intentionally unsigned. The host owns the UAC boundary, removes CLR/AppDomain injection environment variables, validates and locks the complete runtime payload, and then starts the .NET Framework CLR inside the same process with `WireSockUI.exe.config`. The elevated token must belong to the account signed in to the current desktop session; over-the-shoulder UAC credentials from a different administrator are rejected so per-user autorun and notification artifacts cannot be redirected to that account.

The supported installation locations are the fixed, private `%ProgramFiles%\WireSock Foundation WireSock UI` leaf for x64/ARM64 and `%ProgramFiles(x86)%\WireSock Foundation WireSock UI` for x86. Network shares, mapped drives, removable media, reparse-point paths, user-writable copies, extracted build artifacts, and portable ZIP deployments are unsupported and rejected.

Before loading the CLR, the native host validates its local fixed-drive path, owner and DACL, link and reparse state, architecture, `WireSockUI.exe.config`, and every file named by its embedded canonical payload manifest. Each manifest entry includes the exact relative path, size, and SHA-256 digest. Unexpected files and missing or changed payload files fail closed, and validated directories and files remain open for the lifetime of the process so they cannot be replaced between verification and use. Managed startup performs a second bounded validation of the elevated runtime and registered SDK location.

At startup WireSockUI looks for `wgbooster.dll` in this order:

1. WireSock Secure Connect SDK registry install locations under `HKLM\Software\WireSock Foundation\WireSock Secure Connect`.
2. WireSock Secure Connect Pro SDK registry install locations under `HKLM\Software\WireSock Foundation\WireSock Secure Connect Pro`.
3. The legacy WireSock VPN Client registry location under `HKLM\SOFTWARE\NTKernelResources\WinpkFilterForVPNClient`.

For each registered install location it checks `sdk`, `bin`, and the install root. WireSockUI validates the directory, `wgbooster.dll`, and executable/DLL companion ownership and ACLs, then loads the exact validated DLL with a restricted DLL search path instead of changing the machine-wide environment or relying on `PATH`. The protected WireSockUI installation therefore cannot be repackaged with an arbitrary adjacent SDK DLL. SDK companion validation is limited to 1,024 entries per candidate directory.

### Configuration Notes

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

### Migration Notes

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

</details>

<details>
<summary>Compatibility, building, release, and maintainer notes</summary>

## Compatibility Notes

- The native `wgbooster.dll` ABI is expected to match the current SDK headers, including log levels, network-lock exports, and `drop_tunnel(..., preserve_network_lock)`.
- The production application deliberately does not support `Any CPU`: every runnable build must have an x86, x64, or ARM64 native host and matching managed payload. Only the managed test project reference opts into a managed-only `Any CPU` build. Hosted managed and STA WinForms tests execute both classic and UWP variants on x86, x64, and ARM64 runners, while real-driver smoke tests use the corresponding x86-, x64-, and ARM64-workload SDK pools.
- WireSockUI uses the same global direct-client event name as the C++ CLI/service to avoid running side by side with another direct SDK tunnel owner.
- The newer WireSock Secure Connect service stack is intentionally out of scope for this project.

## Building

```powershell
dotnet restore WireSockUI.sln -p:Platform=x64 -m:1
$version = .\scripts\Resolve-BuildVersion.ps1
dotnet run --project WireSockUI.Tests\WireSockUI.Tests.csproj --configuration Release --framework net472-windows -p:Version=$version
dotnet build WireSockUI.sln --configuration Release -p:Platform=x64 -p:UseSharedCompilation=false -p:Version=$version -m:1
dotnet build WireSockUI.sln --configuration "Release UWP" -p:Platform=x64 -p:UseSharedCompilation=false -p:Version=$version -m:1
dotnet publish WireSockUI\WireSockUI.csproj --configuration Release --framework net472-windows --no-self-contained --no-restore -p:Platform=x64 -p:UseSharedCompilation=false -p:Version=$version -m:1
```

Release builds require the Visual C++ Build Tools and Windows SDK. `scripts\Build-NativeBootstrap.ps1` compiles the architecture-matched `WireSockUI.exe`, embeds the canonical path/size/SHA-256 payload manifest and native application manifest, and verifies the linked manifest and version resources. The managed output is `WireSockUI.Managed.dll`; the native host loads its public hosted entry point in-process under `WireSockUI.exe.config`.

`version.json` defines the current major/minor build-version epoch. `scripts\Resolve-BuildVersion.ps1` combines it with the protected branch's first-parent history to produce one canonical `MAJOR.MINOR.BUILD` value. Changing `version.json` starts a new epoch at its configured `buildNumberStart`; this change starts `0.3.0`, and each later merged pull request becomes `0.3.1`, `0.3.2`, and so on. On any other feature branch or GitHub pull-request merge ref, the resolver treats the complete candidate as one prospective protected-branch change and refuses branches that are not based on the protected tip. Keep rebase merging disabled: merge commits and squash merges each add exactly one first-parent commit. CI and hosted SDK validation pass that same value to the managed assembly, native launcher, MSI, validation metadata, and artifact names. Release builds require this explicit value; unversioned development builds use `0.0.0` and cannot silently claim a release identity. Run the resolver from a complete, current Git checkout when a local packaging command needs the candidate or protected-branch version. Official release tags remain an explicit release decision, must use the current resolved version, and use the protected `release-vMAJOR.MINOR.BUILD` namespace.

Build an MSI only from a completed architecture-specific publish directory. The builder rejects any payload module with an embedded Authenticode certificate table and verifies the output MSI is also unsigned. For example:

```powershell
dotnet restore WireSockUI.Installer\WireSockUI.Installer.wixproj --locked-mode
.\scripts\Build-Msi.ps1 `
  -Platform x64 `
  -Version 0.3.0 `
  -Flavor no-uwp `
  -PayloadDirectory .\bin\x64\Release\net472-windows\publish `
  -OutputDirectory .\artifacts\msi `
  -NoRestore
```

Use `x86`, `x64`, or `ARM64` with `no-uwp` or `uwp`. Starting with `0.3.0`, supported releases are unsigned MSIs containing only unsigned application EXE/DLL modules. No code-signing certificate or signing environment variable is used by local builds, CI, or release publication. See [WireSockUI.Installer/README.md](WireSockUI.Installer/README.md) for package validation and disposable-machine installation tests.

Use `-- --list-tests` to list test names or `-- --filter "profile catalog"` to run a focused subset with full exception diagnostics. Each executed test has a two-minute timeout, and CI jobs have explicit overall timeouts so a deadlock reports the active test instead of occupying a runner indefinitely.

The single-node `-m:1` solution build avoids a silent MSBuild failure that can happen when recent .NET SDKs schedule the WinForms app and the test project reference concurrently.

CI checks both the native header/export ABI and the managed P/Invoke declarations against the pinned SDK contract snapshot under `sdk-contract`. The snapshot currently comes from `Wiresock-Foundation/wiresock-vpn-client` revision `a5183451c62b42abe0a5fb67be215bb5a9375603`; update the header, export definition, and `SDK_REVISION` together when intentionally adopting a newer SDK revision. A scheduled drift workflow is loaded only from the protected default branch, enters the protected `wiresock-sdk-contract` environment, and obtains a one-hour repository-scoped GitHub App token with `contents: read`. Configure `WIRESOCK_SDK_READER_CLIENT_ID` as an environment variable and `WIRESOCK_SDK_READER_PRIVATE_KEY` as its environment secret; do not use a long-lived repository PAT. The .NET SDK is pinned by `global.json`, NuGet lock files are committed, and CI restores in locked mode.

Pull requests run hosted contract and all six managed architecture/flavor tests, build and statically validate all six MSI variants, exercise the x86, x64, and ARM64 native hosts' pre-CLR self-tests, and perform architecture-matched MSI install/ACL/repair/uninstall smoke tests on guarded ephemeral Windows runners. They never execute branch code on the elevated SDK hosts. Real SDK integration runs after protected `main` updates, weekly through a pinned hosted caller, and before releases. Both CI and release jobs load the reusable privileged workflow definition from one audited full commit SHA; that workflow derives and validates the exact caller commit/ref before any candidate code reaches an SDK runner. The integration workflow exercises transparent and virtual-adapter lifecycle, network-lock enable/reset behavior, and a complete Amnezia 2.0 profile. Protect the `wiresock-sdk` environment with required reviewers. The canonical repository must be organization-owned because personal repositories cannot own an organization runner group. Place disposable, just-in-time x86-workload and x64-workload pools on x64 hosts plus an ARM64-workload pool on ARM64 hosts in an organization runner group named `wiresock-sdk`. Give them the exact logical routing labels `wiresock-sdk-x86`, `wiresock-sdk-x64`, and `wiresock-sdk-arm64`, restrict that group's workflow access to only the exact `wiresock/WireSockUI/.github/workflows/sdk-integration.yml@0440f3d3a42216a23ce455686ce983b88af62a3e` selected workflow used by the callers, and retain the common `wiresock-sdk` runner label; repository access or labels alone are not a sufficient trust boundary. The hosted runner-policy preflight must confirm the selected-workflow restriction, repository access, architecture labels, minimum runner version, and ephemeral state before privileged work is enabled. Do not reuse a runner after a job. Runners must use version `2.329.0` or newer for the Node.js 24 actions and checkout credential handling. Set `WIRESOCKUI_SDK_INTEGRATION_ENABLED=true` only after all three disposable runner pools and the selected-workflow runner-group policy are available. Protected `main` checks warn and skip real-SDK work when validation is unavailable; release checks remain fail-closed, while scheduled runs remain optional.

Configure `WIRESOCKUI_WGBOOSTER_PATH_X86`, `WIRESOCKUI_WGBOOSTER_PATH_X64`, and `WIRESOCKUI_WGBOOSTER_PATH_ARM64` with trusted installed DLL paths. Configure `WIRESOCKUI_TEST_PROFILE_TRANSPARENT`, `WIRESOCKUI_TEST_PROFILE_VIRTUAL_ADAPTER`, and `WIRESOCKUI_TEST_PROFILE_AMNEZIA` with dedicated, administrator-owned, non-production profiles without script hooks. The Amnezia profile must contain `S1`-`S4`, `H1`-`H4`, `Id`, `Ip`, and `Ib`; the legacy `WIRESOCKUI_TEST_PROFILE` remains a fallback for the two standard modes. The workflow fails when a required profile is missing or mutable by non-administrative users.

Install a dedicated organization GitHub App with only Self-hosted runners (read), expose its `WIRESOCK_SDK_RUNNER_POLICY_CLIENT_ID` variable and `WIRESOCK_SDK_RUNNER_POLICY_PRIVATE_KEY` secret through the protected `wiresock-sdk` environment, and scope its installation to this repository. The hosted preflight uses its short-lived token only to audit the runner group; candidate code never receives that token.

The **Hosted WireSock SDK experiment** is an automated x64 and ARM64 compatibility check and does not replace connected-state validation with protected real profiles. It runs after protected `main` updates, weekly, or by manual dispatch, and authorizes only the current protected `main` tip before allocating matching disposable GitHub-hosted Windows VMs. GitHub does not provide a native 32-bit Windows hosted runner, and the WireSock x86 SDK installer intentionally rejects 64-bit Windows, so x86 SDK lifecycle validation requires the protected self-hosted x86-workload pool described above; ordinary hosted CI still builds and installation-tests WireSockUI's x86 package. Each hosted SDK job downloads the exact architecture-specific WireSock installer URI recorded in the audited WinGet manifest without depending on the runner's WinGet availability, verifies its pinned SHA-256 and Authenticode signature, waits for installation completion, rejects a signed `wgbooster.dll` with the wrong PE architecture, builds and installation-tests the matching unsigned candidate MSI, and exercises the real SDK lifecycle with synthetic profiles restricted to IANA documentation networks. The synthetic lifecycle validates handle creation, Kill Switch transitions, tunnel creation/start/state/stop/drop, and cleanup without asserting external connectivity to the intentionally unreachable TEST-NET peer. The experiment uses no VPN credentials or repository secrets and relies on disposal of the ephemeral VM if package cleanup is unavailable. Use **Actions → Hosted WireSock SDK experiment → Run workflow** for an additional current-tip run; treat a green result as architecture/runtime compatibility evidence, not proof of a successful VPN handshake.

Before tagging a release, use **Actions → Unsigned internal release candidate → Run workflow** for an internal packaging rehearsal. It automatically uses the current protected `main` tip's resolved build version, after successful current-tip CI and hosted SDK experiment push runs, rebuilds and validates all six architecture/flavor MSIs, and repeats architecture-matched installation smoke tests. The resulting `UNSIGNED-INTERNAL-RC-*` bundle is retained for 14 days and contains an explicit warning plus SHA-256 checksums. These packages use the same unsigned binary policy as official releases, but are not published to GitHub Releases and must be used only on disposable test systems.

Native state and statistics polling use bounded asynchronous queries. If `wgbooster.dll` does not return before the query timeout, WireSockUI stops issuing additional native operations, records a recovery marker, and requires recovery or restart. Startup also compares the process and `wgbooster.dll` PE architectures so x86/x64/ARM64 mismatches are reported directly.

## Releases

The supported release artifacts are six per-machine MSIs: x86, x64, and ARM64, each in `no-uwp` and `uwp` flavors. Portable ZIPs and loose publish directories are not distributed or supported. Starting with `0.3.0`, the workflow builds six explicitly unsigned payloads on hosted runners, rejects any application EXE/DLL module with an embedded Authenticode certificate table, packages them into six unsigned MSIs, and revalidates every cabinet against the launcher's embedded payload manifest and a persistent validation document. There is no binary-signing or package-signing job.

Each MSI is published with a separate SPDX SBOM, `*.msi.validation.json` payload inventory, and SHA-256 sidecars for all three assets. GitHub artifact-provenance attestations cover the MSI, validation document, and SBOM. These metadata files are external release evidence and are not added to the installed runtime. Release publication revalidates the authorized annotated tag and every checksum immediately before upload and after publication. An interrupted matching draft is resumed only when its tag, target, title, exact asset inventory, sizes, and digests remain consistent; mismatched, duplicate, or unexpected remote state is rejected. GitHub immutable releases must be enabled before publication, and a published matching immutable release is accepted only after every asset is independently verified with a patched GitHub CLI. Enabling the repository setting does not retroactively make historical releases immutable, so treat older releases as legacy evidence. No PFX, code-signing certificate, Azure signing identity, or signing-related environment variable is required.

The MSI ProductCode is deterministic for version, architecture, and flavor, while all packages share one UpgradeCode. Reinstalling the identical version/architecture/flavor enters Windows Installer maintenance/repair. A same-version flavor or architecture transition is handled as a major upgrade rather than a side-by-side install; this support is for an explicit transition, not for replacing an already-published package with different bytes. Downgrades are blocked. Close WireSock UI and disable autorun for affected accounts before changing architecture, because x86 and native 64-bit packages use different Program Files roots and per-user scheduled tasks are path-bound.

The interactive MSI lets users independently select all-users Start-menu and desktop shortcuts; both are selected by default, their feature states migrate across upgrades, and maintenance mode can change them later. Uninstall removes only MSI-owned runtime files, installer registry data, and whichever of those shortcuts were installed. It does not enumerate or delete other users' scheduled tasks or notification state, and it preserves application-created profiles, protected preferences, recovery data, and logs under `%ProgramData%`. Disable per-user autorun before uninstalling; remove retained user data separately only when it is no longer needed. Unknown files placed in the installation directory are not recursively deleted.

The `release-publish` environment must require independent reviewers, prevent self-review, disable administrator bypass, and allow exactly the custom tag policy `release-v*.*.*`. The release preflight also requires organization ownership and enabled immutable releases. Configure repository Actions policy to require full-SHA action pinning, remove the retired Azure signing actions from the allowlist, limit allowed actions to the audited set, and protect `main` with required status checks, stale-review dismissal, approval of the latest push, signed commits, resolved conversations, and administrator enforcement. The required checks must include the dependency audit, SDK contract, all six managed architecture/flavor test variants, all six publish checks, all three native-host smoke variants, all three architecture-matched MSI install smoke variants, architecture isolation, and transition smoke, bound to the GitHub Actions App rather than accepting same-named third-party statuses. Repository rules must restrict creation, update, and deletion of the active `release-v*.*.*` namespace and the retired `v*` namespace.

Install a dedicated GitHub App on this repository with only repository Administration (read) and Actions (read) permissions so the workflow can inspect immutable-release, environment, Actions, and OIDC policy. Store `RELEASE_POLICY_READER_CLIENT_ID` as an environment variable and `RELEASE_POLICY_READER_PRIVATE_KEY` as an environment secret only in `release-publish`. The protected publication job exchanges them for a short-lived, repository-scoped token; the normal `GITHUB_TOKEN` cannot read all required settings and is not used for this check.

As a mandatory external repository control, every organization or repository ruleset contributing to `main` or to tag update/deletion restrictions must have an empty bypass-actor list. Put active `release-v*.*.*` creation in a separate creation-only ruleset whose bypass list contains only a narrowly scoped, audited release-tagger user, team, or App; never grant broad roles, administrators, or deploy keys this bypass. Keep update and deletion in separate zero-bypass ruleset layers so even the release tagger cannot move or delete a created tag. The retired `v*` namespace must have zero-bypass update/deletion rules and should retain a zero-bypass creation rule to keep it permanently retired. The read-only checker verifies effective rules for the exact active and corresponding legacy tag, requires the active creation ruleset IDs to be disjoint from mutation ruleset IDs, and probes a representative retired tag, but the full wildcard coverage remains an independently audited configuration requirement. GitHub withholds bypass actors from an Administration (read) token, so the checker cannot enumerate their contents. Do not grant the policy-reader App Administration (write) merely to inspect them, because that would turn a read-only release gate into a repository-takeover credential. Classic branch-protection PR bypass allowances are visible to the read-only checker and must remain empty.

Release tags remain signed annotated Git metadata in strict `release-vMAJOR.MINOR.PATCH` form, resolve directly to the current protected `main` tip, and have a GitHub-verified cryptographic signature. This tag signature authorizes the source revision; it does not sign any binary or MSI. Create tags with `git tag -s release-vMAJOR.MINOR.PATCH`; lightweight, unsigned, stale-main, moved, or legacy `v*` tags are rejected. The workflow binds the tag object's internal name and exact object ID during authorization, then revalidates both immediately before publication and after publication. Rotate or delete legacy release PAT/PFX and Azure signing secrets (including `MY_GITHUB_PAT` and all `AZURE_ARTIFACT_SIGNING_*` values). Publication uses only the repository `GITHUB_TOKEN`. Until the organization runner group, protected publication environment, repository rules, OIDC claim template, exact reusable-workflow pins, and immutable-release setting are configured, integration and release execution is intentionally unavailable rather than silently weakening these controls.

## Remaining Runtime Risks

- The ABI contract job does not prove that the installed driver and SDK DLL work together. Keep release-gated real-SDK x86-workload and x64-workload pools on representative x64 hosts and the ARM64-workload pool on representative ARM64 hosts.
- Tunnel start/stop still depends on driver state and Windows networking permissions after elevation succeeds.
- The global `WiresockClientService` event is an SDK compatibility primitive shared with the direct C++ CLI. WireSockUI rejects unexpected owners and broad ACLs, but changing to a private authenticated namespace requires a coordinated SDK change.
- The direct SDK API still requires the managed tunnel coordinator to run elevated. The native launcher prevents mutable pre-CLR startup and untrusted shell activation, while lifecycle, profile, autorun, and UI responsibilities are isolated behind bounded coordinators; a fully medium-integrity UI would require an authenticated broker/service protocol and coordinated SDK ownership changes.
- The `WireSockUI.Tests` harness covers parser/profile validation, native error-sentinel handling, lifecycle cleanup and bounded monitoring through a deterministic native facade, ACL checks, architecture matching, transactional profile renames, reparse-point rejection, and STA construction/disposal of classic and UWP dialogs. Real driver and `wgbooster.dll` validation remains environment-specific and is handled by the SDK Integration workflow.

</details>

## License

This project is licensed under the [MIT License](LICENSE).
