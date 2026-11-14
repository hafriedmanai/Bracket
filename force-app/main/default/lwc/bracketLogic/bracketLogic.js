/**
 * Pure bracket logic shared by the bracket UI components.
 *
 * Game ids:
 *   Rounds 1-4 (inside a region): "R{regionIdx}-{round}-{slot}"   e.g. "R0-1-3"
 *   Final Four (round 5):         "FF-5-0", "FF-5-1"
 *   Championship (round 6):       "FF-6-0"
 *
 * A "winners" object maps game id -> Team Id. The same shape is used for a
 * user's picks and for the official results. The Apex class BracketScoringService
 * mirrors this logic on the server.
 */

// Standard NCAA seed ordering for Round of 64 games, top to bottom of a region.
export const SEED_ORDER = [1, 16, 8, 9, 5, 12, 4, 13, 6, 11, 3, 14, 7, 10, 2, 15];

export const ROUND_NAMES = {
    1: 'Round of 64',
    2: 'Round of 32',
    3: 'Sweet 16',
    4: 'Elite 8',
    5: 'Final Four',
    6: 'Championship'
};

export const DEFAULT_ROUND_POINTS = [10, 20, 40, 80, 160, 320];
export const REGION_COUNT = 4;
export const TOTAL_GAMES = 63;
const GAMES_PER_ROUND_IN_REGION = { 1: 8, 2: 4, 3: 2, 4: 1 };

export function makeGameId(regionIdx, round, slot) {
    return round <= 4 ? `R${regionIdx}-${round}-${slot}` : `FF-${round}-${slot}`;
}

export function parseGameId(id) {
    const parts = String(id).split('-');
    if (parts.length !== 3) {
        return null;
    }
    const round = parseInt(parts[1], 10);
    const slot = parseInt(parts[2], 10);
    if (parts[0] === 'FF') {
        return { regionIdx: null, round, slot };
    }
    return { regionIdx: parseInt(parts[0].substring(1), 10), round, slot };
}

export function roundOf(id) {
    const parsed = parseGameId(id);
    return parsed ? parsed.round : null;
}

/** Returns the id of the game the winner of `id` advances to, or null for the title game. */
export function nextGameId(id) {
    const { regionIdx, round, slot } = parseGameId(id);
    if (round < 4) {
        return makeGameId(regionIdx, round + 1, slot >> 1);
    }
    if (round === 4) {
        return makeGameId(null, 5, regionIdx >> 1);
    }
    if (round === 5) {
        return makeGameId(null, 6, 0);
    }
    return null;
}

/** Returns the two games that feed `id`, or null for Round of 64 games. */
export function feederGameIds(id) {
    const { regionIdx, round, slot } = parseGameId(id);
    if (round === 1) {
        return null;
    }
    if (round <= 4) {
        return [makeGameId(regionIdx, round - 1, slot * 2), makeGameId(regionIdx, round - 1, slot * 2 + 1)];
    }
    if (round === 5) {
        return [makeGameId(slot * 2, 4, 0), makeGameId(slot * 2 + 1, 4, 0)];
    }
    return [makeGameId(null, 5, 0), makeGameId(null, 5, 1)];
}

/** All 63 games, ordered by round so that feeders always come before the games they feed. */
export function buildGames() {
    const games = [];
    for (let round = 1; round <= 4; round++) {
        for (let r = 0; r < REGION_COUNT; r++) {
            for (let slot = 0; slot < GAMES_PER_ROUND_IN_REGION[round]; slot++) {
                games.push(describeGame(makeGameId(r, round, slot)));
            }
        }
    }
    games.push(describeGame('FF-5-0'), describeGame('FF-5-1'), describeGame('FF-6-0'));
    return games;
}

function describeGame(id) {
    const { regionIdx, round, slot } = parseGameId(id);
    const game = { id, regionIdx, round, slot, feeders: feederGameIds(id), next: nextGameId(id) };
    if (round === 1) {
        game.seeds = [SEED_ORDER[slot * 2], SEED_ORDER[slot * 2 + 1]];
    }
    return game;
}

const ALL_GAMES = buildGames();
const GAMES_BY_ID = ALL_GAMES.reduce((acc, g) => {
    acc[g.id] = g;
    return acc;
}, {});

export function getGame(id) {
    return GAMES_BY_ID[id];
}

export function allGames() {
    return ALL_GAMES;
}

/**
 * Index teams for fast lookups.
 * @param {Array<{id, name, seed, region}>} teams
 * @param {Array<string>} regionOrder
 */
