@IsTest
private class BracketControllerTest {
    private static final List<String> REGIONS = new List<String>{ 'East', 'West', 'South', 'Midwest' };

    @TestSetup
    static void setup() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>{
            makeUser('player1', standard.Id),
            makeUser('player2', standard.Id),
            makeUser('commish', standard.Id)
        };
        insert users;

        Map<String, Id> permSets = new Map<String, Id>();
        for (PermissionSet ps : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('Bracket_Player', 'Bracket_Commissioner')]) {
            permSets.put(ps.Name, ps.Id);
        }
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = users[0].Id, PermissionSetId = permSets.get('Bracket_Player')),
            new PermissionSetAssignment(AssigneeId = users[1].Id, PermissionSetId = permSets.get('Bracket_Player')),
            new PermissionSetAssignment(AssigneeId = users[2].Id, PermissionSetId = permSets.get('Bracket_Commissioner'))
        };

        System.runAs(new User(Id = UserInfo.getUserId())) {
            Tournament__c t = new Tournament__c(
                Name = 'Test Tournament',
                Year__c = 2027,
                Status__c = 'Open',
                Lock_Date__c = System.now().addDays(7),
                Region_Order__c = String.join(REGIONS, ','),
                Round_Points__c = '10,20,40,80,160,320'
            );
            insert t;
            List<Team__c> teams = new List<Team__c>();
            for (String region : REGIONS) {
                for (Integer seed = 1; seed <= 16; seed++) {
                    teams.add(new Team__c(Tournament__c = t.Id, Name = region + ' ' + seed, Seed__c = seed, Region__c = region));
                }
            }
            insert teams;
        }
    }

    private static User makeUser(String alias, Id profileId) {
        String unique = alias + System.currentTimeMillis() + Crypto.getRandomInteger();
        return new User(
            Alias = alias,
            Email = alias + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileId,
            TimeZoneSidKey = 'America/New_York',
            Username = unique.replace('-', '') + '@bracket.test'
        );
    }

    private static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias LIMIT 1];
    }

    private static Tournament__c tournament() {
        return [SELECT Id, Region_Order__c, Round_Points__c, Results__c, Status__c FROM Tournament__c LIMIT 1];
    }

    /** Builds a full bracket where the better seed (or upset seeds if `upsets`) always wins. */
    private static Map<String, Id> buildBracket(Boolean favoritesWin) {
        Tournament__c t = tournament();
        Map<String, Team__c> bySlot = new Map<String, Team__c>();
        List<String> regions = BracketScoringService.parseRegions(t.Region_Order__c);
        for (Team__c team : [SELECT Id, Seed__c, Region__c FROM Team__c]) {
            bySlot.put(String.valueOf(regions.indexOf(team.Region__c)) + '-' + team.Seed__c.intValue(), team);
        }
        Map<String, List<Team__c>> participants = new Map<String, List<Team__c>>();
        Map<String, Id> winners = new Map<String, Id>();
        for (String gameId : BracketScoringService.allGameIds()) {
            List<Team__c> playing;
            if (BracketScoringService.roundOf(gameId) == 1) {
                Integer regionIdx = Integer.valueOf(gameId.split('-')[0].substring(1));
                Integer slot = Integer.valueOf(gameId.split('-')[2]);
                playing = new List<Team__c>{
                    bySlot.get(String.valueOf(regionIdx) + '-' + BracketScoringService.SEED_ORDER[slot * 2]),
                    bySlot.get(String.valueOf(regionIdx) + '-' + BracketScoringService.SEED_ORDER[slot * 2 + 1])
                };
            } else {
                playing = participants.get(gameId);
            }
            Boolean firstIsBetter = playing[0].Seed__c <= playing[1].Seed__c;
            Team__c winner = (firstIsBetter == favoritesWin) ? playing[0] : playing[1];
            winners.put(gameId, winner.Id);
            String next = BracketScoringService.nextGameId(gameId);
            if (next != null) {
                if (!participants.containsKey(next)) {
                    participants.put(next, new List<Team__c>());
                }
                participants.get(next).add(winner);
            }
        }
        return winners;
    }

    @IsTest
    static void playerCanSaveAFullBracket() {
        Tournament__c t = tournament();
        Map<String, Id> picks = buildBracket(true);

        System.runAs(user('player1')) {
            Test.startTest();
            BracketController.BracketData before = BracketController.getBracketData(null, null, 'Picks');
            Assert.areEqual(t.Id, before.tournamentId, 'Most recent tournament is used by default');
            Assert.areEqual(64, before.teams.size());
            Assert.isNull(before.entry, 'No entry yet');
            Assert.isTrue(before.canEdit);
            Assert.isFalse(before.isCommissioner);

            BracketController.EntryInfo saved = BracketController.savePicks(t.Id, JSON.serialize(picks), 142, 'Chalk City');
            Test.stopTest();

            Assert.areEqual('Chalk City', saved.name);
            Assert.areEqual(63, saved.picks.size());
            Assert.areEqual(142, saved.tiebreaker);
            Assert.isTrue(saved.isMine);
        }
        Bracket_Entry__c entry = [SELECT Pick_Count__c, Champion__r.Name, Max_Possible__c, Is_Complete__c FROM Bracket_Entry__c];
        Assert.areEqual(63, entry.Pick_Count__c.intValue());
        Assert.isTrue(entry.Is_Complete__c);
        Assert.areEqual('East 1', entry.Champion__r.Name);
        Assert.areEqual(1920, entry.Max_Possible__c.intValue(), '32*10 + 16*20 + 8*40 + 4*80 + 2*160 + 320');
    }

    @IsTest
    static void savingAgainUpdatesTheSameEntry() {
        Tournament__c t = tournament();
        System.runAs(user('player1')) {
            BracketController.savePicks(t.Id, '{}', null, null);
            BracketController.savePicks(t.Id, JSON.serialize(buildBracket(false)), 120, null);
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Bracket_Entry__c]);
    }

    @IsTest
    static void invalidAdvancementIsRejected() {
        Tournament__c t = tournament();
        Team__c sixteen = [SELECT Id FROM Team__c WHERE Region__c = 'East' AND Seed__c = 16];
        // The 16 seed is advanced to the Round of 32 without winning its first game.
        Map<String, Id> picks = new Map<String, Id>{ 'R0-2-0' => sixteen.Id };
        System.runAs(user('player1')) {
            try {
                BracketController.savePicks(t.Id, JSON.serialize(picks), null, null);
                Assert.fail('Expected an exception');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('previous game'), e.getMessage());
            }
        }
    }

    @IsTest
    static void wrongGameIsRejected() {
        Tournament__c t = tournament();
        Team__c oneSeed = [SELECT Id FROM Team__c WHERE Region__c = 'East' AND Seed__c = 1];
        System.runAs(user('player1')) {
            try {
                BracketController.savePicks(t.Id, JSON.serialize(new Map<String, Id>{ 'R1-1-0' => oneSeed.Id }), null, null);
                Assert.fail('Expected an exception');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('cannot play'), e.getMessage());
            }
        }
    }

    @IsTest
    static void picksAreRejectedAfterLock() {
        Tournament__c t = tournament();
        t.Lock_Date__c = System.now().addMinutes(-1);
        update t;
        System.runAs(user('player1')) {
            BracketController.BracketData data = BracketController.getBracketData(t.Id, null, 'Picks');
            Assert.isTrue(data.isLocked);
            Assert.isFalse(data.canEdit);
            try {
                BracketController.savePicks(t.Id, '{}', null, null);
                Assert.fail('Expected an exception');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('locked'), e.getMessage());
            }
        }
    }

    @IsTest
    static void otherBracketsHiddenUntilLock() {
        Tournament__c t = tournament();
        Id entryId;
        System.runAs(user('player1')) {
            entryId = BracketController.savePicks(t.Id, JSON.serialize(buildBracket(true)), 150, null).id;
        }
        System.runAs(user('player2')) {
            try {
                BracketController.getBracketData(t.Id, entryId, 'Picks');
                Assert.fail('Expected an exception');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('hidden'), e.getMessage());
            }
        }
        t.Status__c = 'Locked';
        update t;
        System.runAs(user('player2')) {
            BracketController.BracketData data = BracketController.getBracketData(t.Id, entryId, 'Picks');
            Assert.areEqual(63, data.entry.picks.size());
            Assert.isFalse(data.entry.isMine);
            Assert.isFalse(data.canEdit);
        }
    }

    @IsTest
    static void commissionerResultsRescoreAndRankLeaderboard() {
        Tournament__c t = tournament();
        Map<String, Id> favorites = buildBracket(true);
        Map<String, Id> underdogs = buildBracket(false);
        System.runAs(user('player1')) {
            BracketController.savePicks(t.Id, JSON.serialize(favorites), 140, 'Favorites');
        }
        System.runAs(user('player2')) {
            BracketController.savePicks(t.Id, JSON.serialize(underdogs), 150, 'Underdogs');
        }

        // Favorites win every Round of 64 game in the East region.
        Map<String, Id> results = new Map<String, Id>();
        for (Integer slot = 0; slot < 8; slot++) {
            String gameId = 'R0-1-' + slot;
            results.put(gameId, favorites.get(gameId));
        }

        System.runAs(user('commish')) {
            Test.startTest();
            BracketController.BracketData data = BracketController.getBracketData(t.Id, null, 'Results');
            Assert.isTrue(data.isCommissioner);
            Assert.isTrue(data.canEdit);
            BracketController.saveResults(t.Id, JSON.serialize(results), null);
            Test.stopTest();
        }

        Assert.areEqual('Locked', [SELECT Status__c FROM Tournament__c].Status__c, 'Entering results locks the pool');
        Map<String, Bracket_Entry__c> entries = new Map<String, Bracket_Entry__c>();
        for (Bracket_Entry__c e : [SELECT Name, Score__c, Correct_Picks__c, Max_Possible__c FROM Bracket_Entry__c]) {
            entries.put(e.Name, e);
        }
        Assert.areEqual(80, entries.get('Favorites').Score__c.intValue());
        Assert.areEqual(8, entries.get('Favorites').Correct_Picks__c.intValue());
        Assert.areEqual(1920, entries.get('Favorites').Max_Possible__c.intValue());
        Assert.areEqual(0, entries.get('Underdogs').Score__c.intValue());
        Assert.isTrue(entries.get('Underdogs').Max_Possible__c.intValue() < 1920, 'Eliminated East teams reduce max possible');

        System.runAs(user('player2')) {
            List<BracketController.LeaderboardRow> rows = BracketController.getLeaderboard(t.Id);
            Assert.areEqual(2, rows.size());
            Assert.areEqual('Favorites', rows[0].entryName);
            Assert.areEqual(1, rows[0].rank);
            Assert.areEqual(2, rows[1].rank);
            Assert.isTrue(rows[1].isMine);
            Assert.isTrue(rows[0].championAlive);
        }
    }

    @IsTest
    static void championshipCompletesTournamentAndBreaksTies() {
        Tournament__c t = tournament();
        Map<String, Id> favorites = buildBracket(true);
        System.runAs(user('player1')) {
            BracketController.savePicks(t.Id, JSON.serialize(favorites), 140, 'Close Guess');
        }
        System.runAs(user('player2')) {
            BracketController.savePicks(t.Id, JSON.serialize(favorites), 100, 'Far Guess');
        }
        System.runAs(user('commish')) {
            BracketController.saveResults(t.Id, JSON.serialize(favorites), 138);
        }
        Assert.areEqual('Complete', [SELECT Status__c FROM Tournament__c].Status__c);
        List<BracketController.LeaderboardRow> rows = BracketController.getLeaderboard(t.Id);
        Assert.areEqual('Close Guess', rows[0].entryName);
        Assert.areEqual(1920, rows[0].score);
        Assert.areEqual(2, rows[1].rank, 'Tiebreaker separates equal scores');
    }

    @IsTest
    static void playersCannotEnterResults() {
        Tournament__c t = tournament();
        System.runAs(user('player1')) {
            BracketController.BracketData data = BracketController.getBracketData(t.Id, null, 'Results');
            Assert.isFalse(data.canEdit);
            try {
                BracketController.saveResults(t.Id, '{}', null);
                Assert.fail('Expected an exception');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('commissioner'), e.getMessage());
            }
        }
    }

    @IsTest
    static void missingTournamentGivesFriendlyError() {
        delete [SELECT Id FROM Team__c];
        delete [SELECT Id FROM Tournament__c];
        try {
            BracketController.getBracketData(null, null, 'Picks');
            Assert.fail('Expected an exception');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('No tournament'), e.getMessage());
        }
    }

    @IsTest
    static void pointsParsingPadsMissingRounds() {
        List<Integer> points = BracketScoringService.parsePoints('1, 2,3');
        Assert.areEqual(new List<Integer>{ 1, 2, 3, 0, 0, 0 }, points);
        Assert.areEqual(BracketScoringService.DEFAULT_POINTS, BracketScoringService.parsePoints(null));
        Assert.areEqual(4, BracketScoringService.parseRegions(' East, West ,South,Midwest ').size());
    }
}
