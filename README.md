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
role, choose its options, and enable **Auto start role automation on execute** in each
role profile for unattended execution. **Enable role automation** and **Start selected
role** still control the current session. Dungeon creation requires the
**Host** role; Carry and Alt join the Host queue, or send requests only to a Host confirmed in PRE_START. Party fields save as
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
| Carry | Joins the Host, waits for the actual dungeon start, and runs the local pathfinding farm when the selected party is present. Script heartbeats do not gate running combat. |
| Host | Creates and enters the best eligible dungeon, accepts requests only from the resolved selected accounts, and replays. Starts once everyone is present; keep Level Kaitun on for the host too, so owner-restricted starts work. |
| Alt | Sends requests to the host. Optional healer support matches the Host behavior below. |
| Host and Alt healer support | Equips the strongest eligible mage weapon, highest-level tank helmet/chest, and up to two Universal Heals, removes other equipped skills, and casts only Universal Heal when a selected member needs health. Optional skill points go to Stamina, Spell Power, or Physical Power. |

The carry alone runs the enemy pathfinding farm. Host and alt accounts wait for
the carry; healer hosts and alts cast without approaching enemies. All roles support auto
sell, OCD recovery, UI hiding, CPU saver, automatic settings, and teleport continuation.

## Progression and party recovery

- Best dungeon means the highest real level requirement available to the lowest
  selected host/alt level, with difficulty used to break ties. Live requirements
  come from the lobby catalog; built-in normal-dungeon requirements through
  Northern Lands keep progression working inside dungeons and repair old catalogs.
  Special event and boss-key dungeons are excluded.
- Hardcore and private/whitelist lobby mode are optional host settings. Automatic
  request acceptance **always** checks the selected party, even in a public lobby.
  The host scans existing request prompts once per second as well as listening for
  new requests, so requests received before the script loaded are recovered.
  Unresolved prompts are retried at most once every five seconds.
- Before starting, every selected account must be present in the same dungeon.
  Readable matching non-carry levels are required for progression, not starting. The configurable party-ready delay gives arrivals time to settle.
- The coordinator uses explicit LOBBY_REFORMING, ASSEMBLING, PRE_START, RUNNING,
  REWARDS_SETTLING, REPLAYING, PROGRESSION_RETURN, and RECOVERING phases.
- Completion is latched from the completion event, GUI, boss state, or progress.
  After five seconds for rewards (plus heal inspection when configured), **only
  the Host** chooses replay versus progression using the lowest Host/Alt level.
  Missing dungeon metadata does not count as an unlock. The same eligible dungeon
  replays with the party intact; there is no routine return or new join request.
- Replay uses the inspected ReplayDungeonButton payload and `replayDungeon` event.
  Three bounded attempts precede a controlled regroup if teleport never starts.
  Teleport-in-progress suppresses duplicate actions. Same-job reloads preserve
  pending transition attempts; new jobs discard the old transition context.
- A better eligible dungeon (or completed healer provisioning) causes one Host
  progression-return decision. Followers consume its command once. Return retries
  use bounded backoff; they do not stack a separate reward delay on each account.
- Host accepts selected requests only in PRE_START, before it has ever observed
  this job running, and while completion, failure, return, and teleport are absent.
  Completed/running Hosts reject stale requests even if the started flag falls.
- Followers request a dungeon Host only with fresh PRE_START sync evidence and a
  job different from their previous dungeon. Without that evidence, they use the
  game's local/global **lobby queue** interfaces. Host waits for selected queue
  members before entry, so presence-only coordination does not need blind requests
  into a potentially completed dungeon. Global discovery checks the expected map
  and rotates through the catalog when accounts have different cached selections.
- OCD arms only after the entire party, including level data, has been observed
  in the same stable phase. Initial arrivals have no timeout. A continuously missing
  member starts RecoveryGrace; reappearance resets it. Replay, return, teleport,
  and fresh lobby assembly suspend that timer. Carry pauses immediately on absence.
  Host announces recovery; Carry can take authority if Host is genuinely absent.
  Without transport, Host departure is the fallback signal; a 30-second teleport
  grace distinguishes a delayed replay from a return when no explicit decision
  can be read. Confirmed progression commands return immediately.
- Recovery retains observed non-carry levels as eligibility ceilings. It cannot
  undo earned XP or equalize accounts with different XP boosts.

## Optional cross-client sync

Three independent settings control execution:

- **Auto start role automation on execute**: saved in each Carry/Host/Alt profile.
- **Enable cross-client sync**: exchanges phases, heartbeats, and transitions.
- **Require selected scripts ready before start**: gates starting the dungeon,
  never Carry movement in an already-running dungeon.

`files.luau` enables file transport only. Shared executor files are checked first;
configured HTTP relay is a fallback. A missing heartbeat reports the account, and
an unproven shared workspace reports possible isolation/relay unavailability.
With script readiness disabled, unavailable transport uses presence-only policy.
With script readiness required, the Host waits and shows the missing evidence.
No setting executes scripts on other accounts; run the loader on each account.

Heartbeats write every 0.25 seconds. Relay requests run separately so HTTP latency
cannot stop file heartbeats. A transition has a unique ID, authority, source job,
place, dungeon context, phase, timestamp, and fixed 90-second expiry. Repeated
announcements do not extend it; old-job, wrong-authority, legacy, and expired
commands are ignored. Followers persist the consumed ID. Host normally owns
transitions; Carry recovery requires Host absence. Shared profiles/files require
an actually shared executor workspace, not just the same computer/HWID.

