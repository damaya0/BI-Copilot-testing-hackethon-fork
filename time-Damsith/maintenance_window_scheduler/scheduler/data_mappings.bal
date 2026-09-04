import ballerina/time;

# Maps a maintenance window input, together with its resolved UTC instants and time zone,
# into the stored maintenance window representation.
#
# + windowInput - the maintenance window as submitted by the site's operations team
# + generatedId - the generated unique id for this maintenance window
# + zoneId - the IANA time zone id of the site
# + utcStart - the resolved UTC start instant
# + utcEnd - the resolved UTC end instant
# + return - the stored maintenance window
function toMaintenanceWindow(MaintenanceWindowInput windowInput, string generatedId, string zoneId, time:Utc utcStart, time:Utc utcEnd) returns MaintenanceWindow => {
    id: generatedId,
    site: windowInput.site,
    title: windowInput.title,
    localStart: windowInput.localStart,
    localEnd: windowInput.localEnd,
    timeZone: zoneId,
    utcStart: utcStart,
    utcEnd: utcEnd
};

# Maps a stored maintenance window into the API response view, rendering the
# UTC instants as RFC 3339 strings.
#
# + maintenanceWindow - the stored maintenance window
# + return - the maintenance window view
function toMaintenanceWindowView(MaintenanceWindow maintenanceWindow) returns MaintenanceWindowView => {
    id: maintenanceWindow.id,
    site: maintenanceWindow.site,
    title: maintenanceWindow.title,
    localStart: maintenanceWindow.localStart,
    localEnd: maintenanceWindow.localEnd,
    timeZone: maintenanceWindow.timeZone,
    utcStart: time:utcToString(maintenanceWindow.utcStart),
    utcEnd: time:utcToString(maintenanceWindow.utcEnd)
};

# Maps a recurring window input, together with its resolved time zone, into the stored
# standing maintenance slot representation.
#
# + recurringWindowInput - the standing slot as submitted by the site's operations team
# + generatedId - the generated unique id for this standing slot
# + zoneId - the IANA time zone id of the site
# + return - the stored standing maintenance slot
function toRecurringWindow(RecurringWindowInput recurringWindowInput, string generatedId, string zoneId) returns RecurringWindow => {
    id: generatedId,
    site: recurringWindowInput.site,
    title: recurringWindowInput.title,
    weekOfMonth: recurringWindowInput.weekOfMonth,
    dayOfWeek: recurringWindowInput.dayOfWeek,
    phases: recurringWindowInput.phases,
    timeZone: zoneId
};

# Maps a maintenance window occurrence (either one-off or an expanded standing slot crew
# phase) into the calendar view, enriched with its actual billable duration and collision
# information.
#
# + maintenanceWindow - the maintenance window occurrence
# + recurringWindowId - the id of the standing slot this occurrence belongs to, or nil for a one-off window
# + phaseLabel - the label of the crew phase this occurrence represents, or nil for a one-off window
# + collidingIds - the ids of other occurrences at the same site that collide with this one
# + return - the maintenance occurrence view
function toMaintenanceOccurrence(MaintenanceWindow maintenanceWindow, string? recurringWindowId, string? phaseLabel, string[] collidingIds) returns MaintenanceOccurrence => {
    id: maintenanceWindow.id,
    recurringWindowId,
    phaseLabel,
    site: maintenanceWindow.site,
    title: maintenanceWindow.title,
    localStart: maintenanceWindow.localStart,
    localEnd: maintenanceWindow.localEnd,
    timeZone: maintenanceWindow.timeZone,
    utcStart: time:utcToString(maintenanceWindow.utcStart),
    utcEnd: time:utcToString(maintenanceWindow.utcEnd),
    actualDurationMinutes: actualDurationMinutes(maintenanceWindow),
    collides: collidingIds.length() > 0,
    collidesWith: collidingIds
};
