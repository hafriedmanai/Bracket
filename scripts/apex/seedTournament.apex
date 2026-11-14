// Creates a sample tournament with 64 teams so you can try the bracket right away.
// Run with:  sf apex run --file scripts/apex/seedTournament.apex
// The teams and seeds below are SAMPLE DATA, not a real field. Replace them on Selection Sunday.

Map<String, List<String>> field = new Map<String, List<String>>{
    'East' => new List<String>{
        'Duke', 'Alabama', 'Wisconsin', 'Arizona', 'Oregon', 'BYU', 'Saint Mary\'s', 'Mississippi State',
        'Baylor', 'Vanderbilt', 'VCU', 'Liberty', 'Akron', 'Montana', 'Robert Morris', 'American'
    },
    'West' => new List<String>{
        'Florida', 'St. John\'s', 'Texas Tech', 'Maryland', 'Memphis', 'Missouri', 'Kansas', 'UConn',
        'Oklahoma', 'Arkansas', 'Drake', 'Colorado State', 'Grand Canyon', 'UNC Wilmington', 'Omaha', 'Norfolk State'
    },
    'South' => new List<String>{
        'Auburn', 'Michigan State', 'Iowa State', 'Texas A&M', 'Michigan', 'Ole Miss', 'Marquette', 'Louisville',
        'Creighton', 'New Mexico', 'North Carolina', 'UC San Diego', 'Yale', 'Lipscomb', 'Bryant', 'Alabama State'
    },
    'Midwest' => new List<String>{
        'Houston', 'Tennessee', 'Kentucky', 'Purdue', 'Clemson', 'Illinois', 'UCLA', 'Gonzaga',
        'Georgia', 'Utah State', 'Xavier', 'McNeese', 'High Point', 'Troy', 'Wofford', 'SIU Edwardsville'
    }
};

Tournament__c t = new Tournament__c(
    Name = 'Sample Bracket Pool',
    Year__c = System.today().year(),
    Status__c = 'Open',
    Lock_Date__c = System.now().addDays(7),
    Region_Order__c = 'East,West,South,Midwest',
    Round_Points__c = '10,20,40,80,160,320'
);
insert t;

List<Team__c> teams = new List<Team__c>();
for (String region : field.keySet()) {
    List<String> names = field.get(region);
    for (Integer i = 0; i < names.size(); i++) {
        teams.add(new Team__c(Tournament__c = t.Id, Name = names[i], Seed__c = i + 1, Region__c = region));
    }
}
insert teams;
System.debug('Created tournament ' + t.Id + ' with ' + teams.size() + ' teams.');
