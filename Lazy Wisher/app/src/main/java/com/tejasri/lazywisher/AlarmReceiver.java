package com.tejasri.lazywisher;

import android.content.Context;
import android.content.Intent;

public class AlarmReceiver extends WakefulBroadcastReceiver {

    public static final String INTENT_FILTER = "com.tejasri.lazywisher.AlarmReceiver.INTENT_FILTER";

    @Override
    public void onReceive(Context context, Intent intent) {
        Intent service = new Intent(context, SmsSenderService.class);
        service.putExtras(intent.getExtras());
        startWakefulService(context, service);
    }

}