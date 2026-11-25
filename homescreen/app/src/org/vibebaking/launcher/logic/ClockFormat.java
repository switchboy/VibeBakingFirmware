package org.vibebaking.launcher.logic;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Locale;

/** Car clock (spec S18): HH:mm local time + short date; refreshed once a minute by LauncherActivity. */
public final class ClockFormat {

    public static final long TICK_MS = 60_000L;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("HH:mm", Locale.ENGLISH);
    private static final DateTimeFormatter DATE = DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH);

    private ClockFormat() {}

    public static String time(long epochMillis, int tzOffsetHours) {
        return TIME.format(Instant.ofEpochMilli(epochMillis).atOffset(ZoneOffset.ofHours(tzOffsetHours)));
    }

    public static String date(long epochMillis, int tzOffsetHours) {
        return DATE.format(Instant.ofEpochMilli(epochMillis).atOffset(ZoneOffset.ofHours(tzOffsetHours)));
    }
}
