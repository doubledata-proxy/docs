package io.doubledata.sample;

import android.app.Activity;
import android.os.Bundle;
import android.text.InputType;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import io.doubledata.DoubleDataClient;
import io.doubledata.ClientRetirement;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;

/** Foreground-only sample. Configure the operator notice before distribution. */
public final class MainActivity extends Activity implements DoubleDataClient.Observer {
    private static final ClientRetirement RETIREMENTS = new ClientRetirement();
    private static final ExecutorService JOIN_WORKER = Executors.newSingleThreadExecutor();
    private DoubleDataClient client;
    private boolean visible, destroyed, creating;
    private long requestEpoch;
    private EditText endpoint, key;
    private TextView status;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);layout.setPadding(32,32,32,32);
        endpoint = new EditText(this);endpoint.setSingleLine(true);
        endpoint.setText("https://192.168.1.20:8443");endpoint.setHint("Backend HTTPS endpoint");layout.addView(endpoint);
        key = new EditText(this);key.setSingleLine(true);
        key.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        key.setHint("Developer key");layout.addView(key);
        button(layout,"Review consent and start",() -> {
            try {
                if (!visible || destroyed || creating) return;
                if (client != null) { client.requestConsentAndStart(this);return; }
                {
                    JSONObject notice = new JSONObject()
                            .put("version","sample-v1")
                            .put("controller","Sample operator — replace before distribution")
                            .put("contact","privacy@example.test")
                            .put("purpose","Optional contribution of device connectivity for proxy requests")
                            .put("privacy_url","https://example.test/privacy")
                            .put("text","Participation is optional. Approved requests use this device's internet connection and public IP address. This consumes bandwidth, battery and power; network charges may apply. The operator receives an app-scoped device identifier and session traffic counts. Only accept if you are an adult with authority over this device and network. Decline to continue without contribution. Use Withdraw consent at any time to stop contribution. This sample limits each session to 15 minutes and 64 MiB.");
                    JSONObject config = new JSONObject().put("endpoint",endpoint.getText().toString())
                            .put("developer_key",key.getText().toString()).put("transport","tcp")
                            .put("consent_notice",notice).put("session_duration_seconds",900)
                            .put("max_session_bytes",67108864);
                    final String configJSON = config.toString();
                    final long expected = ++requestEpoch;
                    creating = true;
                    status.setText("Waiting for the previous session to close…");
                    JOIN_WORKER.execute(() -> {
                        try {
                            RETIREMENTS.awaitPrevious().get();
                            RETIREMENTS.awaitPrevious();
                            runOnUiThread(() -> {
                                creating = false;
                                if (destroyed || !visible || expected != requestEpoch) return;
                                try {
                                    client = new DoubleDataClient(configJSON,this);
                                    endpoint.setEnabled(false);key.setEnabled(false);
                                    client.requestConsentAndStart(this);
                                } catch (Exception error) { onError(error); }
                            });
                        } catch (Exception error) {
                            runOnUiThread(() -> { creating = false;if (!destroyed) onError(error); });
                        }
                    });
                }
            } catch (Exception error) { onError(error); }
        });
        button(layout,"Stop",() -> { if (client != null) client.stop(); });
        button(layout,"Restart",() -> { if (client != null) client.restart(); });
        button(layout,"Withdraw consent",() -> { if (client != null) client.withdrawConsent(); });
        status = new TextView(this);status.setText("Contribution is off. Review the notice to choose whether to participate.");layout.addView(status);
        setContentView(layout);
    }
    private void button(LinearLayout layout, String label, Runnable action) {
        Button button = new Button(this);button.setText(label);button.setOnClickListener(view -> action.run());layout.addView(button);
    }
    @Override public void onStatus(String json) { status.setText(json); }
    @Override public void onError(Exception error) { status.setText(error.toString()); }
    @Override protected void onStart() { super.onStart();visible = true; }
    private void retireCurrent() {
        ++requestEpoch;
        if (client == null) return;
        client.setObserver(null);
        // closeAsync invalidates consent synchronously before its worker joins.
        RETIREMENTS.retire(client);
        client = null;
    }
    @Override protected void onStop() {
        visible = false;retireCurrent();super.onStop();
    }
    @Override protected void onDestroy() {
        destroyed = true;retireCurrent();super.onDestroy();
    }
}
