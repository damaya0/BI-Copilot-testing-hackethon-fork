import ballerina/time;

# In-memory store of maintenance windows, keyed by generated id.
final map<MaintenanceWindow> maintenanceWindowStore = {};

# Monotonically increasing counter used to generate unique maintenance window ids.
int nextMaintenanceWindowId = 1;

# Resolves the `time:Zone` for a given site.
#
# + site - the datacenter site
# + return - the corresponding time zone, or an error if the zone cannot be resolved
function getSiteZone(Site site) returns time:Zone|error {
    string zoneId = siteTimeZones.get(site);
    time:Zone? zone = time:getZone(zoneId);
    if zone is () {
        return error("Unable to resolve time zone for site: " + site.toString());
    }
    return zone;
}

# Converts a local wall-clock date and time at a given site into the corresponding UTC instant.
#
# + site - the datacenter site the local time belongs to
# + localDateTime - the local wall-clock date and time
# + return - the resolved UTC instant, or an error if the conversion fails
function toUtc(Site site, LocalDateTime localDateTime) returns time:Utc|error {
    time:Zone zone = check getSiteZone(site);
    time:Civil civil = {
        year: localDateTime.year,
        month: localDateTime.month,
        day: localDateTime.day,
        hour: localDateTime.hour,
        minute: localDateTime.minute,
        second: 0
    };
    return zone.utcFromCivil(civil);
}

# Checks whether the given local start and end times are in the correct order.
#
# + utcStart - the resolved UTC start instant
# + utcEnd - the resolved UTC end instant
# + return - true if the start is strictly before the end
function isChronological(time:Utc utcStart, time:Utc utcEnd) returns boolean {
    return time:utcDiffSeconds(utcEnd, utcStart) > 0d;
}

# Checks whether two maintenance windows overlap in time.
#
# + firstWindow - the first maintenance window
# + secondWindow - the second maintenance window
# + return - true if the two windows overlap
function windowsOverlap(MaintenanceWindow firstWindow, MaintenanceWindow secondWindow) returns boolean {
    boolean startsBeforeOtherEnds = time:utcDiffSeconds(secondWindow.utcEnd, firstWindow.utcStart) > 0d;
    boolean endsAfterOtherStarts = time:utcDiffSeconds(firstWindow.utcEnd, secondWindow.utcStart) > 0d;
    return startsBeforeOtherEnds && endsAfterOtherStarts;
}

# Checks whether a maintenance window's period intersects with a given query period.
#
# + maintenanceWindow - the maintenance window
# + periodStart - the start of the query period
# + periodEnd - the end of the query period
# + return - true if the window falls within, or overlaps, the given period
function isWithinPeriod(MaintenanceWindow maintenanceWindow, time:Utc periodStart, time:Utc periodEnd) returns boolean {
    boolean startsBeforePeriodEnds = time:utcDiffSeconds(periodEnd, maintenanceWindow.utcStart) > 0d;
    boolean endsAfterPeriodStarts = time:utcDiffSeconds(maintenanceWindow.utcEnd, periodStart) > 0d;
    return startsBeforePeriodEnds && endsAfterPeriodStarts;
}

# Generates the next unique maintenance window id.
#
# + return - a freshly generated id
function generateMaintenanceWindowId() returns string {
    string generatedId = "mw-" + nextMaintenanceWindowId.toString();
    nextMaintenanceWindowId += 1;
    return generatedId;
}