Optional relay configuration remains:
`getgenv().DQRewriteSync = { URL = "https://YOUR-RELAY.workers.dev", Key = "YOUR-PRIVATE-KEY" }`.
Do not publish a real relay key. The Cloudflare Worker and local server are in
[`src/relay`](src/relay/README.md). Existing deployments need the updated relay code
for phase/epoch coordination; outdated relays fall back to lobby/presence policy.
Run `npm run local` there for native desktop clients using `http://127.0.0.1:8788`
or an emulator's host address. Cloudflare uses the existing free-plan configuration.

## Boosts

**Auto buy boosts with gold** is opt-in and saved by role. The inspected game shop
currently offers x2 Gold, +1 Item (shown here as +1 Drop), and VIP through gold-only
interfaces; prices vary with level and are queried rather than hardcoded. Priority
is x2 Gold, +1 Drop, VIP, then XP 1h, 2h, 4h. Later XP tiers wait until earlier tiers
are exhausted/unavailable according to the server's current allowance/cooldown.
Saved offers are observations only; a local calendar date never authorizes buying.

Only one purchase can be requested per 15-second inspection cycle, followed by a
fresh ownership/allowance check. Gold affordability is checked first. Robux, gems,
and unknown currencies are never purchased automatically; status directs the user
to the game's shop for manual purchases. No premium prompt/confirmation is invoked.

## Healer provisioning and selling

Enable **Farm Pirate Island for Universal Heal** on every account to coordinate
provisioning. At level 60+, the host uses Pirate Island until the host and every selected alt
each own at least **two Universal Heals**. The carry is excluded from heal ownership
checks. Old one-heal readiness flags are discarded and inventories are checked again. Below Pirate Island's level-60
requirement, it farms eligible content first. It selects the highest eligible
Pirate difficulty. The party returns to best-dungeon progression after ownership
is confirmed and non-carry levels match. A failed inventory inspection does not
establish ownership. New drops are checked again after rewards settle.

Host and Alt Auto Healer equips the eligible weapon with the highest spell power, then
chooses tank/guardian armor by eligible **level first**, then health. A tank class/name or health-only armor stats identify tank gear. It equips
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
Re-enable Auto Sell when finished. The list saves automatically in the role profile and account continuation, including across teleports.

**Keep legendary items** is enabled by default and saves in the role profile. It excludes
all legendary weapons, helmets, chests, and abilities from selling. Turn it off
to include legendary items, subject to the other keep rules.

Auto Sell covers every rarity for weapons, helmets, chests, and abilities. It
retains up to two Universal Heals, including when only one exists, and preserves
equipped, locked, and favorite items plus pending healer equipment. Gear is
refreshed after equipping before a sale is computed. Trading pauses inventory
mutations. All equipped ability slots, including Q2/E2, are protected; unknown
equipped status is also kept. The sale readout distinguishes requests from items
confirmed removed by the next inventory scan. Auto Sell is intentionally opt-in
in each role profile and requires neither party setup nor dungeon catalog loading.

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
- `DungeonQuestRewrite-sync/<party-id>/<userId>.json`: per-account sync heartbeat.
- `DungeonQuestRewrite-sync/<party-id>/command.json`: short-lived host regroup command.

Role profiles publish on user edits. Periodic saves and teleports update only the
account file, so idle accounts do not overwrite shared settings. Shared role settings take precedence over stale account settings and teleport
snapshots. Runtime observations and the current session’s enabled state continue
through teleport; AutoStartRole also enables fresh execution. An existing
account config seeds a missing role profile when its party identifies that account.
Party text saves while typing and is captured again before unload/teleport.
Role automation pauses during party edits to avoid using unfinished usernames.
Accounts must share the executor's file workspace to share profiles; the same HWID
alone does not make separate executor folders share files. `autoloadconfig = false`
starts with defaults and skips shared profiles too.

From Ghastly Harbor through Northern Lands, navigation follows ordered room
checkpoints. Checkpoints require proximity on the same floor; a 60-stud height
gap no longer advances stairs prematurely. Streaming refreshes preserve visited
rooms and include newly replicated forward checkpoints. Brief role pauses retain
route progress. Empty/cleared rooms advance toward the next checkpoint.
Visible enemies outrank blocked targets for every adaptive strategy. A lightweight
watchdog tracks checkpoint/dungeon progress, target health, kills, and closing
distance; stalls invalidate inaccessible targets and recompute the route using
ordinary walking. Northern Lands policy is localized in the map table. No large
teleports or new movement controller were added; tactical dodge limits are intact.

Combat also includes an optional local adaptive policy, enabled by default under
Carry → Adaptive combat policy. It is a small contextual bandit, not a remote
black box: it learns whether visible, nearest, clustered, or finishing targets
and slightly closer/base/far combat spacing produce better health progress with
less incoming damage. It starts with the existing safe policy, updates only from
observed kills/health/damage, keeps a bounded model, and saves it in the account's
existing runtime config. No telemetry or network service is required. Disable the
toggle to return to the fixed baseline at any time.

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
coordinates the three roles. `src/BoostManager.luau` owns bounded purchase policy. `src/ObsidianHub.luau` owns UI, lifecycle, settings,
and performance. Combat, ability scheduling, farm planning, and threat geometry
remain separate modules.

After runtime edits, run `lua build.lua` from this repository and commit both
generated bundles. Do not add a pre-commit test gate or rerun tests only to commit.
The Obsidian library remains pinned to its original revision.

Validation for this rewrite includes Luau compilation, focused policy/state
checks, live lobby UI loading, and inspection of both lobby and dungeon remotes.
A single connected client cannot validate a full carry/host/alt run, cross-account
reconnection, or actual multi-account drops; those remain live integration checks.
