/**
 * Server API for the marchMadnessBracket Lightning Web Component.
 */
public with sharing class BracketController {
    public static final String COMMISSIONER_PERMISSION = 'Bracket_Commissioner';
    public static final String MODE_RESULTS = 'Results';

    public class TeamInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Integer seed;
        @AuraEnabled public String region;
        @AuraEnabled public String record;
    }

    public class EntryInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Boolean isMine;
        @AuraEnabled public Map<String, Id> picks;
        @AuraEnabled public Integer tiebreaker;
        @AuraEnabled public Integer score;
        @AuraEnabled public Integer maxPossible;
    }

    public class BracketData {
        @AuraEnabled public Id tournamentId;
        @AuraEnabled public String tournamentName;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime lockDate;
        @AuraEnabled public Boolean isLocked;
        @AuraEnabled public List<String> regionOrder;
        @AuraEnabled public List<Integer> roundPoints;
        @AuraEnabled public Integer championshipTotal;
        @AuraEnabled public List<TeamInfo> teams;
        @AuraEnabled public Map<String, Id> results;
        @AuraEnabled public EntryInfo entry;
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public Boolean isCommissioner;
    }

    public class LeaderboardRow {
        @AuraEnabled public Integer rank;
        @AuraEnabled public Id entryId;
        @AuraEnabled public String entryName;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Boolean isMine;
        @AuraEnabled public Integer score;
        @AuraEnabled public Integer maxPossible;
        @AuraEnabled public Integer correct;
        @AuraEnabled public Integer pickCount;
        @AuraEnabled public String championName;
        @AuraEnabled public Boolean championAlive;
        @AuraEnabled public Integer tiebreaker;
    }

    // ------------------------------------------------------------------ reads

    @AuraEnabled
    public static BracketData getBracketData(Id tournamentId, Id entryId, String mode) {
        try {
            Tournament__c tournament = loadTournament(tournamentId);
            BracketData data = new BracketData();
            data.tournamentId = tournament.Id;
            data.tournamentName = tournament.Name;
            data.status = tournament.Status__c;
            data.lockDate = tournament.Lock_Date__c;
            data.isLocked = isLocked(tournament);
            data.regionOrder = BracketScoringService.parseRegions(tournament.Region_Order__c);
            data.roundPoints = BracketScoringService.parsePoints(tournament.Round_Points__c);
            data.championshipTotal = toInt(tournament.Championship_Total_Points__c);
            data.results = BracketScoringService.parseWinners(tournament.Results__c);
            data.isCommissioner = isCommissioner();
            data.teams = new List<TeamInfo>();
            for (Team__c team : loadTeams(tournament.Id)) {
                TeamInfo info = new TeamInfo();
                info.id = team.Id;
                info.name = team.Name;
                info.seed = toInt(team.Seed__c);
                info.region = team.Region__c;
                info.record = team.Record__c;
                data.teams.add(info);
            }

            if (mode == MODE_RESULTS) {
                data.canEdit = data.isCommissioner;
                return data;
            }

            Bracket_Entry__c entry = entryId != null ? loadEntry(entryId) : findMyEntry(tournament.Id);
            if (entry != null && entry.OwnerId != UserInfo.getUserId() && !data.isLocked && !data.isCommissioner) {
                throw new BracketScoringService.BracketException('Other brackets are hidden until picks lock.');
            }
            data.entry = toEntryInfo(entry);
            data.canEdit = !data.isLocked && (entry == null || entry.OwnerId == UserInfo.getUserId());
            return data;
        } catch (Exception e) {
            throw asAuraException(e);
        }
    }

    @AuraEnabled
    public static List<LeaderboardRow> getLeaderboard(Id tournamentId) {
        try {
            Tournament__c tournament = loadTournament(tournamentId);
            Map<String, Id> results = BracketScoringService.parseWinners(tournament.Results__c);
            BracketScoringService.Field field = new BracketScoringService.Field(tournament, loadTeams(tournament.Id));
            Set<Id> eliminated = BracketScoringService.eliminatedTeams(results, field);
            Integer actualTotal = toInt(tournament.Championship_Total_Points__c);

            List<RowSort> sortable = new List<RowSort>();
            for (Bracket_Entry__c entry : [
                SELECT Id, Name, OwnerId, Owner.Name, Score__c, Max_Possible__c, Correct_Picks__c,
                    Pick_Count__c, Tiebreaker__c, Champion__c, Champion__r.Name
                FROM Bracket_Entry__c
                WHERE Tournament__c = :tournament.Id
                WITH USER_MODE
            ]) {
                LeaderboardRow row = new LeaderboardRow();
                row.entryId = entry.Id;
                row.entryName = entry.Name;
                row.ownerName = entry.Owner.Name;
                row.isMine = entry.OwnerId == UserInfo.getUserId();
                row.score = toInt(entry.Score__c);
                row.maxPossible = toInt(entry.Max_Possible__c);
                row.correct = toInt(entry.Correct_Picks__c);
                row.pickCount = toInt(entry.Pick_Count__c);
                row.tiebreaker = toInt(entry.Tiebreaker__c);
                row.championName = entry.Champion__r?.Name;
                row.championAlive = entry.Champion__c != null && !eliminated.contains(entry.Champion__c);
                sortable.add(new RowSort(row, actualTotal));
            }
            sortable.sort();

            List<LeaderboardRow> rows = new List<LeaderboardRow>();
            for (Integer i = 0; i < sortable.size(); i++) {
                LeaderboardRow row = sortable[i].row;
                Boolean tiedWithPrevious = i > 0 && sortable[i].compareTo(sortable[i - 1]) == 0;
                row.rank = tiedWithPrevious ? rows[i - 1].rank : i + 1;
                rows.add(row);
            }
            return rows;
        } catch (Exception e) {
            throw asAuraException(e);
        }
    }

    // ----------------------------------------------------------------- writes

    @AuraEnabled
    public static EntryInfo savePicks(Id tournamentId, String picksJson, Integer tiebreaker, String entryName) {
        try {
            Tournament__c tournament = loadTournament(tournamentId);
            if (isLocked(tournament)) {
                throw new BracketScoringService.BracketException('Picks are locked for this tournament.');
            }
            BracketScoringService.Field field = new BracketScoringService.Field(tournament, loadTeams(tournament.Id));
            Map<String, Id> picks = BracketScoringService.parseWinners(picksJson);
            BracketScoringService.validate(picks, field);

            Bracket_Entry__c entry = findMyEntry(tournament.Id);
            if (entry == null) {
                entry = new Bracket_Entry__c(Tournament__c = tournament.Id, OwnerId = UserInfo.getUserId());
            }
            entry.Name = String.isNotBlank(entryName)
                ? entryName.abbreviate(80)
                : (entry.Name != null ? entry.Name : (UserInfo.getName() + '\'s Bracket').abbreviate(80));
            entry.Picks__c = System.JSON.serialize(picks);
            entry.Tiebreaker__c = tiebreaker;
            entry.Champion__c = picks.get('FF-6-0');
            BracketScoringService.applyScore(
                entry,
                BracketScoringService.score(picks, BracketScoringService.parseWinners(tournament.Results__c), field)
            );
            // Players only have read access to Bracket Entry in the UI, so picks can't be edited
            // around the lock; all writes go through this method.
            BracketScoringService.saveEntry(entry);
            return toEntryInfo(loadEntry(entry.Id));
        } catch (Exception e) {
            throw asAuraException(e);
        }
    }

    @AuraEnabled
    public static void saveResults(Id tournamentId, String resultsJson, Integer championshipTotal) {
        try {
            if (!isCommissioner()) {
                throw new BracketScoringService.BracketException('Only the pool commissioner can enter results.');
            }
            Tournament__c tournament = loadTournament(tournamentId);
            BracketScoringService.Field field = new BracketScoringService.Field(tournament, loadTeams(tournament.Id));
            Map<String, Id> results = BracketScoringService.parseWinners(resultsJson);
            BracketScoringService.validate(results, field);

            tournament.Results__c = System.JSON.serialize(results);
            tournament.Championship_Total_Points__c = championshipTotal;
            if (results.containsKey('FF-6-0')) {
                tournament.Status__c = 'Complete';
            } else if (!results.isEmpty() && tournament.Status__c == 'Open') {
                tournament.Status__c = 'Locked';
            }
            update as user tournament;
            BracketScoringService.rescoreTournament(tournament.Id);
        } catch (Exception e) {
            throw asAuraException(e);
        }
    }

    // ---------------------------------------------------------------- helpers

    @TestVisible
    private static Boolean isLocked(Tournament__c tournament) {
        if (tournament.Status__c != null && tournament.Status__c != 'Open') {
            return true;
        }
        return tournament.Lock_Date__c != null && System.now() >= tournament.Lock_Date__c;
    }

    private static Boolean isCommissioner() {
        return FeatureManagement.checkPermission(COMMISSIONER_PERMISSION);
    }

    private static Tournament__c loadTournament(Id tournamentId) {
        List<Tournament__c> tournaments;
        if (tournamentId != null) {
            tournaments = [
                SELECT Id, Name, Status__c, Lock_Date__c, Region_Order__c, Round_Points__c, Results__c,
                    Championship_Total_Points__c
                FROM Tournament__c
                WHERE Id = :tournamentId
                WITH USER_MODE
            ];
        } else {
            tournaments = [
                SELECT Id, Name, Status__c, Lock_Date__c, Region_Order__c, Round_Points__c, Results__c,
                    Championship_Total_Points__c
                FROM Tournament__c
                WITH USER_MODE
                ORDER BY Year__c DESC NULLS LAST, CreatedDate DESC
                LIMIT 1
            ];
        }
        if (tournaments.isEmpty()) {
            throw new BracketScoringService.BracketException(
                'No tournament found. Ask your commissioner to create one and load the teams.'
            );
        }
        return tournaments[0];
    }

    private static List<Team__c> loadTeams(Id tournamentId) {
        return [
            SELECT Id, Name, Seed__c, Region__c, Record__c
            FROM Team__c
            WHERE Tournament__c = :tournamentId
            WITH USER_MODE
            ORDER BY Region__c, Seed__c
        ];
    }

    private static Bracket_Entry__c findMyEntry(Id tournamentId) {
        List<Bracket_Entry__c> entries = [
            SELECT Id, Name, OwnerId, Owner.Name, Picks__c, Tiebreaker__c, Score__c, Max_Possible__c
            FROM Bracket_Entry__c
            WHERE Tournament__c = :tournamentId AND OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY CreatedDate
            LIMIT 1
        ];
        return entries.isEmpty() ? null : entries[0];
    }

    private static Bracket_Entry__c loadEntry(Id entryId) {
        List<Bracket_Entry__c> entries = [
            SELECT Id, Name, OwnerId, Owner.Name, Picks__c, Tiebreaker__c, Score__c, Max_Possible__c
            FROM Bracket_Entry__c
            WHERE Id = :entryId
            WITH USER_MODE
        ];
        if (entries.isEmpty()) {
            throw new BracketScoringService.BracketException('Bracket not found.');
        }
        return entries[0];
    }

    private static EntryInfo toEntryInfo(Bracket_Entry__c entry) {
        if (entry == null) {
            return null;
        }
        EntryInfo info = new EntryInfo();
        info.id = entry.Id;
        info.name = entry.Name;
        info.ownerName = entry.Owner?.Name;
        info.isMine = entry.OwnerId == UserInfo.getUserId();
        info.picks = BracketScoringService.parseWinners(entry.Picks__c);
        info.tiebreaker = toInt(entry.Tiebreaker__c);
        info.score = toInt(entry.Score__c);
        info.maxPossible = toInt(entry.Max_Possible__c);
        return info;
    }

    private static Integer toInt(Decimal value) {
        return value == null ? null : value.intValue();
    }

    private static Exception asAuraException(Exception e) {
        if (e instanceof AuraHandledException) {
            return e;
        }
        String message = e instanceof BracketScoringService.BracketException ? e.getMessage() : 'Something went wrong: ' + e.getMessage();
        AuraHandledException aura = new AuraHandledException(message);
        aura.setMessage(message);
        return aura;
    }

    /** Sort: score desc, then closest tiebreaker (once the final total is known), then max possible desc. */
    private class RowSort implements Comparable {
        public LeaderboardRow row;
        private Integer actualTotal;

        RowSort(LeaderboardRow row, Integer actualTotal) {
            this.row = row;
            this.actualTotal = actualTotal;
        }

        private Integer tiebreakDiff() {
            if (actualTotal == null) {
                return 0;
            }
            return row.tiebreaker == null ? 99999 : Math.abs(row.tiebreaker - actualTotal);
        }

        public Integer compareTo(Object other) {
            RowSort that = (RowSort) other;
            Integer a = nz(row.score), b = nz(that.row.score);
            if (a != b) {
                return a > b ? -1 : 1;
            }
            Integer da = tiebreakDiff(), db = that.tiebreakDiff();
            if (da != db) {
                return da < db ? -1 : 1;
            }
            a = nz(row.maxPossible);
            b = nz(that.row.maxPossible);
            if (a != b) {
                return a > b ? -1 : 1;
            }
            return 0;
        }

        private Integer nz(Integer value) {
            return value == null ? 0 : value;
        }
    }
}
