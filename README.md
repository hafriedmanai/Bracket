# March Madness Bracket Pool for Salesforce

A Salesforce DX project for running a college basketball bracket pool inside Salesforce.
Players fill out a 64-team bracket by **tapping a team to advance it**. The commissioner
taps the real winners as games finish, and every bracket is re-scored on a live leaderboard.

## Features

- **Tap to advance.** Tap a team and it moves into the next round. Tap it again to undo.
  If you change an earlier pick, any later picks that depended on the old team are cleared.
- **Phone-friendly.** Each region is its own tab (East / West / South / Midwest / Final Four),
  with 40px+ tap targets and sideways scrolling between rounds. The app runs in the Salesforce mobile app.
- **Fill Favorites.** Fills every empty game with the better seed, so players can start from
  chalk and only pick the upsets.
- **Lock time.** Picks lock at the tournament's *Picks Lock At* date/time (or when Status is
  no longer *Open*). The lock is checked on the server, not just in the UI.
- **Commissioner Results mode.** The same component, set to Results mode, records official
  winners. Saving re-scores every entry.
- **Leaderboard.** Ranks entries by score, then by the closest championship-total tiebreaker,
  then by max possible points. Shows each player's champion pick, crossed out once that team is eliminated. Other players'
  brackets can be opened once picks lock.
- **Graded picks.** After results come in, picks show green (correct), red (wrong or the team
  is already out), and the real winner is shown under any wrong pick.
- **Configurable scoring.** Default is 10 / 20 / 40 / 80 / 160 / 320 per round (1,920 max).
  You can change it per tournament.

## What's in the project

| Path | What it is |
| --- | --- |
| `objects/Tournament__c` | Tournament: lock time, status, region order, points per round, results (JSON), championship total |
| `objects/Team__c` | Team: seed (1-16) and region. Detail of Tournament |
| `objects/Bracket_Entry__c` | One per player: picks (JSON), tiebreaker, champion, score, max possible |
| `classes/BracketController` | `@AuraEnabled` API: load bracket, save picks, save results, leaderboard |
| `classes/BracketScoringService` | Bracket structure, server-side validation of picks, scoring |
| `classes/BracketControllerTest` | Apex tests |
| `lwc/marchMadnessBracket` | Main bracket UI (App, Home, Record page and Tab targets) |
| `lwc/bracketGame` | One game card with two tappable teams |
| `lwc/bracketLeaderboard` | Leaderboard |
| `lwc/bracketLogic` | Bracket logic shared by the components (advancing, clearing later picks, scoring) |
| `permissionsets/` | **Bracket Player** and **Bracket Commissioner** |
| `applications/March_Madness` | Lightning app with *Bracket Pool* and *Enter Results* tabs |
| `scripts/apex/seedTournament.apex` | Sample tournament with 64 teams |

## Deploy

```bash
# Install the Salesforce CLI: https://developer.salesforce.com/tools/salesforcecli
sf org login web --alias bracket            # or create a scratch org:
# sf org create scratch --definition-file config/project-scratch-def.json --alias bracket --set-default

sf project deploy start --target-org bracket
sf org assign permset --name Bracket_Commissioner --target-org bracket   # you, the commissioner
sf apex run --file scripts/apex/seedTournament.apex --target-org bracket # optional sample data
sf apex run test --class-names BracketControllerTest --result-format human --target-org bracket
```

Give everyone in the pool the **Bracket Player** permission set. Then open the **March Madness** app.

## Running a pool

1. **Create a Tournament.** Set *Picks Lock At* to the tip-off of the first Round of 64 game. Keep
   *Region Order* in Final Four pairing order: region 1 plays region 2 and region 3 plays region 4.
   Bracket pairings change every year, so check them on Selection Sunday.
2. **Load 64 Teams** with Seed and Region. Use a Data Import Wizard CSV with the columns
   `Name, Seed__c, Region__c, Tournament__c`, or edit the sample script.
   *First Four:* enter one placeholder per play-in slot (for example `Texas / Xavier`). Rename it to the
   winner after the play-in game. Picks follow the record, so renaming doesn't change anyone's picks.
3. **Players fill out brackets** on the *Bracket Pool* tab and tap **Save Bracket**. They can save
   partial brackets and come back to finish before the lock.
4. **Enter results** on the *Enter Results* tab as games finish. After the title game, enter the
   combined final score so the tiebreaker can be applied.

## How picks are stored

Every game has a stable id:

- `R{region}-{round}-{slot}` for rounds 1-4 inside a region (region is the 0-based position in
  *Region Order*). For example, `R0-1-0` is the 1 vs 16 game in the first region.
- `FF-5-0` and `FF-5-1` for the Final Four, and `FF-6-0` for the championship.

Picks and results are JSON maps of game id → Team Id. The server checks that every saved pick
is a team that could actually be in that game and won its previous game. This means a bracket
can't be tampered with by editing the record directly. Players only get read access to the
objects, and all writes go through Apex.

## Tests

```bash
npm install
npm test          # LWC Jest tests (bracket logic + tap interactions)
```
