package org.vibebaking.launcher.logic;

/** Plain HTTP fetch for the Open-Meteo forecast API (owner request 2026-11-27). Tests stub this. */
public interface WeatherFetcher {
    byte[] fetch(String url) throws Exception;
}
