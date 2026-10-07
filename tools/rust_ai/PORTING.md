# Porting BARb to the Rust AI

What the Rust AI takes from BARb, where it is in BARb's source, and where it is here. BARb is CircuitAI's `barbarian`
branch (https://github.com/rlcevg/CircuitAI/tree/barbarian, `src/circuit/...`, referred to below by file) played by
BAR's `luarules/configs/BARb/stable` hard profile (`script/hard/*.as` and `config/hard/*.json`). BAR's scripts call
the C++ defaults almost everywhere (`aiBuilderMgr.DefaultMakeTask`, `aiFactoryMgr.DefaultMakeTask`,
`aiMilitaryMgr.DefaultMakeTask`, `aiMilitaryMgr.DefaultMakeDefence`), so the C++ is what decides; the scripts add
the openers (`misc/commander.as`), two base "energizer" builders (`manager/builder.as`), the economy flags
(`manager/economy.as`) and when defences may start (`manager/military.as`).

Units: BARb works in elmos and frames; here 11 elmos are a stud and 30 frames a second. BARb's `build_speed` is a
unit's workertime over 20.

## Economy and builders

### The task pool (`module/BuilderManager.cpp`, `task/builder/*.cpp`)

BARb does not give builders orders directly. The economy manager (and the military manager, for defences) put
*tasks* into a pool, by type (factory, nano, store, energy, defence, mex, mexup, convert, reclaim, repair, guard...),
each with a priority (LOW 0, NORMAL 1, HIGH 2, NOW 3), a position, a def to build, and a cost. A builder that wants
work (`DefaultMakeTask`) first asks the economy manager to top the pool up (`MakeEconomyTasks`), then takes, of all
the tasks it may be assigned (`IBuilderTask::CanAssignTo`), the one with the least

    metric = path_cost(builder -> task) * 1 / (priority + 1)^2

where the path cost is the threat-weighted cost map from the builder (`CPathFinder::CreateCostMapQuery` over the
threat map) and a task that is under threat (`checkThreat`: threat at the site over the builder's own power, and the
influence there negative) is skipped unless it is NOW. A task with a target (a blueprint already started) is taken
only if walking there is worth it: `(maxHealth - health) * 0.6 * speed > healthSpeed * distCost`.

- `CanAssignTo`: the builder can build it, and the task has not got enough buildpower yet:
  `cost.metal >= buildPower.metal * build_mod / metal_income` (the task's buildpower is the sum of each assignee's
  `cost.metal / (buildtime / workertime)`, `ShowAssignee`); energy tasks aside, not while energy stalls unless there is
  enough energy for it (`IsEnoughEnergy`).
- Metal stalling (`MakeBuilderTask`): when metal is empty and the pull is over 1.2 times the income and the
  builders' metal pull is over `ms_pull` times the factories', builders take only NOW tasks, extractors, and energy
  while energy stalls (`IsIgnoreStallingPull`). This is how BARb shares metal between builders and labs.
- Nothing to do: `CreateBuilderTask` -> energy (`UpdateEnergyTasks`), reclaim (`UpdateReclaimTasks`), then guard the
  nearest factory for 60 s (`TaskB::Guard`).
- The commander (`MakeCommTask`, `commander.json` `hide`): before `hide.time` (240 s for corcom, 420 s for armcom) or
  while there are 2 builders or fewer, it takes tasks within `task_rad[0]` (2000 elmos) of base, with weights (energy
  `baseDivEnemy * energyDivMetal * 8`, mex `baseDivEnemy * metalDivEnergy`, defence...); in danger (enemy influence at
  it over `hide.threat`, or enemy aircraft) only within `task_rad[1]` (800). `assist_fac` 3: it assists its factory at
  high priority until there are 3 constructors (`CheckMobileAssistRequired`).
- Energizers (`manager/builder.as`): the first cheap constructor and the first expensive one get the BASE attribute
  and take tasks by `MakeEnergizerTask`: energy, store, factory, nano first (anywhere within 10000 elmos), then the
  rest within 2000 of base.

### What the economy manager puts in the pool (`module/EconomyManager.cpp`)

- `UpdateMetalTasks` (every builder request): if energy stalls, energy instead. Otherwise an extractor upgrade
  (`numMexUp` = economy.json `mex_up`, once income is over 10), else an extractor on the nearest open spot of the
  builder's cluster (`CMetalManager::GetSpotToBuild`) that is reachable safely (`CanReachAtSafe`), priority HIGH;
  converters when energy is full and metal is not (at most 2 tasks); else reclaim.
- `UpdateEnergyTasks`: the generators of `economy.json`'s `energy.land` in order of tech (`[limit_min, limit_max,
  metal_income, energy_income, score]`), the first whose count is under its limit and whose metal and energy income
  conditions are met (metal income times the time-varying energy factor), wind only if the wind makes it worth it.
- `UpdateFactoryTasks` (every second): a construction turret (NANO) by a factory that needs one
  (`CFactoryManager::NeedUpgrade`), else a new factory when there is the metal and energy for it (`newFacMod`).
- `UpdateStorageTasks` (every second): metal storage when metal is full, energy storage when energy storage is under
  5 seconds of income and energy is not empty.
- Economy flags (`script/hard/manager/economy.as`): metal empty under 20% of storage, full over 99%; energy
  stalling (first 3 minutes: pull over income and under 30%; after: under 20%, or pull over income and under 60%),
  full over 88%; factories want assistance when metal is over 20% and energy is not stalling.

### Build chains (`IBuilderTask::ExecuteChain`, `config/hard/build_chain.json`)

When a building of a listed def is finished, follow-up tasks go in the pool: a defence by a factory (`corllt` at
NOW, and for corlab a `corvipe` at LOW), nano turrets and anti-air by fusions, defences by advanced solars (by chance),
and porcupine defences by extractors (`isPorc` -> `MakeDefence`).

### Metal clusters and defence points (`resource/MetalManager.cpp`, `resource/MetalData.cpp`, `setup/DefenceData.cpp`)

Metal spots are clustered hierarchically (`economy.json` `cluster_range`, 1500 elmos); clusters that are near each
other are joined in a graph. A builder's extractor is the nearest open spot of the nearest cluster, by the graph,
over clusters the threat map leaves safe (`GetSpotToBuild`). Each cluster has defence points: its spots clustered
again within `porcupine.point_range` (600 elmos).

### Porcupine (`CMilitaryManager::DefaultMakeDefence`, `config/hard/build_chain.json` `porcupine`)

Every finished extractor, and every 5 seconds each cluster in turn (`UpdateDefenceTasks`), calls `MakeDefence`, which
only acts once BAR's script allows (after 5 minutes, or 10 metal income, or once the enemy has a mobile army). At the
cluster's nearest defence point whose built defence costs under `amountFactor * metal_income` (amountFactor from the
map's size, `porcupine.amount`), it queues defenders from the land list (`porcupine.land`: llt, hllt, maw, madsam,
hlt, viper, flak, doom) in order, each only while the total stays under that budget and past what is already there:
one (`prevent`) for an ordinary cluster, the whole list for a "porc" cluster (far from base and richer than most, or
next to two threatened clusters, or where the influence is not its own). Anti-air ones only once the enemy has air.
The first factory also queues the base defences of `porcupine.base` on a timetable (`MakeBaseDefence`).

## Factories (`module/FactoryManager.cpp`, `unit/FactoryData.cpp`, `script/hard/manager/factory.as`)

- Each factory makes one unit at a time (`CreateFactoryTask`): a constructor while buildpower is under
  `metal_income * bp_ratio` (half the time while the factory is busy), else wait 3 s if metal is stalling and the
  factories' pull outweighs the builders' (`ms_pull`), else a fighter by `RequiredFireDef`: BARb's roulette of
  `RoleProbability * (tier_weight + response._weight_)`, response batches of `num_batch`, the air table while enemy
  air outweighs its anti-air.
- A new factory's opener (`misc/commander.as`): one of the weighted queues for its BAR factory.
- Which factory to build next (`CFactoryData::GetFactoryToBuild`): fewest built first, then
  `importance * (map_percent + speed_percent)` plus noise, `importance` from `factory.json` (`[start, switch]`).
  A new one goes up when metal and energy income cover it (`UpdateFactoryTasks`) and the script's switch time has
  come (`AiIsSwitchTime`: `(frames since last switch)^0.9 * income + metal * 7` over 8000 to 12000 seconds).
- Construction turrets (`NeedUpgrade`): a factory has fewer than `factories * caretaker` of them.
- A construction turret (`CreateAssistTask`) helps the cheapest-to-finish blueprint in reach (mobile ones first),
  else repairs, else reclaims when metal is empty.

## The army (`module/MilitaryManager.cpp`, `task/fighter/*.cpp`, `task/RetreatTask.cpp`)

- A new fighter's task by its main role (`DefaultMakeTask`): scout -> SCOUT (up to `quota.scout`); raider -> an
  escort GUARD task if one wants it, else a DEFEND task that is promoted to RAID at `quota.raid[0]` power; riot ->
  GUARD, else DEFEND promoted to ATTACK at `max(quota.attack, enemy pre-max group threat)`; artillery -> ARTY;
  anti-air -> AA; anti-heavy -> ATTACK once the enemy has heavies; bomber -> BOMB; the rest -> DEFEND promoted to
  ATTACK. Power is `kernel * sqrt(health)` summed over the squad (`IFighterTask::attackPower`).
- Squads (`ISquadTask`): the leader is the member with the least mobility; every 32 updates a squad merges into a
  stronger one of its kind it can reach safely; every 16 it regroups when members are further apart than
  `max(8 squares * members, highest range)`; attacking, its members stand on arcs round the target, a row per range
  (`Attack`).
- DEFEND (`CDefendTask`): stands at the front (the defence points of the owned cluster nearest the lane to the enemy),
  fights enemies inside its defended ground whose threat is under its power (4 times near base), and every 32 updates
  is promoted when its power reaches its target or a task of that kind exists (it joins it).
- ATTACK (`CAttackTask`): every 4 updates the target is the enemy group nearest by `vague_metric * distance^2 *
  scale` among those whose threat, times `thr_mod.attack`, it outpowers; engaged when within its range plus slack
  and with a line of fire, otherwise it follows a threat-weighted path there; with none, the front.
- RAID (`CRaidTask`, one def per raid, up to `quota.raid[1]` power): attacks the best target within reach (builders
  first, then the most threatening it outpowers), else paths to the nearest of the weak enemies anywhere, else scouts.
- GUARD (`CFGuardTask`): escorts the first `defence.escort[0]` constructors with `escort[1]` fighters each; until
  `escort[2]` seconds an unescorted constructor does not take extractors in undefended clusters.
- Retreat (`IFighterTask::OnUnitDamaged`, `CRetreatTask`): under the unit's retreat health (behaviour.json), or with
  no target in sight, or out of range with threat twice its power: go to the nearest factory with turrets, and a
  HIGH repair task goes in the builders' pool; back at 98% health.

## What the Rust AI adds, and where

Only at BARb's own decision points, each switchable (`params.rs`):
- the battle simulator: an ATTACK or RAID target BARb's rule allows must also be won in the simulator
  (`sim_gate`); a unit BARb would keep fighting retreats if the simulator says its fight is lost; and each fighter's
  roulette weight is multiplied by how a budget of it fares against the enemy's army (`counter_sim_weight`);
- fronts and desperation (`fronts.rs`): desperation scales the attack and raid `powerMod` and, past a point, promotes
  every DEFEND to an ATTACK on the enemy's commander.
