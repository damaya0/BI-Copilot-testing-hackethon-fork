import ballerina/http;
import ballerina/time;

listener http:Listener maintenanceWindowListener = new (servicePort);

service /maintenance\-windows on maintenanceWindowListener {

    # Registers a maintenance window using the site operations team's own local wall-clock time.
    #
    # + newWindow - the maintenance window as written down by the site's operations team
    # + return - the stored maintenance window, or a bad request if the input is invalid
    resource function post .(MaintenanceWindowInput newWindow) returns MaintenanceWindow|http:BadRequest {
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
        return storedWindow;
    }

    # Lists maintenance windows that fall within the given period, in chronological order,
    # flagging any windows at the same site that collide with each other.
    #
    # + 'from - the start of the period, as an RFC 3339 UTC timestamp
    # + to - the end of the period, as an RFC 3339 UTC timestamp
    # + return - the matching windows in chronological order, or a bad request if the period is invalid
    resource function get .(string 'from, string to) returns ScheduledMaintenanceWindow[]|http:BadRequest {
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

        MaintenanceWindow[] matchingWindows = from MaintenanceWindow candidateWindow in maintenanceWindowStore
            where isWithinPeriod(candidateWindow, periodStart, periodEnd)
            order by candidateWindow.utcStart ascending
            select candidateWindow;

        ScheduledMaintenanceWindow[] scheduledWindows = [];
        foreach MaintenanceWindow currentWindow in matchingWindows {
            string[] collidingIds = from MaintenanceWindow otherWindow in maintenanceWindowStore
                where otherWindow.id != currentWindow.id
                where otherWindow.site == currentWindow.site
                where windowsOverlap(currentWindow, otherWindow)
                select otherWindow.id;
            scheduledWindows.push(toScheduledMaintenanceWindow(currentWindow, collidingIds));
        }
        return scheduledWindows;
    }
}
