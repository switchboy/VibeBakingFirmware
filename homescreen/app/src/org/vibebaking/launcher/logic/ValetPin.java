package org.vibebaking.launcher.logic;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Valet PIN storage + wrong-attempt lockout (spec S26). Pure; UI glue in ValetPinActivity. */
public final class ValetPin {

    public static final int MAX_ATTEMPTS = 5;
    public static final long LOCKOUT_MS = 30_000L;

    private ValetPin() {}

    /** SHA-256 hex of the PIN digits; the PIN itself is never stored. */
    public static String hashPin(String pin) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(pin.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : h) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e); // SHA-256 is guaranteed on Android
        }
    }

    /** Result of one verification attempt against the guard's clock. */
    public static final class Verdict {
        public final boolean ok;          // PIN correct
        public final boolean locked;      // attempts exhausted, lockout active
        public final int remaining;       // attempts left before lockout
        public final long retryInMs;      // 0 unless locked
        Verdict(boolean ok, boolean locked, int remaining, long retryInMs) {
            this.ok = ok; this.locked = locked; this.remaining = remaining; this.retryInMs = retryInMs;
        }
    }

    /** Mutable attempt guard; the caller supplies "now" (wall clock millis). */
    public static final class Guard {
        private int attempts = 0;
        private long lockoutUntil = 0L;

        public Verdict verify(String pin, String storedHash, long now) {
            if (now < lockoutUntil) {
                return new Verdict(false, true, 0, lockoutUntil - now);
            }
            if (lockoutUntil != 0L && now >= lockoutUntil) { // lockout expired
                lockoutUntil = 0L;
                attempts = 0;
            }
            boolean ok = storedHash != null && !storedHash.isEmpty()
                       && MessageDigest.isEqual(storedHash.getBytes(StandardCharsets.UTF_8),
                                                hashPin(pin).getBytes(StandardCharsets.UTF_8));
            if (ok) { attempts = 0; lockoutUntil = 0L; return new Verdict(true, false, MAX_ATTEMPTS, 0); }
            attempts++;
            if (attempts >= MAX_ATTEMPTS) {
                lockoutUntil = now + LOCKOUT_MS;
                return new Verdict(false, true, 0, LOCKOUT_MS);
            }
            return new Verdict(false, false, MAX_ATTEMPTS - attempts, 0);
        }

        public void reset() { attempts = 0; lockoutUntil = 0L; }
        public boolean isLocked(long now) { return now < lockoutUntil; }
    }
}
