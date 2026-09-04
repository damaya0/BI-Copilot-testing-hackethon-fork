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

# Builds the concrete local start and end date-times for one crew phase of a standing
# maintenance slot in a given year and month. If the phase's end time is not after its
# start time, the phase is understood to run past midnight and end the next day.
#
# + recurringWindow - the standing maintenance slot
# + phase - the crew phase to build
# + year - the year of the occurrence
# + month - the month of the occurrence (1-12)
# + return - the local start and end date-times for this phase, or an error if the month has no such occurrence
function buildPhaseLocalDateTimes(RecurringWindow recurringWindow, RecurringPhase phase, int year, int month) returns [LocalDateTime, LocalDateTime]|error {
    int occurrenceDay = check findOccurrenceDay(year, month, recurringWindow.weekOfMonth, recurringWindow.dayOfWeek);
    TimeOfDay startTime = phase.localStartTime;
    TimeOfDay endTime = phase.localEndTime;

    LocalDateTime phaseStart = {
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
        return [phaseStart, sameDayEnd];
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
    return [phaseStart, nextDayEnd];
}

# One expanded crew phase occurrence of a standing maintenance slot, together with the
# label of the phase and the year/month/occurrence group it belongs to (used to group
# phases back together for finance reconciliation).
public type RecurringPhaseOccurrence record {|
    MaintenanceWindow phaseWindow;
    string phaseLabel;
    string occurrenceGroupId;
|};

# Expands a standing maintenance slot into the concrete crew phase occurrences that
# intersect a given period.
#
# + recurringWindow - the standing maintenance slot
# + periodStart - the start of the query period
# + periodEnd - the end of the query period
# + return - the matching phase occurrences, or an error if a conversion fails
function expandRecurringWindow(RecurringWindow recurringWindow, time:Utc periodStart, time:Utc periodEnd) returns RecurringPhaseOccurrence[]|error {
    time:Utc probeStart = time:utcAddSeconds(periodStart, -31d * 24 * 60 * 60);
    time:Civil probeStartCivil = time:utcToCivil(probeStart);
    time:Civil periodEndCivil = time:utcToCivil(periodEnd);

    RecurringPhaseOccurrence[] phaseOccurrences = [];
    int candidateYear = probeStartCivil.year;
    int candidateMonth = probeStartCivil.month;

    while candidateYear < periodEndCivil.year || (candidateYear == periodEndCivil.year && candidateMonth <= periodEndCivil.month) {
        string occurrenceGroupId = recurringWindow.id + "-" + candidateYear.toString() + "-" + candidateMonth.toString();
        foreach RecurringPhase phase in recurringWindow.phases {
            [LocalDateTime, LocalDateTime]|error phaseDateTimes = buildPhaseLocalDateTimes(recurringWindow, phase, candidateYear, candidateMonth);
            if phaseDateTimes is [LocalDateTime, LocalDateTime] {
                [LocalDateTime, LocalDateTime] [phaseLocalStart, phaseLocalEnd] = phaseDateTimes;
                time:Utc phaseUtcStart = check toUtc(recurringWindow.site, phaseLocalStart);
                time:Utc phaseUtcEnd = check toUtc(recurringWindow.site, phaseLocalEnd);
                MaintenanceWindow phaseWindow = {
                    id: occurrenceGroupId + "-" + phase.label,
                    site: recurringWindow.site,
                    title: recurringWindow.title + " (" + phase.label + ")",
                    localStart: phaseLocalStart,
                    localEnd: phaseLocalEnd,
                    timeZone: recurringWindow.timeZone,
                    utcStart: phaseUtcStart,
                    utcEnd: phaseUtcEnd
                };
                if isWithinPeriod(phaseWindow, periodStart, periodEnd) {
                    phaseOccurrences.push({
                        phaseWindow,
                        phaseLabel: phase.label,
                        occurrenceGroupId
                    });
                }
            }
        }

        candidateMonth += 1;
        if candidateMonth > 12 {
            candidateMonth = 1;
            candidateYear += 1;
        }
    }
    return phaseOccurrences;
}

# Computes the actual elapsed duration of a maintenance window on the global timeline, in minutes.
# A local start and end time that a clock change makes impossible to resolve consistently
# (for example, a phase that starts and ends within a spring-forward gap) can otherwise
# produce a nonsensical negative duration; that case is clamped to zero here, since there is
# no meaningful amount of on-site time to bill, and callers should treat it as needing manual
# review rather than as a real elapsed duration.
#
# + maintenanceWindow - the maintenance window
# + return - the actual duration in minutes, clamped to zero if it cannot be resolved consistently
function actualDurationMinutes(MaintenanceWindow maintenanceWindow) returns decimal {
    time:Seconds durationSeconds = time:utcDiffSeconds(maintenanceWindow.utcEnd, maintenanceWindow.utcStart);
    decimal durationMinutes = durationSeconds / 60;
    if durationMinutes < 0d {
        return 0;
    }
    return durationMinutes;
}

# Builds the concrete crew phase windows of a standing maintenance slot for a single
# calendar month, regardless of whether they fall within any particular query period.
# Used to validate a slot's phases against each other when it is first registered.
#
# + recurringWindow - the standing maintenance slot
# + year - the year to build the phases for
# + month - the month to build the phases for (1-12)
# + return - the phase windows for that month, or an error if a conversion fails
function phaseWindowsForMonth(RecurringWindow recurringWindow, int year, int month) returns MaintenanceWindow[]|error {
    MaintenanceWindow[] phaseWindows = [];
    foreach RecurringPhase phase in recurringWindow.phases {
        [LocalDateTime, LocalDateTime] [phaseLocalStart, phaseLocalEnd] = check buildPhaseLocalDateTimes(recurringWindow, phase, year, month);
        time:Utc phaseUtcStart = check toUtc(recurringWindow.site, phaseLocalStart);
        time:Utc phaseUtcEnd = check toUtc(recurringWindow.site, phaseLocalEnd);
        phaseWindows.push({
            id: phase.label,
            site: recurringWindow.site,
            title: recurringWindow.title + " (" + phase.label + ")",
            localStart: phaseLocalStart,
            localEnd: phaseLocalEnd,
            timeZone: recurringWindow.timeZone,
            utcStart: phaseUtcStart,
            utcEnd: phaseUtcEnd
        });
    }
    return phaseWindows;
}

# Checks whether any two of a standing slot's crew phase windows overlap each other.
# Phases that are simply back-to-back (one ends exactly when the next starts) do not count.
#
# + phaseWindows - the crew phase windows to check
# + return - true if any two phases overlap
function hasOverlappingPhases(MaintenanceWindow[] phaseWindows) returns boolean {
    foreach int firstIndex in int:range(0, phaseWindows.length(), step = 1) {
        foreach int secondIndex in int:range(firstIndex + 1, phaseWindows.length(), step = 1) {
            if windowsOverlap(phaseWindows[firstIndex], phaseWindows[secondIndex]) {
                return true;
            }
        }
    }
    return false;
}

# Builds the finance reconciliation view for one occurrence of a standing slot: the
# whole slot's own actual duration (from the earliest phase start to the latest phase
# end, on the global timeline) checked against the sum of its individual phase durations.
#
# + recurringWindow - the standing maintenance slot the phases belong to
# + phasesInOccurrence - the crew phase windows that make up this occurrence, in any order
# + return - the reconciliation view for this occurrence
function buildSlotReconciliation(RecurringWindow recurringWindow, MaintenanceWindow[] phasesInOccurrence) returns SlotReconciliation {
    time:Utc earliestPhaseStart = phasesInOccurrence[0].utcStart;
    time:Utc latestPhaseEnd = phasesInOccurrence[0].utcEnd;
    decimal phaseDurationTotalMinutes = 0;
    foreach MaintenanceWindow phaseWindow in phasesInOccurrence {
        if time:utcDiffSeconds(phaseWindow.utcStart, earliestPhaseStart) < 0d {
            earliestPhaseStart = phaseWindow.utcStart;
        }
        if time:utcDiffSeconds(phaseWindow.utcEnd, latestPhaseEnd) > 0d {
            latestPhaseEnd = phaseWindow.utcEnd;
        }
        phaseDurationTotalMinutes += actualDurationMinutes(phaseWindow);
    }
    time:Seconds slotDurationSeconds = time:utcDiffSeconds(latestPhaseEnd, earliestPhaseStart);
    decimal slotDurationMinutes = slotDurationSeconds / 60;
    return {
        recurringWindowId: recurringWindow.id,
        site: recurringWindow.site,
        title: recurringWindow.title,
        phases: [],
        slotDurationMinutes,
        phaseDurationTotalMinutes,
        reconciled: slotDurationMinutes == phaseDurationTotalMinutes
    };
}
