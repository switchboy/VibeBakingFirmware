package org.vibebaking.launcher;

/** Plain HTTP fetch for the RainViewer API/tiles (spec S15). Tests stub this interface. */
public interface RadarFetcher {
    byte[] fetch(String url) throws Exception;
}
