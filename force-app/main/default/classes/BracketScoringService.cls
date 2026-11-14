/**
 * Bracket structure, validation and scoring. Mirrors the LWC module c/bracketLogic.
 *
 * Game ids:
 *   Rounds 1-4: "R{regionIdx}-{round}-{slot}"   Final Four: "FF-5-0", "FF-5-1"   Title: "FF-6-0"
 *
 * Runs without sharing so the commissioner can re-score every entry when results change,
 * even though Bracket Entry records are owned by (and private to edit for) each player.
 */
public without sharing class BracketScoringService {
    public static final List<Integer> SEED_ORDER = new List<Integer>{ 1, 16, 8, 9, 5, 12, 4, 13, 6, 11, 3, 14, 7, 10, 2, 15 };
    public static final List<Integer> DEFAULT_POINTS = new List<Integer>{ 10, 20, 40, 80, 160, 320 };
    public static final Integer TOTAL_GAMES = 63;

    /** Ordered list of all game ids, feeders always before the games they feed. */
    public static List<String> allGameIds() {
        List<String> ids = new List<String>();
        Map<Integer, Integer> gamesPerRound = new Map<Integer, Integer>{ 1 => 8, 2 => 4, 3 => 2, 4 => 1 };
        for (Integer round = 1; round <= 4; round++) {
            for (Integer r = 0; r < 4; r++) {
                for (Integer slot = 0; slot < gamesPerRound.get(round); slot++) {
                    ids.add(gameId(r, round, slot));
                }
            }
        }
        ids.add('FF-5-0');
        ids.add('FF-5-1');
        ids.add('FF-6-0');
        return ids;
    }

    public static String gameId(Integer regionIdx, Integer round, Integer slot) {
        return round <= 4 ? 'R' + regionIdx + '-' + round + '-' + slot : 'FF-' + round + '-' + slot;
    }

    public static Integer roundOf(String gameId) {
        return Integer.valueOf(gameId.split('-')[1]);
    }

    public static String nextGameId(String id) {
        List<String> parts = id.split('-');
        Integer round = Integer.valueOf(parts[1]);
        Integer slot = Integer.valueOf(parts[2]);
        if (round < 4) {
            Integer regionIdx = Integer.valueOf(parts[0].substring(1));
            return gameId(regionIdx, round + 1, slot / 2);
        }
        if (round == 4) {
            Integer regionIdx = Integer.valueOf(parts[0].substring(1));
            return gameId(null, 5, regionIdx / 2);
        }
        if (round == 5) {
            return 'FF-6-0';
        }
        return null;
    }

    /** Context about a tournament's field of teams. */
    public class Field {
        public List<String> regionOrder = new List<String>();
        public List<Integer> roundPoints = new List<Integer>();
        public Map<Id, Team__c> teamsById = new Map<Id, Team__c>();
        public Map<Id, List<String>> pathByTeam = new Map<Id, List<String>>();

        public Field(Tournament__c tournament, List<Team__c> teams) {
            regionOrder = parseRegions(tournament.Region_Order__c);
            roundPoints = parsePoints(tournament.Round_Points__c);
            Map<String, Integer> regionIndex = new Map<String, Integer>();
            for (Integer i = 0; i < regionOrder.size(); i++) {
                regionIndex.put(regionOrder[i].toLowerCase(), i);
            }
            for (Team__c team : teams) {
                teamsById.put(team.Id, team);
                Integer regionIdx = team.Region__c == null ? null : regionIndex.get(team.Region__c.trim().toLowerCase());
                pathByTeam.put(team.Id, pathOf(regionIdx, team.Seed__c));
            }
        }
    }

    public static List<String> parseRegions(String value) {
        List<String> regions = new List<String>();
        String source = String.isBlank(value) ? 'East,West,South,Midwest' : value;
        for (String region : source.split(',')) {
            if (String.isNotBlank(region)) {
                regions.add(region.trim());
            }
        }
        return regions;
    }

    public static List<Integer> parsePoints(String value) {
        if (String.isBlank(value)) {
            return DEFAULT_POINTS.clone();
        }
        List<Integer> points = new List<Integer>();
        for (String part : value.split(',')) {
            points.add(String.isBlank(part) ? 0 : Integer.valueOf(part.trim()));
        }
        while (points.size() < 6) {
            points.add(0);
        }
        return points;
    }

    public static List<String> pathOf(Integer regionIdx, Decimal seed) {
        List<String> path = new List<String>();
        if (regionIdx == null || seed == null) {
            return path;
        }
        Integer pos = SEED_ORDER.indexOf(seed.intValue());
        if (pos < 0) {
            return path;
        }
        String current = gameId(regionIdx, 1, pos / 2);
        while (current != null) {
            path.add(current);
            current = nextGameId(current);
        }
        return path;
    }

    public static Map<String, Id> parseWinners(String json) {
        Map<String, Id> winners = new Map<String, Id>();
        if (String.isBlank(json)) {
            return winners;
        }
        Map<String, Object> raw = (Map<String, Object>) System.JSON.deserializeUntyped(json);
        for (String key : raw.keySet()) {
            if (raw.get(key) != null) {
                winners.put(key, Id.valueOf(String.valueOf(raw.get(key))));
            }
        }
        return winners;
    }

    /**
     * Throws BracketException if `winners` is not a consistent bracket: every key must be a
     * real game, every team must belong to the tournament, sit on that game's path, and have
     * won the previous game on its path.
     */
    public static void validate(Map<String, Id> winners, Field field) {
        Set<String> validGames = new Set<String>(allGameIds());
        for (String gameId : winners.keySet()) {
            if (!validGames.contains(gameId)) {
                throw new BracketException('Unknown game: ' + gameId);
            }
            Id teamId = winners.get(gameId);
            if (!field.teamsById.containsKey(teamId)) {
                throw new BracketException('Team is not part of this tournament: ' + teamId);
            }
            List<String> path = field.pathByTeam.get(teamId);
            Integer idx = path.indexOf(gameId);
            if (idx < 0) {
                throw new BracketException(field.teamsById.get(teamId).Name + ' cannot play in game ' + gameId);
            }
            if (idx > 0 && winners.get(path[idx - 1]) != teamId) {
                throw new BracketException(
                    field.teamsById.get(teamId).Name + ' must win its previous game before advancing.'
                );
            }
        }
    }

    public class Score {
        public Integer score = 0;
        public Integer maxPossible = 0;
        public Integer correct = 0;
        public Integer pickCount = 0;
    }

    public static Set<Id> eliminatedTeams(Map<String, Id> results, Field field) {
        Set<Id> eliminated = new Set<Id>();
        for (Id teamId : field.pathByTeam.keySet()) {
            for (String gameId : field.pathByTeam.get(teamId)) {
                if (results.containsKey(gameId) && results.get(gameId) != teamId) {
                    eliminated.add(teamId);
                    break;
                }
            }
        }
        return eliminated;
    }

    public static Score score(Map<String, Id> picks, Map<String, Id> results, Field field) {
        return score(picks, results, field, eliminatedTeams(results, field));
    }

    public static Score score(Map<String, Id> picks, Map<String, Id> results, Field field, Set<Id> eliminated) {
        Score s = new Score();
        for (String gameId : picks.keySet()) {
            Id pick = picks.get(gameId);
            if (pick == null) {
                continue;
            }
            s.pickCount++;
            Integer points = field.roundPoints[roundOf(gameId) - 1];
            if (results.containsKey(gameId)) {
                if (results.get(gameId) == pick) {
                    s.score += points;
                    s.maxPossible += points;
                    s.correct++;
                }
            } else if (!eliminated.contains(pick)) {
                s.maxPossible += points;
            }
        }
        return s;
    }

    public static void applyScore(Bracket_Entry__c entry, Score s) {
        entry.Score__c = s.score;
        entry.Max_Possible__c = s.maxPossible;
        entry.Correct_Picks__c = s.correct;
        entry.Pick_Count__c = s.pickCount;
    }

    /** Re-scores every entry in a tournament. */
    public static void rescoreTournament(Id tournamentId) {
        Tournament__c tournament = [
            SELECT Id, Region_Order__c, Round_Points__c, Results__c
            FROM Tournament__c
            WHERE Id = :tournamentId
        ];
        Field field = new Field(tournament, [SELECT Id, Name, Seed__c, Region__c FROM Team__c WHERE Tournament__c = :tournamentId]);
        Map<String, Id> results = parseWinners(tournament.Results__c);
        Set<Id> eliminated = eliminatedTeams(results, field);
        List<Bracket_Entry__c> entries = [SELECT Id, Picks__c FROM Bracket_Entry__c WHERE Tournament__c = :tournamentId];
        for (Bracket_Entry__c entry : entries) {
            applyScore(entry, score(parseWinners(entry.Picks__c), results, field, eliminated));
        }
        update entries;
    }

    /** Saves an entry in system mode; callers are responsible for ownership and lock checks. */
    public static Bracket_Entry__c saveEntry(Bracket_Entry__c entry) {
        upsert entry;
        return entry;
    }

    public class BracketException extends Exception {
    }
}
