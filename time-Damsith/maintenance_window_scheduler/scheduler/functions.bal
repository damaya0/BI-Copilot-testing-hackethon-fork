import ballerina/time;

# In-memory store of maintenance windows, keyed by generated id.
final map<MaintenanceWindow> maintenanceWindowStore = {};

# Monotonically increasing counter used to generate unique maintenance window ids.
int nextMaintenanceWindowId = 1;

# In-memory store of standing maintenance slots, keyed by generated id.
final map<RecurringWindow> recurringWindowStore = {};

# Monotonically increasing counter used to generate unique recurring window ids.
int nextRecurringWindowId = 1;

# The number of days in each month of a non-leap year, indexed from 1 (January) to 12 (December).
final int[] & readonly daysInNonLeapMonth = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

# Converts a local wall-clock date and time at a given site into the corresponding UTC instant.
#
# + site - the datacenter site the local time belongs to
# + localDateTime - the local wall-clock date and time
# + return - the resolved UTC instant, or an error if the conversion fails
function toUtc(Site site, LocalDateTime localDateTime) returns time:Utc|error {
    string zoneId = siteTimeZones.get(site);
    time:Zone? zone = time:getZone(zoneId);
    if zone is () {
        return error("Unable to resolve time zone for site: " + site.toString());
    }
    time:Civil civil = {
        year: localDateTime.year,
        month: localDateTime.month,
        day: localDateTime.day,
        hour: localDateTime.hour,
        minute: localDateTime.minute,
        second: 0,
        timeAbbrev: zoneId
    };
    time:Utc utc = check zone.utcFromCivil(civil);
    return utc;
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

# Generates the next unique recurring window id.
#
# + return - a freshly generated id
function generateRecurringWindowId() returns string {
    string generatedId = "rw-" + nextRecurringWindowId.toString();
    nextRecurringWindowId += 1;
    return generatedId;
}

# Checks whether a given year is a leap year in the Gregorian calendar.
#
# + year - the year to check
# + return - true if the year is a leap year
function isLeapYear(int year) returns boolean {
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

# Returns the number of days in a given month of a given year.
#
# + year - the year
# + month - the month (1-12)
# + return - the number of days in that month
function daysInMonth(int year, int month) returns int {
    if month == 2 && isLeapYear(year) {
        return 29;
    }
    return daysInNonLeapMonth[month];
}

# Finds the calendar date of the requested occurrence of a weekday within a given month.
#
# + year - the year
# + month - the month (1-12)
# + weekOfMonth - which occurrence of the weekday within the month
# + dayOfWeek - the target weekday
# + return - the day of the month on which the occurrence falls, or an error if the month has no such occurrence
function findOccurrenceDay(int year, int month, WeekOfMonth weekOfMonth, Weekday dayOfWeek) returns int|error {
    int targetWeekdayNumber = weekdayNumbers.get(dayOfWeek);
    int lastDayOfMonth = daysInMonth(year, month);

    if weekOfMonth == LAST {
        foreach int candidateDay in int:range(lastDayOfMonth, 0, step = -1) {
            time:DayOfWeek actualWeekdayNumber = time:dayOfWeek({year, month, day: candidateDay});
            if actualWeekdayNumber == targetWeekdayNumber {
                return candidateDay;
            }
        }
        return error("Unable to locate the last " + dayOfWeek.toString() + " of " + year.toString() + "-" + month.toString());
    }

    final map<int> occurrenceOffsets = {[FIRST]: 0, [SECOND]: 1, [THIRD]: 2, [FOURTH]: 3};
    int occurrenceOffset = occurrenceOffsets.get(weekOfMonth);
    foreach int candidateDay in int:range(1, 8, step = 1) {
        time:DayOfWeek actualWeekdayNumber = time:dayOfWeek({year, month, day: candidateDay});
        if actualWeekdayNumber == targetWeekdayNumber {
            int occurrenceDay = candidateDay + (occurrenceOffset * 7);
            if occurrenceDay > lastDayOfMonth {
                return error("Month " + year.toString() + "-" + month.toString() + " does not have a " + weekOfMonth.toString() + " " + dayOfWeek.toString());
            }
            return occurrenceDay;
        }
    }
    return error("Unable to locate a " + dayOfWeek.toString() + " in " + year.toString() + "-" + month.toString());
}

# Builds the concrete local start and end date-times for one occurrence of a standing
# maintenance slot in a given year and month. If the slot's end time is not after its
# start time, the occurrence is understood to run past midnight and end the next day.
#
# + recurringWindow - the standing maintenance slot
# + year - the year of the occurrence
# + month - the month of the occurrence (1-12)
# + return - the local start and end date-times for this occurrence, or an error if the month has no such occurrence
function buildOccurrenceLocalDateTimes(RecurringWindow recurringWindow, int year, int month) returns [LocalDateTime, LocalDateTime]|error {
    int occurrenceDay = check findOccurrenceDay(year, month, recurringWindow.weekOfMonth, recurringWindow.dayOfWeek);
    TimeOfDay startTime = recurringWindow.localStartTime;
    TimeOfDay endTime = recurringWindow.localEndTime;

    LocalDateTime occurrenceStart = {
        year,
        month,
        day: occurrenceDay,
        hour: startTime.hour,
        minute: startTime.minute
    };

    boolean rollsOverToNextDay = endTime.hour < startTime.hour
        || (endTime.hour == startTime.hour && endTime.minute <= startTime.minute);

    if !rollsOverToNextDay {
        LocalDateTime sameDayEnd = {
            year,
            month,
            day: occurrenceDay,
            hour: endTime.hour,
            minute: endTime.minute
        };
        return [occurrenceStart, sameDayEnd];
    }

    int nextDay = occurrenceDay + 1;
    int nextDayMonth = month;
    int nextDayYear = year;
    if nextDay > daysInMonth(year, month) {
        nextDay = 1;
        nextDayMonth = month + 1;
        if nextDayMonth > 12 {
            nextDayMonth = 1;
            nextDayYear += 1;
        }
    }
    LocalDateTime nextDayEnd = {
        year: nextDayYear,
        month: nextDayMonth,
        day: nextDay,
        hour: endTime.hour,
        minute: endTime.minute
    };
    return [occurrenceStart, nextDayEnd];
}

# Expands a standing maintenance slot into its concrete occurrences that intersect a given period.
#
# + recurringWindow - the standing maintenance slot
# + periodStart - the start of the query period
# + periodEnd - the end of the query period
# + return - the matching occurrences as maintenance windows, or an error if a conversion fails
function expandRecurringWindow(RecurringWindow recurringWindow, time:Utc periodStart, time:Utc periodEnd) returns MaintenanceWindow[]|error {
    time:Utc probeStart = time:utcAddSeconds(periodStart, -31d * 24 * 60 * 60);
    time:Civil probeStartCivil = time:utcToCivil(probeStart);
    time:Civil periodEndCivil = time:utcToCivil(periodEnd);

    MaintenanceWindow[] occurrences = [];
    int candidateYear = probeStartCivil.year;
    int candidateMonth = probeStartCivil.month;

    while candidateYear < periodEndCivil.year || (candidateYear == periodEndCivil.year && candidateMonth <= periodEndCivil.month) {
        [LocalDateTime, LocalDateTime]|error occurrenceDateTimes = buildOccurrenceLocalDateTimes(recurringWindow, candidateYear, candidateMonth);
        if occurrenceDateTimes is [LocalDateTime, LocalDateTime] {
            [LocalDateTime, LocalDateTime] [occurrenceLocalStart, occurrenceLocalEnd] = occurrenceDateTimes;
            time:Utc occurrenceUtcStart = check toUtc(recurringWindow.site, occurrenceLocalStart);
            time:Utc occurrenceUtcEnd = check toUtc(recurringWindow.site, occurrenceLocalEnd);
            if isWithinPeriod({
                id: recurringWindow.id,
                site: recurringWindow.site,
                title: recurringWindow.title,
                localStart: occurrenceLocalStart,
                localEnd: occurrenceLocalEnd,
                timeZone: recurringWindow.timeZone,
                utcStart: occurrenceUtcStart,
                utcEnd: occurrenceUtcEnd
            }, periodStart, periodEnd) {
                occurrences.push({
                    id: recurringWindow.id + "-" + candidateYear.toString() + "-" + candidateMonth.toString(),
                    site: recurringWindow.site,
                    title: recurringWindow.title,
                    localStart: occurrenceLocalStart,
                    localEnd: occurrenceLocalEnd,
                    timeZone: recurringWindow.timeZone,
                    utcStart: occurrenceUtcStart,
                    utcEnd: occurrenceUtcEnd
                });
            }
        }

        candidateMonth += 1;
        if candidateMonth > 12 {
            candidateMonth = 1;
            candidateYear += 1;
        }
    }
    return occurrences;
}

# Computes the actual elapsed duration of a maintenance window on the global timeline, in minutes.
#
# + maintenanceWindow - the maintenance window
# + return - the actual duration in minutes
function actualDurationMinutes(MaintenanceWindow maintenanceWindow) returns decimal {
    time:Seconds durationSeconds = time:utcDiffSeconds(maintenanceWindow.utcEnd, maintenanceWindow.utcStart);
    return durationSeconds / 60;
}
