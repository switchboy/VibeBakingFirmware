package org.vibebaking.launcher;

import android.content.Context;
import android.media.AudioManager;

import org.vibebaking.launcher.logic.VolumePolicy;

/** Reverse-gear volume attenuation (spec S31) on STREAM_MUSIC; policy decisions in VolumePolicy. */
public class AudioAttenuator {

    private final AudioManager am;
    private final CarClient car;
    private final SettingsStore store;
    private Integer captured; // volume captured at the first backview-start of this reverse spell

    public AudioAttenuator(Context c, CarClient car, SettingsStore store) {
        this.car = car;
        this.store = store;
        AudioManager m = null;
        try { m = (AudioManager) c.getApplicationContext().getSystemService(Context.AUDIO_SERVICE); }
        catch (Throwable ignore) { }
        am = m;
    }

    /** CarEvent BACKVIEW_START: attenuate (once) or delegate to the MCU. */
    public void onReverseStart() {
        String mode = store.reverseVolume();
        int pct = store.reversePercent();
        if (VolumePolicy.delegateToMcu(store.reverseMcu()) && car.isAvailable()) {
            car.sendCommand(VolumePolicy.mcuVolumeCommand(pct));
            return;
        }
        if (am == null) return;
        Integer target = VolumePolicy.targetVolume(mode, pct, max(), current());
        if (target == null) return;               // "unchanged"
        captured = VolumePolicy.capture(captured, current());
        try { am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0); }
        catch (Throwable t) { /* SecurityException: quietly degrade */ }
    }

    /** CarEvent BACKVIEW_STOP: restore the captured volume. */
    public void onReverseStop() {
        if (VolumePolicy.delegateToMcu(store.reverseMcu()) && car.isAvailable()) {
            // MCU owns attenuation; tell it back to full (same command surface).
            car.sendCommand(VolumePolicy.mcuVolumeCommand(100));
            return;
        }
        Integer restore = VolumePolicy.restoreVolume(captured != null, captured);
        captured = null;
        if (restore == null || am == null) return;
        try { am.setStreamVolume(AudioManager.STREAM_MUSIC, restore, 0); }
        catch (Throwable t) { }
    }

    /**
     * ACC_OFF / SLEEP: the reverse spell may have ended without a BACKVIEW_STOP frame (the MCU
     * drops frames while powering down). Restore the captured volume so it cannot stay low (S31).
     */
    public void onAccOff() {
        if (captured == null) return;
        if (VolumePolicy.delegateToMcu(store.reverseMcu()) && car.isAvailable()) {
            car.sendCommand(VolumePolicy.mcuVolumeCommand(100));
        } else if (am != null) {
            try { am.setStreamVolume(AudioManager.STREAM_MUSIC, captured, 0); }
            catch (Throwable t) { /* quietly degrade */ }
        }
        captured = null;
    }

    int current() {
        try { return am.getStreamVolume(AudioManager.STREAM_MUSIC); } catch (Throwable t) { return 0; }
    }

    int max() {
        try { return am.getStreamMaxVolume(AudioManager.STREAM_MUSIC); } catch (Throwable t) { return 15; }
    }
}
