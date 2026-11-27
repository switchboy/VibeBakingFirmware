package org.vibebaking.launcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

import org.vibebaking.launcher.logic.WeatherFetcher;
import org.vibebaking.launcher.logic.WeatherIcon;

/**
 * Real HTTP fetcher for the Open-Meteo forecast API (owner request 2026-11-27), same helper style as
 * {@link HttpRadarFetcher}: User-Agent required by some hosts, connect 10 s / read 15 s, GET only.
 * Every failure surfaces as an exception that WeatherIcon.parseCurrent turns into "keep the last value".
 * The URL carries the rounded position, so failure messages never include it (privacy rule).
 */
public class HttpWeatherFetcher implements WeatherFetcher {
    public static final String USER_AGENT = HttpRadarFetcher.USER_AGENT;

    @Override
    public byte[] fetch(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(10_000);
        c.setReadTimeout(15_000);
        c.setRequestMethod("GET");
        c.setRequestProperty("User-Agent", USER_AGENT);
        try {
            int code = c.getResponseCode();
            // No URL in the message: it contains the (rounded) position and must never be logged.
            if (code != 200) throw new IOException("HTTP " + code);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            InputStream in = c.getInputStream();
            byte[] buf = new byte[8192];
            int n, total = 0;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > WeatherIcon.MAX_BODY_BYTES) throw new IOException("response too large");
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } finally {
            c.disconnect();
        }
    }
}
