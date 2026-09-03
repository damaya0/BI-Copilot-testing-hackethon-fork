import ballerina/time;

# The datacenter sites that this scheduler manages maintenance windows for.
public enum Site {
    FRANKFURT = "FRANKFURT",
    SYDNEY = "SYDNEY",
    SAO_PAULO = "SAO_PAULO"
}

# Maps each site to the IANA time zone identifier that its operations team uses
# when writing down maintenance windows.
public final map<string> & readonly siteTimeZones = {
    [FRANKFURT]: "Europe/Berlin",
    [SYDNEY]: "Australia/Sydney",
    [SAO_PAULO]: "America/Sao_Paulo"
};

# A wall-clock date and time, as an operations team would write it down on a
# spreadsheet, with no time zone attached (the site implies the zone).
public type LocalDateTime record {|
    int year;
    int month;
    int day;
    int hour;
    int minute;
|};

# The maintenance window payload as submitted by a site's operations team.
public type MaintenanceWindowInput record {|
    Site site;
    string title;
    LocalDateTime localStart;
    LocalDateTime localEnd;
|};

# A stored maintenance window. Keeps both the original local representation
# (so it can be rendered back to customers exactly the way they expect) and
# the resolved UTC instants (so the global change calendar and paging system
# can reason about a single timeline).
public type MaintenanceWindow record {|
    string id;
    Site site;
    string title;
    LocalDateTime localStart;
    LocalDateTime localEnd;
    string timeZone;
    time:Utc utcStart;
    time:Utc utcEnd;
|};

# A maintenance window enriched with chronological ordering and collision
# information, as returned to the change calendar.
public type ScheduledMaintenanceWindow record {|
    string id;
    Site site;
    string title;
    LocalDateTime localStart;
    LocalDateTime localEnd;
    string timeZone;
    string utcStart;
    string utcEnd;
    boolean collides;
    string[] collidesWith;
|};
