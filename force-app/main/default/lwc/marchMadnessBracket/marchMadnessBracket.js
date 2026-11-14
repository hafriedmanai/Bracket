import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getBracketData from '@salesforce/apex/BracketController.getBracketData';
import savePicks from '@salesforce/apex/BracketController.savePicks';
import saveResults from '@salesforce/apex/BracketController.saveResults';
import {
    ROUND_NAMES,
    TOTAL_GAMES,
    allGames,
    applyPick,
    eliminatedTeams,
    fillChalk,
    indexTeams,
    participantsOf,
    pickStatus,
    scoreBracket
} from 'c/bracketLogic';

const FINAL_FOUR_TAB = 'final';
const LEADERBOARD_VIEW = 'leaderboard';
const BRACKET_VIEW = 'bracket';

export default class MarchMadnessBracket extends LightningElement {
    /** Tournament__c record id. Optional: on a Tournament record page recordId is used, otherwise the newest tournament. */
    @api tournamentId;
    @api recordId;
    /** "Picks" (players fill out brackets) or "Results" (commissioner enters actual winners). */
    @api mode = 'Picks';
    @api cardTitle;

    @track winners = {};
    data;
    index;
    tiebreaker;
    entryName;
    viewingEntryId;
    activeView = BRACKET_VIEW;
    activeTab = '0';
    isDirty = false;
    isLoading = true;
    isSaving = false;
    error;

    connectedCallback() {
        this.load();
    }

    get isResultsMode() {
        return this.mode === 'Results';
    }

    get effectiveTournamentId() {
        return this.tournamentId || this.recordId || null;
    }

