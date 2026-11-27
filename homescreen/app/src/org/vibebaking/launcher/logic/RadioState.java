package org.vibebaking.launcher.logic;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * HCT radio as a media-card source (owner request 2026-11-26). The radio app (com.microntek.radio) publishes no media
 * session, so the card follows the radio itself (protocol read from the app's RadioService, see docs/findings.md):
 *  - active      = the MCU audio source is the radio: CarManager string state "av_channel" equals "fm" (the radio's
 *                  own check), plus broadcasts com.microntek.canbusdisplay type=radio-on / radio-off;
 *  - frequency   = car event "Radio" type=freq value, or canbusdisplay type=radio fre. Units differ: the radio app keeps
 *                  FM in 10 kHz steps (fre=10135 = 101.35 MHz, measured on the unit), the MCU's own log uses kHz
 *                  (seek 100350); AM is kHz. normalizeKhz() maps all of them to kHz;
 *  - station     = car event "Radio" type=psn value=<RDS PS bytes>, ISO-8859-1 outside China (the app uses gb2312 only
 *                  for its China area);
 *  - commands    = broadcasts hct.radio.channel.prev / hct.radio.channel.next / hct.radio.power.switch, and
 *                  hct.radio.request.data (the app answers with a canbusdisplay type=radio broadcast).
 * Pure: no Android types.
 */
public final class RadioState {

    public static final String PKG = "com.microntek.radio";
    public static final String ACT_PREV = "hct.radio.channel.prev";
    public static final String ACT_NEXT = "hct.radio.channel.next";
    public static final String ACT_POWER = "hct.radio.power.switch";
    public static final String ACT_REQUEST = "hct.radio.request.data";
    public static final String BC_DISPLAY = "com.microntek.canbusdisplay";
    public static final String CAR_EVENT_TYPE = "Radio";
    /** Below this many kHz the frequency is AM (FM starts at 64 MHz in every region). */
    static final int FM_MIN_KHZ = 30_000;

    public boolean active;
    public int freqKhz;      // 0 = unknown
    public String psn = "";  // RDS programme service name, "" = none

    /** av_channel value of the HCT car service while the radio is the audio source. */
    public static boolean isRadioChannel(String avChannel) {
        return avChannel != null && "fm".equalsIgnoreCase(avChannel.trim());
    }

    /** RDS PS bytes -> trimmed text ("" for null/blank/control-only). */
    public static String decodePsn(byte[] b) {
        if (b == null) return "";
        String s = new String(b, StandardCharsets.ISO_8859_1);
        StringBuilder out = new StringBuilder();
        for (char c : s.toCharArray()) out.append(c < 0x20 ? ' ' : c);
        return out.toString().trim();
    }

    public static boolean isFm(int khz) { return khz >= FM_MIN_KHZ; }

    /**
     * Any radio frequency value -> kHz. >= 30000: already kHz (FM). 6400..29999: FM in 10 kHz steps (64.00-299.99 MHz;
     * no AM/LW/SW broadcast band reaches 6400 kHz in practice for this tuner). Below: AM in kHz. <= 0: unknown (0).
     */
    public static int normalizeKhz(int v) {
        if (v <= 0) return 0;
        if (v >= FM_MIN_KHZ) return v;
        if (v >= 6400) return v * 10;
        return v;
    }

    /** "100.35 MHz" / "1008 kHz" / "" when unknown. */
    public static String formatFreq(int khz) {
        if (khz <= 0) return "";
        if (isFm(khz)) return String.format(Locale.ROOT, "%.2f MHz", khz / 1000.0);
        return khz + " kHz";
    }

    /** Card title: the RDS station name if there is one, else the frequency, else "Radio". */
    public String title() {
        if (psn != null && !psn.isEmpty()) return psn;
        String f = formatFreq(freqKhz);
        return f.isEmpty() ? "Radio" : f;
    }

    /** Second line: band + frequency when the title is the station name, else the band only. */
    public String subtitle() {
        if (freqKhz <= 0) return "";
        String band = isFm(freqKhz) ? "FM" : "AM";
        return (psn != null && !psn.isEmpty()) ? band + " " + formatFreq(freqKhz) : band;
    }

    /** A new frequency invalidates the old station name (RDS sends the new PS within ~1 s). */
    public void setFreq(int raw) {
        int khz = normalizeKhz(raw);
        if (khz > 0 && khz != freqKhz) { freqKhz = khz; psn = ""; }
    }
}