export function indexTeams(teams, regionOrder) {
    const byId = {};
    const bySlot = {};
    const regionIndex = {};
    regionOrder.forEach((region, idx) => {
        regionIndex[String(region).trim().toLowerCase()] = idx;
    });
    (teams || []).forEach((team) => {
        const regionIdx = regionIndex[String(team.region || '').trim().toLowerCase()];
        const enriched = { ...team, regionIdx };
        byId[team.id] = enriched;
        if (regionIdx !== undefined) {
            bySlot[`${regionIdx}-${team.seed}`] = enriched;
        }
    });
    return { byId, bySlot };
}

/** Returns [teamIdA, teamIdB] (either may be null) currently playing in game `id`. */
export function participantsOf(id, winners, index) {
    const game = GAMES_BY_ID[id];
    if (game.round === 1) {
        return game.seeds.map((seed) => {
            const team = index.bySlot[`${game.regionIdx}-${seed}`];
            return team ? team.id : null;
        });
    }
    return game.feeders.map((feeder) => (winners && winners[feeder]) || null);
}

/** Removes any winner that is no longer one of the participants of its game. */
export function prune(winners, index) {
    const cleaned = { ...winners };
    ALL_GAMES.forEach((game) => {
        const winner = cleaned[game.id];
        if (winner && !participantsOf(game.id, cleaned, index).includes(winner)) {
            delete cleaned[game.id];
        }
    });
    // Drop unknown keys
    Object.keys(cleaned).forEach((key) => {
        if (!GAMES_BY_ID[key]) {
            delete cleaned[key];
        }
    });
    return cleaned;
}

/**
 * The tap action: make `teamId` the winner of `gameId` and advance it. Tapping
 * the current winner again clears the pick. Any later picks that depended on a
 * team that is no longer advancing are cleared automatically.
 */
export function applyPick(winners, gameId, teamId, index) {
    if (!teamId || !GAMES_BY_ID[gameId]) {
        return { ...winners };
    }
    const participants = participantsOf(gameId, winners, index);
    if (!participants.includes(teamId)) {
        return { ...winners };
    }
    const updated = { ...winners };
    if (updated[gameId] === teamId) {
        delete updated[gameId];
    } else {
        updated[gameId] = teamId;
    }
    return prune(updated, index);
}

/** Fill every empty game with the better (lower) seed. Existing picks are kept. */
export function fillChalk(winners, index) {
    const updated = { ...winners };
    ALL_GAMES.forEach((game) => {
        if (updated[game.id]) {
            return;
        }
        const [a, b] = participantsOf(game.id, updated, index);
        if (!a || !b) {
            return;
        }
        const seedA = index.byId[a] ? index.byId[a].seed : 99;
        const seedB = index.byId[b] ? index.byId[b].seed : 99;
        updated[game.id] = seedB < seedA ? b : a;
    });
    return updated;
}

/** All games on a team's path from the Round of 64 to the title game. */
export function pathOf(team) {
    if (!team || team.regionIdx === undefined || team.regionIdx === null) {
        return [];
    }
    const pos = SEED_ORDER.indexOf(Number(team.seed));
    if (pos < 0) {
        return [];
    }
    const path = [makeGameId(team.regionIdx, 1, pos >> 1)];
    let current = path[0];
    let next = nextGameId(current);
    while (next) {
        path.push(next);
        current = next;
        next = nextGameId(current);
    }
    return path;
}

/** Set of team ids that have lost a game according to `results`. */
export function eliminatedTeams(results, index) {
    const eliminated = new Set();
    Object.values(index.byId).forEach((team) => {
        const lost = pathOf(team).some((gameId) => results[gameId] && results[gameId] !== team.id);
        if (lost) {
            eliminated.add(team.id);
        }
    });
    return eliminated;
}

/**
 * Status of a single pick against the official results:
 *   'correct' | 'wrong' | 'dead' (picked team already eliminated) | 'pending' | 'none'
 */
export function pickStatus(gameId, picks, results, eliminated) {
    const pick = picks[gameId];
    if (!pick) {
        return 'none';
    }
    if (results[gameId]) {
        return results[gameId] === pick ? 'correct' : 'wrong';
    }
    return eliminated.has(pick) ? 'dead' : 'pending';
}

export function scoreBracket(picks, results, index, roundPoints = DEFAULT_ROUND_POINTS) {
    const eliminated = eliminatedTeams(results, index);
    let score = 0;
    let maxPossible = 0;
    let correct = 0;
    let pickCount = 0;
    ALL_GAMES.forEach((game) => {
        const pick = picks[game.id];
        if (!pick) {
            return;
        }
        pickCount++;
        const points = roundPoints[game.round - 1] || 0;
        const status = pickStatus(game.id, picks, results, eliminated);
        if (status === 'correct') {
            score += points;
            maxPossible += points;
            correct++;
        } else if (status === 'pending') {
            maxPossible += points;
        }
    });
    return { score, maxPossible, correct, pickCount };
}
