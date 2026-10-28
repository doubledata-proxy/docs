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
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** Foreground-only host example. Supply your application-sdk.json asset before use. */
public final class MainActivity extends Activity implements DoubleDataClient.Observer {
    private static final ClientRetirement RETIREMENTS = new ClientRetirement();
    private static final ExecutorService JOIN_WORKER = Executors.newSingleThreadExecutor();
    private DoubleDataClient client;
    private boolean visible, destroyed, creating;
    private long requestEpoch;
    private EditText endpoint, key;
    private TextView status;
    private JSONObject applicationConfig;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);layout.setPadding(32,32,32,32);
        endpoint = new EditText(this);endpoint.setSingleLine(true);
        endpoint.setHint("Configured HTTPS endpoint");layout.addView(endpoint);
        key = new EditText(this);key.setSingleLine(true);
        key.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        key.setHint("Developer key");layout.addView(key);
        button(layout,"Review sharing options",() -> {
            try {
                if (!visible || destroyed || creating) return;
                if (client != null) { client.requestConsentAndStart(this);return; }
                {
                    if(applicationConfig==null)throw new IllegalStateException("Configure application-sdk.json before sharing.");
                    JSONObject config = new JSONObject(applicationConfig.toString())
                            .put("endpoint",endpoint.getText().toString())
                            .put("developer_key",key.getText().toString());
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
        status = new TextView(this);status.setText("Sharing is off. Review your options to choose whether to participate.");layout.addView(status);
        try {
            applicationConfig=loadApplicationConfig();
            endpoint.setText(applicationConfig.optString("endpoint",""));
            key.setText(applicationConfig.optString("developer_key",""));
        } catch(Exception error) {
            status.setText("Configure the application-sdk.json asset before sharing.");
        }
        setContentView(layout);
    }
    private void button(LinearLayout layout, String label, Runnable action) {
        Button button = new Button(this);button.setText(label);button.setOnClickListener(view -> action.run());layout.addView(button);
    }
    private JSONObject loadApplicationConfig() throws Exception {
        try(InputStream input=getAssets().open("application-sdk.json");
                ByteArrayOutputStream content=new ByteArrayOutputStream()) {
            byte[] buffer=new byte[4096];int count;
            while((count=input.read(buffer))!=-1)content.write(buffer,0,count);
            return new JSONObject(new String(content.toByteArray(),StandardCharsets.UTF_8));
        }
    }
    @Override public void onStatus(String json) {
        try {
            JSONObject snapshot=new JSONObject(json);
            String permission=snapshot.optString("consent_state","");
            String state=snapshot.optString("state","");
            String message;
            if(permission.equals("withdrawn"))message="Sharing is off. Your permission has been withdrawn.";
            else if(permission.equals("expired"))message="Sharing is off. Review your options to participate again.";
            else if(permission.equals("declined"))message="Sharing is off. You chose not to participate.";
            else if(permission.equals("awaiting_consent"))message="Sharing is off. Choose whether to enable sharing.";
            else if(state.equals("running"))message="Sharing is on. Stop or withdraw whenever you choose.";
            else if(state.equals("retrying"))message="Connection interrupted. Trying again…";
            else if(state.equals("starting")||state.equals("registering")||state.equals("connecting"))message="Connecting to share…";
            else if(state.equals("stopping"))message="Stopping sharing…";
            else if(state.equals("failed"))message="Sharing could not connect. Check your connection and try again.";
            else if(permission.equals("granted"))message="Sharing is paused. Restart when you're ready.";
            else message="Sharing is off. Review your options to choose whether to participate.";
            status.setText(message);
        } catch(Exception error) { status.setText("Sharing status is unavailable."); }
    }
    @Override public void onError(Exception error) {
        status.setText("Sharing could not continue. Check your connection and the application's sharing settings.");
    }
    @Override protected void onStart() { super.onStart();visible = true; }
    private void retireCurrent() {
        ++requestEpoch;
        if (client == null) return;
        client.setObserver(null);
        // closeAsync invalidates consent synchronously before its worker joins.
        RETIREMENTS.retire(client);
        client = null;
        endpoint.setEnabled(true);key.setEnabled(true);
    }
    @Override protected void onStop() {
        visible = false;retireCurrent();super.onStop();
    }
    @Override protected void onDestroy() {
        destroyed = true;retireCurrent();super.onDestroy();
    }
}
