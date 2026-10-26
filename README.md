# Last Bell: Courtyard Siege

Co-op zombie survival on a school campus (Roblox). Scavenge by day, barricade and craft, survive escalating night waves, reach the Rooftop Helipad at Wave 10.

## Layout

- `src/` – all first-party Luau code, synced with [Rojo](https://rojo.space)
  - `ReplicatedStorage/Client` – controllers (HUD, inventory, lighting, music, sound), client components
  - `ReplicatedStorage/Shared` – network definitions, enums, configs (`MobConfig`, lighting profiles), utils
  - `ServerScriptService/Server` – services (Barricade, Siege, Supply, Session, Mob, Data, Inventory, Currency, Player, Sync)
  - `ServerScriptService/Bootstrapper`, `StarterPlayer/StarterPlayerScripts/Bootstrapper` – startup scripts
- `place/School_Survival_Game_Concept.rbxl` – the full place (map, props, lighting, sounds, prompts). The map lives here, not in `src/`.
- `wally.toml` – third-party packages (installed into `Packages/`, git-ignored)

## Setup

```bash
aftman install
wally install
rojo serve
```

Open `place/School_Survival_Game_Concept.rbxl` in Studio, connect the Rojo plugin. `default.project.json` ignores unknown instances, so syncing will not delete the map.

## Gameplay

Day phase: scavenge Cafeteria, Gym, Science Lab, Admin Office/Library. Night phase: horde waves, barricade and repair. Enemies: Walkers, Runners, Bloater Staff, Teacher Brute. Win: reach the Helipad at Wave 10 with Radio Parts and Fuel.

## Notes

- Scripts were extracted from the place file; edit in `src/`, and treat the `.rbxl` as the source for Workspace content only.

## Repo

https://github.com/Leck0000/last-bell-courtyard-siege
