# Dungeon Quest Rewrite · Obsidian

Three account roles built on the latest pathfinding farm from
[Dungeon-quest](https://github.com/glitchreal/Dungeon-quest), including its newer
stairs, recovery, target-facing, and bounded dodge fixes. The old movement spoof,
raid, webhook, and miscellaneous feature panels have been removed.

```lua
getgenv().autoexecute = true
getgenv().autoloadconfig = true
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/dungeonquestrewrite/main/main.luau"))()
```

Run this on **every account**, initially in a lobby. In **Party**, enter the same
host username, carry username, and selected alt usernames on all accounts.
Paste the whole alt list using newlines, spaces, tabs, commas, or semicolons, then
press Enter or click away. The field formats it with commas and removes duplicate entries.
User IDs also work; display names do not. Select each account's
role, choose its options, then use **Enable role automation** at the top of Party
or **Start selected role** at the top of Roles. Dungeon creation requires the
**Host** role; Carry and Alt send join requests instead. Party fields save as
you type, and the visible text is captured again before reload/unload/teleport.
Role automation pauses while you edit the party to avoid using partial usernames.
Click away to resume; Enter is optional. The host and carry must
be different accounts. The host and selected alts should begin at the same level;
the carry can be much higher level.

Automation, auto sell, auto healer, auto skill points, and OCD recovery start
disabled. Feature switches such as auto join and Level Kaitun are preset, but
perform no actions until **Enable role automation** is on. Auto Sell is independent:
turning on its own toggle runs it even with role automation off or no party configured.

| Role | Behavior |
| --- | --- |
| Carry | Sends requests to the host. Level Kaitun waits for the entire selected party, starts the dungeon, then uses the existing pathfinding combat farm. Pauses whenever a selected account is absent or its level is unavailable. |
| Host | Creates and enters the best eligible dungeon, accepts requests only from the resolved selected accounts, and replays. Starts once everyone is present; keep Level Kaitun on for the host too, so owner-restricted starts work. |
| Alt | Sends requests to the host. Optional healer equips the highest-level eligible tank helmet/chest and up to two Universal Heals, removes other equipped skills, and casts only Universal Heal when a selected member needs health. Optional skill points go to Stamina, Spell Power, or Physical Power. |

The carry alone runs the enemy pathfinding farm. Host and alt accounts wait for
the carry; healer alts cast without approaching enemies. All roles support auto
sell, OCD recovery, UI hiding, CPU saver, automatic settings, and teleport continuation.

## Progression and party recovery

- Best dungeon means the highest real level requirement available, with difficulty
  used to break ties. Requirements come from the game's lobby catalog, including
  later content; special event and boss-key dungeons are excluded.
- Hardcore and private/whitelist lobby mode are optional host settings. Automatic
  request acceptance **always** checks the selected party, even in a public lobby.
  The host scans existing request prompts once per second as well as listening for
  new requests, so requests received before the script loaded are recovered.
  Unresolved prompts are retried at most once every five seconds.
- Before starting, every selected account must be present in the same dungeon.
  Readable matching non-carry levels are required for progression, not starting. The configurable party-ready delay gives arrivals time to settle.
- At the end of a run, switching waits five seconds for rewards, verifies the host's
  current level, and requires every selected non-carry account to match it. The host
  returns to create the new dungeon; carry/alt accounts return and request the host
  again. Enable Auto Best on the host and Auto Switch on the carry/alts.
- Starting and recovery do not depend on dungeon-owner metadata. Host role
  controls join-request handling; the game enforces owner-only actions.
- A host disappearing is **not** treated as a level unlock. With OCD disabled, the
  carry pauses and waits. Initial party assembly has no timeout. With OCD enabled
  on every account, a player missing from a previously assembled party (or an
  already-started run) for the grace period triggers lobby recovery. Requests and teleports are retried at bounded intervals.
- Recovery remembers observed alt levels and caps the host's new selection at the
  lowest known non-carry level so a disconnected alt is not locked out. The party
  replays while levels differ. It cannot undo XP earned before a disconnect or
  guarantee identical XP/levels when account XP boosts differ.

## Optional cross-client sync

A small HTTPS relay lets separate devices report that their **scripts** are running,
not just that their players are present. In Party → Cross-client sync, enter the same
relay URL and private key on every selected account and enable the toggle on each.
An optional private setup loader can set `getgenv().DQRewriteSync = { URL = "https://YOUR-RELAY.workers.dev", Key = "YOUR-PRIVATE-KEY" }`
before running the regular main loader. These values save per account and continue
through teleports. Never commit or publicly share the real key or setup loader.

- Every account sends a heartbeat every 10 seconds. Starting, replaying, farming,
  and automatic healing require fresh enabled/ready reports from the entire party
  in the **same dungeon job**. The start delay resets when readiness is lost.
- If the relay stops responding, clients pause these actions instead of assuming
  other scripts are ready. The UI lists missing, paused, or different-server accounts.
- The host publishes a regroup message before its automated lobby return and waits
  for relay acknowledgment. Carry and alts in the old job follow that message, even
  if their own catalog is missing or they missed the host leaving. Level eligibility
  and reward checks still govern host progression. With sync enabled, followers use
  the host's progression decision instead of independently switching dungeons.
- Regroup messages expire after three minutes and target only the old job. Ordinary
  missing-player OCD recovery still works independently on carry/alt clients.
- Disabling sync restores the presence-only behavior. The manual Return to lobby
  button remains an individual action. Sync cannot inject or execute a script on
  another account: run the loader on each account and keep teleport execution enabled.
- Executors need an HTTPS `request`, `http_request`, or `syn.request` API. Settings
  files and the private key remain local; the relay only receives party IDs, server
  IDs, place, enabled/readiness flags, and regroup reasons. Party members sharing a
  key are trusted: this is a private coordination service, not Roblox identity proof.

The deployable Cloudflare Worker is in [`src/relay`](src/relay/README.md). It uses a
SQLite-backed Durable Object supported by the Workers Free plan. Ten continuously
running accounts at the default interval use about 86,400 requests/day, before
restarts and other traffic; the Free plan allowance is 100,000/day. Stay on Free:
exceeding its quota stops requests rather than automatically buying extra capacity.

## Healer provisioning and selling

Enable **Farm Pirate Island for Universal Heal** on every account to coordinate
provisioning. The host uses Pirate Island until the host and every selected alt
each own at least **two Universal Heals**. The carry is excluded from heal ownership
checks. Old one-heal readiness flags are discarded and inventories are checked again. Below Pirate Island's level-60
requirement, it farms eligible content first. It selects the highest eligible
Pirate difficulty. The party returns to best-dungeon progression after ownership
is confirmed and non-carry levels match. A failed inventory inspection does not
establish ownership. New drops are checked again after rewards settle.

Alt Auto Healer chooses tank/guardian armor by eligible **level first**, then
health. A tank class/name or health-only armor stats identify tank gear. It equips
two distinct heals when available; one is usable while waiting for another drop.
Heal casting uses the game's equipped-slot event and cooldown path. The existing
Auto Healer toggle alternates ready Q/E heals with at least four seconds between
casts, while still waiting for each skill's real cooldown and a party member to
need healing. One owned heal also respects its cooldown; no extra toggle is needed.

Under Settings → All account types, **Keep items** accepts full item names
separated by commas, semicolons, or pasted lines, for example
`Enhanced Inner Focus, Enhanced Inner Rage`. Matching ignores capitalization and
extra spaces but requires the entire name; every matching copy is protected.
Editing the list stops Auto Sell so partially typed names cannot cause a sale.
Re-enable Auto Sell when finished. The list saves automatically in the same
per-account config, including across teleports.

**Keep legendary items** is enabled by default and saves per account. It excludes
all legendary weapons, helmets, chests, and abilities from selling. Turn it off
to include legendary items, subject to the other keep rules.

Auto Sell covers every rarity for weapons, helmets, chests, and abilities. It
retains up to two Universal Heals, including when only one exists, and preserves
equipped, locked, and favorite items plus pending healer equipment. Gear is
refreshed after equipping before a sale is computed. Trading pauses inventory
mutations. All equipped ability slots, including Q2/E2, are protected; unknown
equipped status is also kept. The sale readout distinguishes requests from items
confirmed removed by the next inventory scan. Auto Sell is intentionally opt-in
on each account and requires neither party setup nor dungeon catalog loading.

## Settings and execution

Settings use shared **Carry**, **Host**, and **Alt** profiles. On execution, the
script matches the current Roblox username or UserId against the shared Host,
Carry, and Selected alts fields, then loads that role's saved settings. All listed
alts load the Alt profile. Unlisted accounts retain their own saved settings
until configured. Reload an account after changing the shared party/profile.

Files in the executor workspace:

- `DungeonQuestRewrite-party.json`: shared Host, Carry, and Selected alts.
- `DungeonQuestRewrite-role-Carry.json`, `-Host.json`, `-Alt.json`: settings per role.
- `DungeonQuestRewrite-<userId>.json`: account fallback and runtime observations.

Role profiles publish on user edits. Periodic saves and teleports update only the
account file, so idle accounts do not overwrite shared settings. An in-memory
teleport snapshot takes precedence over shared profiles on arrival. An existing
account config seeds a missing role profile when its party identifies that account.
Party text saves while typing and is captured again before unload/teleport.
Role automation pauses during party edits to avoid using unfinished usernames.
Accounts must share the executor's file workspace to share profiles; the same HWID
alone does not make separate executor folders share files. `autoloadconfig = false`
starts with defaults and skips shared profiles too.

Right Shift toggles the Obsidian menu; the key is configurable. Hide UI applies
on execution. CPU saver disables 3D rendering, caps FPS at 30, and reduces visual
effects without changing game speed or the combat controller's dodge limits.
Disabling it or unloading restores the changed properties.

`autoexecute = true` queues the **main loader** after teleports so the destination
loads the right bundle. This requires `queue_on_teleport` or a supported alias.
Without it, rerun the loader after teleporting. Saving requires executor file APIs.
Unsupported places exit without running automation.

| Place | Place ID | Bundle |
| --- | --- | --- |
| Lobby | `77649408247578` | `dist/lobby.luau` |
| Level 100+ lobby | `115445507767090` | `dist/lobby.luau` |
| Dungeon | `85776757589518` | `dist/dungeon.luau` |

## Development

`src/HubLogic.luau` contains pure eligibility, roster, equipment, and sale policy.
`src/GameAdapter.luau` owns inspected game interfaces. `src/RoleController.luau`
coordinates the three roles. `src/ObsidianHub.luau` owns UI, lifecycle, settings,
and performance. Combat, ability scheduling, farm planning, and threat geometry
remain separate modules.

After runtime edits, run `lua build.lua` from this repository and commit both
generated bundles. Do not add a pre-commit test gate or rerun tests only to commit.
The Obsidian library remains pinned to its original revision.

Validation for this rewrite includes Luau compilation, focused policy/state
checks, live lobby UI loading, and inspection of both lobby and dungeon remotes.
A single connected client cannot validate a full carry/host/alt run, cross-account
reconnection, or actual multi-account drops; those remain live integration checks.
