package org.vibebaking.launcher;

import android.app.Activity;
import android.os.Bundle;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.vibebaking.launcher.logic.ValetPin;

/** Valet PIN pad (spec S26): wrong attempts lock out after MAX_ATTEMPTS for LOCKOUT_MS. */
public class ValetPinActivity extends Activity {

    private final ValetPin.Guard guard = new ValetPin.Guard();
    private TextView status;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        SettingsStore store = App.store();
        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        setContentView(page);

        status = new TextView(this);
        status.setTextSize(18f);
        status.setPadding(24, 16, 24, 16);
        EditText pin = new EditText(this);
        pin.setHint("PIN");
        pin.setInputType(android.input.InputType.TYPE_CLASS_NUMBER);
        Button unlock = new Button(this);
        unlock.setText("Unlock valet mode");
        unlock.setOnClickListener(v -> {
            // Re-read the hash on every attempt: a PIN saved while this screen is open must work.
            long now = System.currentTimeMillis();
            String hash = store.valetPinHash();
            ValetPin.Verdict verdict = guard.verify(pin.getText().toString(), hash, now);
            if (verdict.ok) {
                App.valet().exit();
                finish();
                return;
            }
            if (hash.isEmpty()) {
                status.setText(getString(R.string.pin_unset));
            } else if (verdict.locked) {
                status.setText(getString(R.string.pin_locked, verdict.retryInMs / 1000));
            } else {
                status.setText(getString(R.string.pin_wrong, verdict.remaining));
            }
        });
        page.addView(status);
        page.addView(pin);
        page.addView(unlock);

        if (!App.valet().isActive()) status.setText(getString(R.string.pin_not_active));
        if (store.valetPinHash().isEmpty()) status.setText(getString(R.string.pin_unset));
    }
}
