import { createElement } from 'lwc';
import MarchMadnessBracket from 'c/marchMadnessBracket';
import getBracketData from '@salesforce/apex/BracketController.getBracketData';
import savePicks from '@salesforce/apex/BracketController.savePicks';

jest.mock('@salesforce/apex/BracketController.getBracketData', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/BracketController.savePicks', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/BracketController.saveResults', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/BracketController.getLeaderboard', () => ({ default: jest.fn(() => Promise.resolve([])) }), {
    virtual: true
});

const REGIONS = ['East', 'West', 'South', 'Midwest'];

function bracketData(overrides = {}) {
    const teams = [];
    REGIONS.forEach((region) => {
        for (let seed = 1; seed <= 16; seed++) {
            teams.push({ id: `${region}${seed}`, name: `${region} ${seed}`, seed, region });
        }
    });
    return {
        tournamentId: 'a00000000000001',
        tournamentName: 'Test Madness',
        isLocked: false,
        canEdit: true,
        isCommissioner: false,
        regionOrder: REGIONS,
        roundPoints: [10, 20, 40, 80, 160, 320],
        teams,
        results: {},
        entry: null,
        ...overrides
    };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function teamButtons(element) {
    const games = element.shadowRoot.querySelectorAll('c-bracket-game');
    return Array.from(games).map((g) => Array.from(g.shadowRoot.querySelectorAll('button.team')));
}

describe('c-march-madness-bracket', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the first region with 15 games', async () => {
        getBracketData.mockResolvedValue(bracketData());
        const element = createElement('c-march-madness-bracket', { is: MarchMadnessBracket });
        document.body.appendChild(element);
        await flush();

        const games = element.shadowRoot.querySelectorAll('c-bracket-game');
        expect(games).toHaveLength(15);
        const first = teamButtons(element)[0];
        expect(first[0].textContent).toContain('East 1');
        expect(first[1].textContent).toContain('East 16');
    });

    it('advances a tapped team into the next round', async () => {
        getBracketData.mockResolvedValue(bracketData());
        const element = createElement('c-march-madness-bracket', { is: MarchMadnessBracket });
        document.body.appendChild(element);
        await flush();

        teamButtons(element)[0][1].click(); // East 16 upsets East 1
        await flush();

        const buttons = teamButtons(element);
        expect(buttons[0][1].className).toContain('team_winner');
        // Round of 32 games start at index 8; first slot is fed by game 0
        expect(buttons[8][0].textContent).toContain('East 16');
        expect(element.shadowRoot.textContent).toContain('1 / 63 picks');
        expect(element.shadowRoot.textContent).toContain('unsaved changes');
    });

    it('saves picks as JSON', async () => {
        getBracketData.mockResolvedValue(bracketData());
        savePicks.mockResolvedValue({});
        const element = createElement('c-march-madness-bracket', { is: MarchMadnessBracket });
        document.body.appendChild(element);
        await flush();

        teamButtons(element)[0][0].click();
        await flush();
        const save = Array.from(element.shadowRoot.querySelectorAll('lightning-button')).find(
            (b) => b.label === 'Save Bracket'
        );
        save.click();
        await flush();

        expect(savePicks).toHaveBeenCalledTimes(1);
        const args = savePicks.mock.calls[0][0];
        expect(JSON.parse(args.picksJson)).toEqual({ 'R0-1-0': 'East1' });
    });

    it('is read-only once picks lock', async () => {
        getBracketData.mockResolvedValue(bracketData({ isLocked: true, canEdit: false }));
        const element = createElement('c-march-madness-bracket', { is: MarchMadnessBracket });
        document.body.appendChild(element);
        await flush();

        const button = teamButtons(element)[0][0];
        expect(button.disabled).toBe(true);
        button.click();
        await flush();
        expect(element.shadowRoot.textContent).toContain('0 / 63 picks');
    });
});
