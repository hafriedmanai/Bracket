import { LightningElement, api } from 'lwc';

/**
 * One game in the bracket: two team buttons. Tapping a team fires `teamtap`
 * with { gameId, teamId } so the parent can advance that team.
 */
export default class BracketGame extends LightningElement {
    @api game;
    @api label;
    @api points;

    get hasHeader() {
        return !!(this.label || this.points);
    }

    handleTap(event) {
        const { gameId, teamId } = event.currentTarget.dataset;
        if (!teamId) {
            return;
        }
        this.dispatchEvent(new CustomEvent('teamtap', { detail: { gameId, teamId } }));
    }
}
