Below are a list of things that needed to be completed. If they are checked, that means they were addressed.
1. Add the anti nuke (Prevailer) with stats copied from BAR. Anti nuke homes onto the nuclear missile and can block any nuclear missile within its range.
- Not verified yet

2. Bombers (whirlwind) need to be able to fire in bursts before reloading.
- Verification: Still needs work

3. Mammoth is currently unstoppable when rushed. Implement impulse.
- Not verified yet

4. Allow T2 mex blueprints to be built on top of T1 mexes - an upgrading mechanism. When the upgrade blueprint finishes, the original is simultaneously refunded.
- Verification: Fixed

5. Scavengers should spawn in sea less often, and cannot be the initial spawn, otherwise it poses no threat to the player.
- Not verified yet

6. Units should be able to have more than one weapon
- Implementation in codebase is not permissive enough.

7. AA Missiles should be able to home on its target, not just lead 
- Verification: Missiles do not home visually, but missiles are hitting.

8. Fix bomber, fighter bombing own units when in swarms

9. Add a new mode called guard which 
- Verified as complete

10. Mex snapping only ignores mexes that are already queued **by the same builder,** other builders are fine.
- Verified as incomplete

11. Reclaim waypoints should render at the position of the entity being reclaimed
- Verified as incomplete

12. Unit target selection happens according to priority. Each unit has a power score, the same as the difficulty score: metal cost + 60 * energy. The reward score is power / max health. A low health glass cannon will get very high priority compared to a say a wall that costs nothing but has high health. It should target units that are closest to dying.
- Verified as complete

13. Syracusia (and presumably other sea units) are able to climb to land
- Not verified yet

14. Units being transported should be excluded by selection box
- Verified as fixed

15. Idle construction turrets should reclaim nearby wrecks in addition to repairing.
- Verified as fixed

16. Beam laser attacks should be able to damage wrecks
- Verified as still broken
- Now aoe attacks also do not damage wrecks, regression

17. Wrecks should display their health bars
- Verified as fixed

18. Stockpile should drain resources to fill progress, not wait until progress reaches 100%, then try to consume all the metal and energy at once.
- Verified as fixed

---
future todos. ignore this for now
1. Don't drop orders for transported units, just ignore them.
2. Unloading also needs to get close to the ground first.
3. Priority should also take into account how much damage the unit is expected to do. Something that does 15% damage (to air) should be valued 15% of the usual score.
4. Dgun indicator should begin at where the commander is expected to be at the end of the waypoints (if shift is held).
5. Dgun no longer works on allied units. Intended behavior is dgun works unconditionally, as does BAR. Regression.
6. Disable aircraft colliders (behavior copied from BAR).
7. Missiles are purple neon lines (behavior copied from BAR) with thickness varying based on the unit (heavier aa units will look thicker).
8. Advanced energy storage, advanced metal storage, Screamer (long range aa missile)

---
more todos
Nuclear silo is manual fire (scavenger nukes will need to set attack commands)