    async load() {
        this.isLoading = true;
        this.error = undefined;
        try {
            const data = await getBracketData({
                tournamentId: this.effectiveTournamentId,
                entryId: this.viewingEntryId || null,
                mode: this.isResultsMode ? 'Results' : 'Picks'
            });
            this.data = data;
            this.index = indexTeams(
                (data.teams || []).map((t) => ({ ...t })),
                data.regionOrder || []
            );
            if (this.isResultsMode) {
                this.winners = { ...(data.results || {}) };
                this.tiebreaker = data.championshipTotal;
            } else {
                this.winners = { ...((data.entry && data.entry.picks) || {}) };
                this.tiebreaker = data.entry ? data.entry.tiebreaker : null;
                this.entryName = data.entry ? data.entry.name : null;
            }
            this.isDirty = false;
        } catch (e) {
            this.error = reduceError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------ view state

    get title() {
        if (this.cardTitle) {
            return this.cardTitle;
        }
        return this.data ? this.data.tournamentName : 'March Madness';
    }

    get subtitle() {
        if (!this.data) {
            return '';
        }
        if (this.isResultsMode) {
            return 'Commissioner: tap the winner of each game as it finishes';
        }
        if (this.isViewingOther) {
            return `Viewing ${this.data.entry.name} (${this.data.entry.ownerName})`;
        }
        if (this.data.isLocked) {
            return 'Picks are locked';
        }
        return this.data.lockDate ? `Picks lock ${formatDate(this.data.lockDate)}` : 'Tap a team to advance it';
    }

    get isViewingOther() {
        return !!(this.data && this.data.entry && !this.data.entry.isMine);
    }

    get canEdit() {
        return !!(this.data && this.data.canEdit && !this.isViewingOther);
    }

    get readOnly() {
        return !this.canEdit;
    }

    get showBracket() {
        return this.activeView === BRACKET_VIEW;
    }

    get showLeaderboard() {
        return this.activeView === LEADERBOARD_VIEW;
    }

    get bracketViewLabel() {
        if (this.isResultsMode) {
            return 'Results';
        }
        return this.isViewingOther ? 'Bracket' : 'My Bracket';
    }

    get bracketViewClass() {
        return this.viewButtonClass(BRACKET_VIEW);
    }

    get leaderboardViewClass() {
        return this.viewButtonClass(LEADERBOARD_VIEW);
    }

    viewButtonClass(view) {
        return `view-toggle__btn${this.activeView === view ? ' view-toggle__btn_active' : ''}`;
    }

    get pickCount() {
        return Object.keys(this.winners).length;
    }

    get progressLabel() {
        return `${this.pickCount} / ${TOTAL_GAMES} ${this.isResultsMode ? 'games final' : 'picks'}`;
    }

    get progressStyle() {
        return `width: ${Math.round((this.pickCount / TOTAL_GAMES) * 100)}%`;
    }

    get scoreSummary() {
        if (this.isResultsMode || !this.data || !this.hasResults) {
            return null;
        }
        const s = scoreBracket(this.winners, this.data.results || {}, this.index, this.data.roundPoints);
        return `${s.score} pts · ${s.correct} correct · ${s.maxPossible} max`;
    }

    get hasResults() {
        return this.data && this.data.results && Object.keys(this.data.results).length > 0;
    }

    get saveDisabled() {
        return !this.isDirty || this.isSaving;
    }

    get saveLabel() {
        return this.isResultsMode ? 'Save Results' : 'Save Bracket';
    }

    get championName() {
        const champ = this.winners['FF-6-0'];
        return champ ? this.teamLabel(champ) : null;
    }

    get championLabel() {
        return this.isResultsMode ? 'National Champion' : 'Your Champion';
    }

    get championDisplay() {
        return this.championName || 'Tap the title game winner';
    }

    get tiebreakerLabel() {
        return this.isResultsMode ? 'Championship game total points' : 'Tiebreaker: total points in the title game';
    }

    get tiebreakerHelp() {
        return this.isResultsMode
            ? 'Combined final score of both teams. Used to break ties on the leaderboard.'
            : 'Your guess for the combined score of both teams. Closest guess wins ties.';
    }

    get showFillFavorites() {
        return !this.isResultsMode && this.canEdit;
    }

    get showEntryName() {
        return !this.isResultsMode && this.canEdit;
    }

    get regionTabs() {
        const regions = (this.data && this.data.regionOrder) || [];
        const tabs = regions.map((region, idx) => {
            const done = allGames().filter((g) => g.regionIdx === idx && this.winners[g.id]).length;
            return {
                key: String(idx),
                label: region,
                count: `${done}/15`,
                className: this.tabClass(String(idx))
            };
        });
        const ffDone = ['FF-5-0', 'FF-5-1', 'FF-6-0'].filter((id) => this.winners[id]).length;
        tabs.push({
            key: FINAL_FOUR_TAB,
            label: 'Final Four',
            count: `${ffDone}/3`,
            className: this.tabClass(FINAL_FOUR_TAB)
        });
        return tabs;
    }

    tabClass(key) {
        return `region-tab${this.activeTab === key ? ' region-tab_active' : ''}`;
    }

    get isFinalFourTab() {
        return this.activeTab === FINAL_FOUR_TAB;
    }

    get eliminated() {
        return this.data ? eliminatedTeams(this.data.results || {}, this.index) : new Set();
    }

    /** Columns (rounds 1-4) of the selected region. */
    get regionRounds() {
        if (!this.data || this.isFinalFourTab) {
            return [];
        }
        const regionIdx = parseInt(this.activeTab, 10);
        const eliminated = this.eliminated;
        return [1, 2, 3, 4].map((round) => ({
            key: `round-${round}`,
            name: ROUND_NAMES[round],
            points: this.pointsLabel(round),
            className: `round round_${round}`,
            games: allGames()
                .filter((g) => g.regionIdx === regionIdx && g.round === round)
                .map((g) => this.decorateGame(g, eliminated))
        }));
    }

    get finalFourGames() {
        if (!this.data) {
            return {};
        }
        const eliminated = this.eliminated;
        const byId = {};
        allGames()
            .filter((g) => g.round >= 5)
            .forEach((g) => {
                byId[g.id] = this.decorateGame(g, eliminated);
            });
        const regions = this.data.regionOrder || [];
        byId['FF-5-0'].label = `${regions[0] || ''} vs ${regions[1] || ''}`;
        byId['FF-5-1'].label = `${regions[2] || ''} vs ${regions[3] || ''}`;
        byId['FF-6-0'].label = 'National Championship';
        return {
            semiOne: byId['FF-5-0'],
            semiTwo: byId['FF-5-1'],
            title: byId['FF-6-0'],
            semiPoints: this.pointsLabel(5),
            titlePoints: this.pointsLabel(6)
        };
    }

    pointsLabel(round) {
        const pts = this.data && this.data.roundPoints ? this.data.roundPoints[round - 1] : null;
        return pts ? `${pts} pts` : '';
    }

    decorateGame(game, eliminated) {
        const participants = participantsOf(game.id, this.winners, this.index);
        const winner = this.winners[game.id];
        const results = (this.data && this.data.results) || {};
        const status = this.isResultsMode ? 'none' : pickStatus(game.id, this.winners, results, eliminated);
        const actual = results[game.id];
        const teams = participants.map((teamId, i) => {
            const team = teamId ? this.index.byId[teamId] : null;
            const isWinner = !!teamId && winner === teamId;
            const isLoser = !!winner && !!teamId && !isWinner;
            const classes = ['team'];
            if (!team) {
                classes.push('team_empty');
            }
            if (isWinner) {
                classes.push('team_winner');
                if (status !== 'none') {
                    classes.push(`team_${status}`);
                }
            }
            if (isLoser) {
                classes.push('team_loser');
            }
            if (!this.isResultsMode && team && eliminated.has(teamId)) {
                classes.push('team_out');
            }
            if (this.canEdit && team) {
                classes.push('team_tappable');
            }
            return {
                key: `${game.id}-${i}`,
                teamId: teamId || '',
                gameId: game.id,
                seed: team ? team.seed : '',
                name: team ? team.name : 'TBD',
                className: classes.join(' '),
                ariaLabel: team
                    ? `${team.seed} seed ${team.name}${isWinner ? ', picked to win' : ''}`
                    : 'To be determined',
                disabled: !this.canEdit || !team,
                isWinner
            };
        });
        let note = null;
        if (!this.isResultsMode && status === 'wrong' && actual) {
            note = `Winner: ${this.teamLabel(actual)}`;
        }
        return { id: game.id, key: game.id, teams, note, className: `game game_${status}` };
    }

    teamLabel(teamId) {
        const team = this.index && this.index.byId[teamId];
        return team ? `(${team.seed}) ${team.name}` : '';
    }

    // ------------------------------------------------------------ handlers

    handleTeamTap(event) {
        if (!this.canEdit) {
            return;
        }
        const { gameId, teamId } = event.detail;
        if (!teamId) {
            return;
        }
        const before = this.winners;
        const after = applyPick(before, gameId, teamId, this.index);
        const removed = Object.keys(before).filter((id) => id !== gameId && !after[id]).length;
        this.winners = after;
        this.isDirty = true;
        if (removed > 0) {
            this.toast(
                'Later picks cleared',
                `${removed} later ${removed === 1 ? 'pick was' : 'picks were'} cleared because that team is no longer advancing.`,
                'info'
            );
        }
        // Once a region's Elite 8 game is picked, jump ahead to the next region.
        if (after[gameId] && gameId.match(/^R\d-4-0$/) && this.regionIsComplete(gameId)) {
            this.advanceTab();
        }
    }

    regionIsComplete(eliteEightId) {
        const regionIdx = parseInt(eliteEightId.substring(1), 10);
        return allGames()
            .filter((g) => g.regionIdx === regionIdx)
            .every((g) => this.winners[g.id]);
    }

    advanceTab() {
        const keys = this.regionTabs.map((t) => t.key);
        const pos = keys.indexOf(this.activeTab);
        const next = keys.slice(pos + 1).find((key) => {
            if (key === FINAL_FOUR_TAB) {
                return true;
            }
            const idx = parseInt(key, 10);
            return !allGames().filter((g) => g.regionIdx === idx).every((g) => this.winners[g.id]);
        });
        if (next) {
            this.activeTab = next;
        }
    }

    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.key;
    }

    handleShowBracket() {
        this.activeView = BRACKET_VIEW;
    }

    handleShowLeaderboard() {
        this.activeView = LEADERBOARD_VIEW;
    }

    handleTiebreakerChange(event) {
        const value = event.target.value;
        this.tiebreaker = value === '' || value === null ? null : parseInt(value, 10);
        this.isDirty = true;
    }

    handleNameChange(event) {
        this.entryName = event.target.value;
        this.isDirty = true;
    }

    handleFillChalk() {
        this.winners = fillChalk(this.winners, this.index);
        this.isDirty = true;
    }

    async handleReset() {
        if (this.pickCount) {
            const ok = await LightningConfirm.open({
                message: 'Clear every pick in this bracket? Nothing is saved until you tap Save.',
                label: 'Clear bracket',
                theme: 'warning'
            });
            if (!ok) {
                return;
            }
        }
        this.winners = {};
        this.isDirty = true;
    }

    handleRevert() {
        this.load();
    }

    async handleSave() {
        this.isSaving = true;
        try {
            const json = JSON.stringify(this.winners);
            if (this.isResultsMode) {
                await saveResults({
                    tournamentId: this.data.tournamentId,
                    resultsJson: json,
                    championshipTotal: this.tiebreaker
                });
                this.toast('Results saved', 'Every bracket has been re-scored.', 'success');
            } else {
                await savePicks({
                    tournamentId: this.data.tournamentId,
                    picksJson: json,
                    tiebreaker: this.tiebreaker,
                    entryName: this.entryName
                });
                const message =
                    this.pickCount === TOTAL_GAMES
                        ? 'Your bracket is complete. Good luck!'
                        : `Saved ${this.pickCount} of ${TOTAL_GAMES} picks. Finish before picks lock.`;
                this.toast('Bracket saved', message, 'success');
            }
            await this.load();
            const board = this.template.querySelector('c-bracket-leaderboard');
            if (board) {
                board.refresh();
            }
        } catch (e) {
            this.toast('Could not save', reduceError(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleViewEntry(event) {
        this.viewingEntryId = event.detail.entryId;
        this.activeView = BRACKET_VIEW;
        this.activeTab = '0';
        this.load();
    }

    handleBackToMine() {
        this.viewingEntryId = null;
        this.load();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

function reduceError(e) {
    if (!e) {
        return 'Unknown error';
    }
    if (e.body && e.body.message) {
        return e.body.message;
    }
    return e.message || String(e);
}

function formatDate(value) {
    try {
        return new Intl.DateTimeFormat(undefined, {
            weekday: 'short',
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit'
        }).format(new Date(value));
    } catch (err) {
        return String(value);
    }
}
