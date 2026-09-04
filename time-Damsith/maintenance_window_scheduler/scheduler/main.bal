import ballerina/http;
import ballerina/time;

listener http:Listener maintenanceWindowListener = new (servicePort);

service /maintenance\-windows on maintenanceWindowListener {

    # Registers a maintenance window using the site operations team's own local wall-clock time.
    #
    # + newWindow - the maintenance window as written down by the site's operations team
    # + return - the stored maintenance window, or a bad request if the input is invalid
    resource function post .(MaintenanceWindowInput newWindow) returns MaintenanceWindowView|http:BadRequest {
        time:Utc|error utcStart = toUtc(newWindow.site, newWindow.localStart);
        time:Utc|error utcEnd = toUtc(newWindow.site, newWindow.localEnd);
        if utcStart is error {
            return <http:BadRequest>{body: "Invalid local start time: " + utcStart.message()};
        }
        if utcEnd is error {
            return <http:BadRequest>{body: "Invalid local end time: " + utcEnd.message()};
        }
        if !isChronological(utcStart, utcEnd) {
            return <http:BadRequest>{body: "The maintenance window's end time must be after its start time."};
        }

        string zoneId = siteTimeZones.get(newWindow.site);
        string generatedId = generateMaintenanceWindowId();
        MaintenanceWindow storedWindow = toMaintenanceWindow(newWindow, generatedId, zoneId, utcStart, utcEnd);
        maintenanceWindowStore[generatedId] = storedWindow;
        return toMaintenanceWindowView(storedWindow);
    }

    # Lists maintenance window occurrences that fall within the given period, in chronological
    # order. Includes both one-off windows and the concrete occurrences of every standing slot
    # that intersect the period, flagging any occurrences at the same site that collide with
    # each other.
    #
    # + 'from - the start of the period, as an RFC 3339 UTC timestamp
    # + to - the end of the period, as an RFC 3339 UTC timestamp
    # + return - the matching occurrences in chronological order, or a bad request if the period is invalid
    resource function get .(string 'from, string to) returns MaintenanceOccurrence[]|http:BadRequest {
        time:Utc|error periodStart = time:utcFromString('from);
        time:Utc|error periodEnd = time:utcFromString(to);
        if periodStart is error {
            return <http:BadRequest>{body: "Invalid 'from' timestamp: " + periodStart.message()};
        }
        if periodEnd is error {
            return <http:BadRequest>{body: "Invalid 'to' timestamp: " + periodEnd.message()};
        }
        if !isChronological(periodStart, periodEnd) {
            return <http:BadRequest>{body: "The 'to' timestamp must be after the 'from' timestamp."};
        }

        MaintenanceWindow[] oneOffWindows = from MaintenanceWindow candidateWindow in maintenanceWindowStore
            where isWithinPeriod(candidateWindow, periodStart, periodEnd)
            select candidateWindow;

        map<string?> sourceRecurringWindowIds = {};
        MaintenanceWindow[] allOccurrences = [];
        foreach MaintenanceWindow oneOffWindow in oneOffWindows {
            sourceRecurringWindowIds[oneOffWindow.id] = ();
            allOccurrences.push(oneOffWindow);
        }

        foreach RecurringWindow recurringWindow in recurringWindowStore {
            MaintenanceWindow[]|error expandedOccurrences = expandRecurringWindow(recurringWindow, periodStart, periodEnd);
            if expandedOccurrences is MaintenanceWindow[] {
                foreach MaintenanceWindow occurrence in expandedOccurrences {
                    sourceRecurringWindowIds[occurrence.id] = recurringWindow.id;
                    allOccurrences.push(occurrence);
                }
            }
        }

        MaintenanceWindow[] sortedOccurrences = from MaintenanceWindow occurrence in allOccurrences
            order by occurrence.utcStart ascending
            select occurrence;

        MaintenanceOccurrence[] scheduledOccurrences = [];
        foreach MaintenanceWindow currentOccurrence in sortedOccurrences {
            string[] collidingIds = from MaintenanceWindow otherOccurrence in allOccurrences
                where otherOccurrence.id != currentOccurrence.id
                where otherOccurrence.site == currentOccurrence.site
                where windowsOverlap(currentOccurrence, otherOccurrence)
                select otherOccurrence.id;
            string? recurringWindowId = sourceRecurringWindowIds[currentOccurrence.id];
            scheduledOccurrences.push(toMaintenanceOccurrence(currentOccurrence, recurringWindowId, collidingIds));
        }
        return scheduledOccurrences;
    }
}

service /recurring\-maintenance\-windows on maintenanceWindowListener {

    # Registers a standing maintenance slot that repeats every month, using the site operations
    # team's own local wall-clock time.
    #
    # + newRecurringWindow - the standing slot as written down by the site's operations team
    # + return - the stored standing slot, or a bad request if the input is invalid
    resource function post .(RecurringWindowInput newRecurringWindow) returns RecurringWindow|http:BadRequest {
        string zoneId = siteTimeZones.get(newRecurringWindow.site);
        string generatedId = generateRecurringWindowId();
        RecurringWindow storedRecurringWindow = toRecurringWindow(newRecurringWindow, generatedId, zoneId);

        [LocalDateTime, LocalDateTime]|error sampleOccurrence = buildOccurrenceLocalDateTimes(storedRecurringWindow, 2026, 1);
        if sampleOccurrence is error {
            return <http:BadRequest>{body: "Invalid recurrence rule: " + sampleOccurrence.message()};
        }

        recurringWindowStore[generatedId] = storedRecurringWindow;
        return storedRecurringWindow;
    }

    # Lists all registered standing maintenance slots.
    #
    # + return - the registered standing slots
    resource function get .() returns RecurringWindow[] {
        return recurringWindowStore.toArray();
    }
}
