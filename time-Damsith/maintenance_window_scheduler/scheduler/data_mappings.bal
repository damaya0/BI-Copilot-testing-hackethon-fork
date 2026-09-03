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

# Maps a stored maintenance window into the calendar view, enriched with collision information.
#
# + maintenanceWindow - the stored maintenance window
# + collidingIds - the ids of other windows at the same site that collide with this one
# + return - the scheduled maintenance window view
function toScheduledMaintenanceWindow(MaintenanceWindow maintenanceWindow, string[] collidingIds) returns ScheduledMaintenanceWindow => {
    id: maintenanceWindow.id,
    site: maintenanceWindow.site,
    title: maintenanceWindow.title,
    localStart: maintenanceWindow.localStart,
    localEnd: maintenanceWindow.localEnd,
    timeZone: maintenanceWindow.timeZone,
    utcStart: time:utcToString(maintenanceWindow.utcStart),
    utcEnd: time:utcToString(maintenanceWindow.utcEnd),
    collides: collidingIds.length() > 0,
    collidesWith: collidingIds
};
