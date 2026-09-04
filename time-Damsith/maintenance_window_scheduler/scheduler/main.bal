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
        map<string?> sourcePhaseLabels = {};
        MaintenanceWindow[] allOccurrences = [];
        foreach MaintenanceWindow oneOffWindow in oneOffWindows {
            sourceRecurringWindowIds[oneOffWindow.id] = ();
            sourcePhaseLabels[oneOffWindow.id] = ();
            allOccurrences.push(oneOffWindow);
        }

        foreach RecurringWindow recurringWindow in recurringWindowStore {
            RecurringPhaseOccurrence[]|error expandedPhases = expandRecurringWindow(recurringWindow, periodStart, periodEnd);
            if expandedPhases is RecurringPhaseOccurrence[] {
                foreach RecurringPhaseOccurrence phaseOccurrence in expandedPhases {
                    MaintenanceWindow phaseWindow = phaseOccurrence.phaseWindow;
                    sourceRecurringWindowIds[phaseWindow.id] = recurringWindow.id;
                    sourcePhaseLabels[phaseWindow.id] = phaseOccurrence.phaseLabel;
                    allOccurrences.push(phaseWindow);
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
            string? phaseLabel = sourcePhaseLabels[currentOccurrence.id];
            scheduledOccurrences.push(toMaintenanceOccurrence(currentOccurrence, recurringWindowId, phaseLabel, collidingIds));
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
        if newRecurringWindow.phases.length() == 0 {
            return <http:BadRequest>{body: "A standing maintenance slot must have at least one crew phase."};
        }

        string zoneId = siteTimeZones.get(newRecurringWindow.site);
        string generatedId = generateRecurringWindowId();
        RecurringWindow storedRecurringWindow = toRecurringWindow(newRecurringWindow, generatedId, zoneId);

        foreach RecurringPhase phase in storedRecurringWindow.phases {
            [LocalDateTime, LocalDateTime]|error samplePhase = buildPhaseLocalDateTimes(storedRecurringWindow, phase, 2026, 1);
            if samplePhase is error {
                return <http:BadRequest>{body: "Invalid recurrence rule: " + samplePhase.message()};
            }
        }

        MaintenanceWindow[]|error samplePhaseWindows = phaseWindowsForMonth(storedRecurringWindow, 2026, 1);
        if samplePhaseWindows is error {
            return <http:BadRequest>{body: "Invalid recurrence rule: " + samplePhaseWindows.message()};
        }
        if hasOverlappingPhases(samplePhaseWindows) {
            return <http:BadRequest>{body: "A standing slot's crew phases must never overlap each other."};
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

    # Provides the finance reconciliation view for every standing slot occurrence within the
    # given period: each crew phase alongside the whole slot's own actual duration, so the
    # phases can be checked against the slot end to end.
    #
    # + 'from - the start of the period, as an RFC 3339 UTC timestamp
    # + to - the end of the period, as an RFC 3339 UTC timestamp
    # + return - the reconciliation view for each occurrence in chronological order, or a bad request if the period is invalid
    resource function get reconciliation(string 'from, string to) returns SlotReconciliation[]|http:BadRequest {
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

        SlotReconciliation[] reconciliations = [];
        foreach RecurringWindow recurringWindow in recurringWindowStore {
            RecurringPhaseOccurrence[]|error expandedPhases = expandRecurringWindow(recurringWindow, periodStart, periodEnd);
            if expandedPhases is error {
                continue;
            }

            map<MaintenanceWindow[]> phasesByOccurrenceGroup = {};
            foreach RecurringPhaseOccurrence phaseOccurrence in expandedPhases {
                string groupId = phaseOccurrence.occurrenceGroupId;
                MaintenanceWindow[]? existingGroup = phasesByOccurrenceGroup[groupId];
                MaintenanceWindow[] groupPhases = existingGroup is MaintenanceWindow[] ? existingGroup : [];
                groupPhases.push(phaseOccurrence.phaseWindow);
                phasesByOccurrenceGroup[groupId] = groupPhases;
            }

            foreach MaintenanceWindow[] groupPhases in phasesByOccurrenceGroup {
                SlotReconciliation reconciliation = buildSlotReconciliation(recurringWindow, groupPhases);
                string[] emptyCollisionList = [];
                MaintenanceOccurrence[] phaseViews = from MaintenanceWindow phaseWindow in groupPhases
                    order by phaseWindow.utcStart ascending
                    select toMaintenanceOccurrence(phaseWindow, recurringWindow.id, phaseWindow.title, emptyCollisionList);
                reconciliation.phases = phaseViews;
                reconciliations.push(reconciliation);
            }
        }

        SlotReconciliation[] sortedReconciliations = from SlotReconciliation reconciliation in reconciliations
            order by reconciliation.phases[0].utcStart ascending
            select reconciliation;
        return sortedReconciliations;
    }
}
