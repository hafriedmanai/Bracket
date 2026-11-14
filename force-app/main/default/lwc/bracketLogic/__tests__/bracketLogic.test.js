import {
    TOTAL_GAMES,
    allGames,
    applyPick,
    eliminatedTeams,
    feederGameIds,
    fillChalk,
    indexTeams,
    nextGameId,
    participantsOf,
    pathOf,
    pickStatus,
    scoreBracket
} from 'c/bracketLogic';

const REGIONS = ['East', 'West', 'South', 'Midwest'];

function makeTeams() {
    const teams = [];
    REGIONS.forEach((region) => {
        for (let seed = 1; seed <= 16; seed++) {
            teams.push({ id: `${region}${seed}`, name: `${region} ${seed}`, seed, region });
        }
    });
    return teams;
}

const index = indexTeams(makeTeams(), REGIONS);

describe('bracket structure', () => {
    it('has 63 games ordered so feeders come first', () => {
        const games = allGames();
        expect(games).toHaveLength(TOTAL_GAMES);
        const seen = new Set();
        games.forEach((g) => {
            (g.feeders || []).forEach((f) => expect(seen.has(f)).toBe(true));
            seen.add(g.id);
        });
    });

    it('links games forward and backward consistently', () => {
        allGames().forEach((g) => {
            if (g.next) {
                expect(feederGameIds(g.next)).toContain(g.id);
            }
        });
        expect(nextGameId('R0-4-0')).toBe('FF-5-0');
        expect(nextGameId('R1-4-0')).toBe('FF-5-0');
        expect(nextGameId('R2-4-0')).toBe('FF-5-1');
        expect(nextGameId('FF-5-1')).toBe('FF-6-0');
        expect(nextGameId('FF-6-0')).toBeNull();
    });

    it('pairs Round of 64 seeds the standard way', () => {
        expect(participantsOf('R0-1-0', {}, index)).toEqual(['East1', 'East16']);
        expect(participantsOf('R0-1-1', {}, index)).toEqual(['East8', 'East9']);
        expect(participantsOf('R3-1-7', {}, index)).toEqual(['Midwest2', 'Midwest15']);
    });

    it('builds a six-game path for every team', () => {
        expect(pathOf(index.byId.East1)).toEqual(['R0-1-0', 'R0-2-0', 'R0-3-0', 'R0-4-0', 'FF-5-0', 'FF-6-0']);
        expect(pathOf(index.byId.Midwest15)).toEqual(['R3-1-7', 'R3-2-3', 'R3-3-1', 'R3-4-0', 'FF-5-1', 'FF-6-0']);
    });
});

describe('tap to advance', () => {
    it('advances the tapped team into the next game', () => {
        let picks = applyPick({}, 'R0-1-0', 'East1', index);
        picks = applyPick(picks, 'R0-1-1', 'East9', index);
        expect(participantsOf('R0-2-0', picks, index)).toEqual(['East1', 'East9']);
    });

    it('ignores taps on a team that is not in the game', () => {
        const picks = applyPick({}, 'R0-2-0', 'East1', index);
        expect(picks).toEqual({});
    });

    it('toggles a pick off when the winner is tapped again', () => {
        let picks = applyPick({}, 'R0-1-0', 'East1', index);
        picks = applyPick(picks, 'R0-1-0', 'East1', index);
        expect(picks['R0-1-0']).toBeUndefined();
    });

    it('clears later picks when an earlier pick changes', () => {
        let picks = fillChalk({}, index);
        expect(Object.keys(picks)).toHaveLength(TOTAL_GAMES);
        expect(picks['FF-6-0']).toBe('East1');

        picks = applyPick(picks, 'R0-1-0', 'East16', index);
        expect(picks['R0-1-0']).toBe('East16');
        ['R0-2-0', 'R0-3-0', 'R0-4-0', 'FF-5-0', 'FF-6-0'].forEach((id) => expect(picks[id]).toBeUndefined());
        // Unrelated picks are kept
        expect(picks['R1-4-0']).toBe('West1');
        expect(Object.keys(picks)).toHaveLength(TOTAL_GAMES - 5);
    });

    it('fills favorites only into empty games', () => {
        const picks = fillChalk({ 'R0-1-0': 'East16' }, index);
        expect(picks['R0-1-0']).toBe('East16');
        expect(picks['R0-2-0']).toBe('East8');
    });
});

describe('scoring', () => {
    it('scores correct picks and computes max possible', () => {
        const picks = fillChalk({}, index);
        const results = { 'R0-1-0': 'East1', 'R0-1-1': 'East9' };
        const eliminated = eliminatedTeams(results, index);
        expect(eliminated.has('East8')).toBe(true);
        expect(eliminated.has('East16')).toBe(true);
        expect(pickStatus('R0-1-0', picks, results, eliminated)).toBe('correct');
        expect(pickStatus('R0-1-1', picks, results, eliminated)).toBe('wrong');
        expect(pickStatus('R0-2-0', picks, results, eliminated)).toBe('pending');

        const s = scoreBracket(picks, results, index);
        expect(s.score).toBe(10);
        expect(s.correct).toBe(1);
        expect(s.pickCount).toBe(63);
        expect(s.maxPossible).toBe(1920 - 10);
    });

    it('marks a pick dead once the team has been eliminated', () => {
        const picks = fillChalk({}, index);
        const results = { 'R0-1-1': 'East9' };
        const eliminated = eliminatedTeams(results, index);
        // East 1 vs East 8 was picked for the Round of 32; East 8 is out.
        const r32 = { 'R0-1-1': 'East8', 'R0-2-0': 'East8' };
        expect(pickStatus('R0-2-0', r32, results, eliminated)).toBe('dead');
        expect(pickStatus('R0-2-0', picks, results, eliminated)).toBe('pending');
    });
});
