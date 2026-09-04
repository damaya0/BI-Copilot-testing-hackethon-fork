import ballerina/jballerina.java;

# Information about the IANA time zone database (tzdata) version the service is currently
# running against, and the Java runtime supplying it. Ballerina's `time` module has no
# bundled tzdata of its own - it delegates entirely to the JVM's `java.time` zone rules,
# so the effective tzdata version is whatever ships with (or has since been patched into)
# that JVM, not anything pinned by the Ballerina distribution.
public type ZoneDataInfo record {|
    string tzdataVersion;
    string javaVersion;
    string javaVendor;
|};

# Reads a Java system property as a Ballerina string.
#
# + propertyName - the Java system property name, for example "java.version"
# + return - the property value
function getSystemProperty(handle propertyName) returns handle = @java:Method {
    name: "getProperty",
    'class: "java.lang.System",
    paramTypes: ["java.lang.String"]
} external;

# Looks up the version history of time zone rules known for a given zone id. The map is
# keyed by tzdata version string (for example "2024a"), ordered oldest to newest.
#
# + zoneId - the zone id to look up version history for; any valid zone id can be used
# + return - a `java.util.NavigableMap<String, java.time.zone.ZoneRules>` handle
function getZoneRuleVersions(handle zoneId) returns handle = @java:Method {
    name: "getVersions",
    'class: "java.time.zone.ZoneRulesProvider",
    paramTypes: ["java.lang.String"]
} external;

# Returns the most recent entry of a navigable map.
#
# + navigableMap - the map to read the last entry from
# + return - a `java.util.Map.Entry` handle for the most recent entry
function getLastEntry(handle navigableMap) returns handle = @java:Method {
    name: "lastEntry",
    'class: "java.util.NavigableMap"
} external;

# Returns the key of a map entry.
#
# + mapEntry - the map entry to read the key from
# + return - the entry's key
function getEntryKey(handle mapEntry) returns handle = @java:Method {
    name: "getKey",
    'class: "java.util.Map$Entry"
} external;

# Reports the IANA tzdata version bundled in the running JVM, together with the Java
# runtime's own version and vendor, so an operator can tell exactly which zone data the
# service is applying to every maintenance window conversion.
#
# + return - the zone data version info, or an error if it could not be determined
function getZoneDataInfo() returns ZoneDataInfo|error {
    handle utcZoneId = java:fromString("UTC");
    handle zoneRuleVersions = getZoneRuleVersions(utcZoneId);
    handle lastVersionEntry = getLastEntry(zoneRuleVersions);
    handle tzdataVersionHandle = getEntryKey(lastVersionEntry);
    string? tzdataVersion = java:toString(tzdataVersionHandle);
    if tzdataVersion is () {
        return error("Unable to determine the tzdata version from the running JVM.");
    }

    handle javaVersionPropertyName = java:fromString("java.version");
    handle javaVendorPropertyName = java:fromString("java.vendor");
    string? javaVersion = java:toString(getSystemProperty(javaVersionPropertyName));
    string? javaVendor = java:toString(getSystemProperty(javaVendorPropertyName));

    return {
        tzdataVersion,
        javaVersion: javaVersion ?: "unknown",
        javaVendor: javaVendor ?: "unknown"
    };
}
