package org.vibebaking.launcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

import org.vibebaking.launcher.logic.RadarFetcher;
import org.vibebaking.launcher.logic.RadarPlan;

/** Real HTTP fetcher for RainViewer (java.net, no Android dependency). */
public class HttpRadarFetcher implements RadarFetcher {
    @Override
    public byte[] fetch(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(10_000);
        c.setReadTimeout(15_000);
        c.setRequestMethod("GET");
        try {
            int code = c.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code + " for " + url);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            InputStream in = c.getInputStream();
            byte[] buf = new byte[8192];
            int n, total = 0;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > RadarPlan.MAX_BODY_BYTES) throw new IOException("response too large");
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        } finally {
            c.disconnect();
        }
    }
}
