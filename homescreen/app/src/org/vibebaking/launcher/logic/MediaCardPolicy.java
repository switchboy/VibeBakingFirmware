package org.vibebaking.launcher.logic;

import java.util.List;

/** Media-card presentation decision (spec S10-S12). Pure; MediaSessionManager glue in MediaCardController. */
public final class MediaCardPolicy {

    public static final int TR_PLAY_PAUSE = 1;
    public static final int TR_NEXT = 2;
    public static final int TR_PREV = 4;

    private MediaCardPolicy() {}

    /** One candidate controller, mirrored from MediaController into pure data. */
    public static final class Ctl {
        public String pkg;
        public String pkgLabel;
        public String title;
        public String artist;
        public String album;
        public boolean playing;   // transport state playing/preparing
        public boolean canPlayPause;
        public boolean canSkipNext;
        public boolean canSkipPrev;
    }

    /**
     * Active controller: the one that is actually playing wins; else the first with metadata;
     * else the first session. Never an empty card.
     */
    public static Ctl pickActive(List<Ctl> controllers) {
        if (controllers == null || controllers.isEmpty()) return null;
        for (Ctl c : controllers) if (c.playing) return c;
        for (Ctl c : controllers)
            if (notEmpty(c.title) || notEmpty(c.artist) || notEmpty(c.album)) return c;
        return controllers.get(0);
    }

    /** Card headline: title (+ artist), package label when a session publishes no metadata. */
    public static String label(Ctl c) {
        if (c == null) return "";
        if (notEmpty(c.title)) {
            return notEmpty(c.artist) ? c.title + " \u2022 " + c.artist : c.title;
        }
        return notEmpty(c.pkgLabel) ? c.pkgLabel : c.pkg;
    }

    public static String album(Ctl c) { return c != null && notEmpty(c.album) ? c.album : ""; }

    /** Enabled transport toggles from the controller's capabilities (spec S11). */
    public static int transportEnabled(Ctl c) {
        int t = 0;
        if (c == null) return t;
        if (c.canPlayPause) t |= TR_PLAY_PAUSE;
        if (c.canSkipNext) t |= TR_NEXT;
        if (c.canSkipPrev) t |= TR_PREV;
        return t;
    }

    /** Radio-as-source special label (phase 2, spec S13): station name beats package label. */
    public static String radioLabel(String station, Ctl c) {
        if (notEmpty(station)) return station;
        return label(c);
    }

    static boolean notEmpty(String s) { return s != null && !s.isEmpty(); }
}
