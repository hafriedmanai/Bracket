import { LightningElement, api } from 'lwc';
import getLeaderboard from '@salesforce/apex/BracketController.getLeaderboard';

export default class BracketLeaderboard extends LightningElement {
    @api tournamentId;
    @api isLocked = false;
    @api isCommissioner = false;

    rows = [];
    isLoading = true;
    error;

    connectedCallback() {
        this.refresh();
    }

    @api
    async refresh() {
        if (!this.tournamentId) {
            return;
        }
        this.isLoading = true;
        this.error = undefined;
        try {
            const rows = await getLeaderboard({ tournamentId: this.tournamentId });
            this.rows = rows.map((row) => this.decorate(row));
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the leaderboard.';
        } finally {
            this.isLoading = false;
        }
    }

    decorate(row) {
        const canView = row.isMine || this.isLocked || this.isCommissioner;
        return {
            ...row,
            rowClass: `lb-row${row.isMine ? ' lb-row_mine' : ''}`,
            rankClass: `lb-rank lb-rank_${row.rank <= 3 ? row.rank : 'other'}`,
            championClass: `lb-champ${row.championName && !row.championAlive ? ' lb-champ_out' : ''}`,
            championDisplay: row.championName || '—',
            progress: `${row.pickCount || 0}/63 picks`,
            canView,
            viewLabel: `View bracket ${row.entryName}`
        };
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get footnote() {
        return this.isLocked
            ? 'Tap a bracket to view its picks.'
            : 'Other brackets become visible once picks lock.';
    }

    handleView(event) {
        this.dispatchEvent(new CustomEvent('viewentry', { detail: { entryId: event.currentTarget.dataset.id } }));
    }
}
