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

# The maintenance window representation returned to API clients, rendered in
# the site's own local time (as customers expect to see it) alongside the
# resolved UTC instants for systems that work off the single global timeline.
public type MaintenanceWindowView record {|
    string id;
    Site site;
    string title;
    LocalDateTime localStart;
    LocalDateTime localEnd;
    string timeZone;
    string utcStart;
    string utcEnd;
|};

# The day of the week a standing maintenance slot runs on.
public enum Weekday {
    SUNDAY = "SUNDAY",
    MONDAY = "MONDAY",
    TUESDAY = "TUESDAY",
    WEDNESDAY = "WEDNESDAY",
    THURSDAY = "THURSDAY",
    FRIDAY = "FRIDAY",
    SATURDAY = "SATURDAY"
}

# Maps each weekday to its `time:DayOfWeek` numeric value (0 = Sunday .. 6 = Saturday).
public final map<int> & readonly weekdayNumbers = {
    [SUNDAY]: 0,
    [MONDAY]: 1,
    [TUESDAY]: 2,
    [WEDNESDAY]: 3,
    [THURSDAY]: 4,
    [FRIDAY]: 5,
    [SATURDAY]: 6
};

# Which occurrence of a weekday within the month a standing maintenance slot runs on.
public enum WeekOfMonth {
    FIRST = "FIRST",
    SECOND = "SECOND",
    THIRD = "THIRD",
    FOURTH = "FOURTH",
    LAST = "LAST"
}

# A wall-clock time of day, with no date attached.
public type TimeOfDay record {|
    int hour;
    int minute;
|};

# A standing maintenance slot, as a site's operations team would describe it: for
# example "the last Sunday of every month, 02:00 to 03:00 local". If the end time
# is not after the start time, the slot is understood to run past midnight and end
# on the following day.
public type RecurringWindowInput record {|
    Site site;
    string title;
    WeekOfMonth weekOfMonth;
    Weekday dayOfWeek;
    TimeOfDay localStartTime;
    TimeOfDay localEndTime;
|};

# A stored standing maintenance slot.
public type RecurringWindow record {|
    string id;
    Site site;
    string title;
    WeekOfMonth weekOfMonth;
    Weekday dayOfWeek;
    TimeOfDay localStartTime;
    TimeOfDay localEndTime;
    string timeZone;
|};

# A single concrete occurrence of a maintenance window within a requested period -
# either a one-off window or one instance of an expanded standing slot. Keeps the
# local representation for rendering back to customers, the resolved UTC instants
# for the global timeline, the actual elapsed duration on that timeline (used to
# bill contractor call-out hours), and same-site collision information.
public type MaintenanceOccurrence record {|
    string id;
    string? recurringWindowId;
    Site site;
    string title;
    LocalDateTime localStart;
    LocalDateTime localEnd;
    string timeZone;
    string utcStart;
    string utcEnd;
    decimal actualDurationMinutes;
    boolean collides;
    string[] collidesWith;
|};
