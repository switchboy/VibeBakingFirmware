package org.vibebaking.launcher.logic;

/**
 * Trusted-phone source (spec S25/S26): the HCT/GOC Bluetooth stack and Android's own stack both
 * implement this. Pure interface so the fault tolerance of the combination is unit-testable without
 * a phone, a BT daemon or an Android context. Implementations must never throw: a dead service or a
 * denied permission reports UNKNOWN (and configured=false), which keeps valet inert (S26a).
 */
public interface PhonePresenceProbe {

    /** Presence verdict; UNKNOWN when this source cannot tell us anything trustworthy. */
    PhonePresence probe();

    /** A trusted phone is paired (an exit path even while away). Default: source knows nothing. */
    default boolean trustedPhoneConfigured() { return false; }

    /** Release stack resources (profile proxies, receivers). Default: nothing to release. */
    default void release() {}
}
