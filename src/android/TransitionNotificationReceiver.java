package edu.berkeley.eecs.emission.cordova.transitionnotify;

import android.annotation.TargetApi;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Bundle;
import android.support.v4.content.LocalBroadcastManager;
import android.webkit.ValueCallback;

import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CallbackContext;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/*
 * Importing dependencies from the notification plugin
 */

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

import de.appplant.cordova.plugin.localnotification.TriggerReceiver;
import de.appplant.cordova.plugin.notification.Manager;
import de.appplant.cordova.plugin.notification.Request;
import de.appplant.cordova.plugin.notification.Options;

/*
 * Importing dependencies from the logger plugin
 */

import edu.berkeley.eecs.emission.BuildConfig;
import edu.berkeley.eecs.emission.R;

import edu.berkeley.eecs.emission.cordova.tracker.wrapper.SimpleLocation;
import edu.berkeley.eecs.emission.cordova.tracker.wrapper.Transition;
import edu.berkeley.eecs.emission.cordova.unifiedlogger.Log;
import edu.berkeley.eecs.emission.cordova.usercache.UserCache;
import edu.berkeley.eecs.emission.cordova.usercache.UserCacheFactory;

public class TransitionNotificationReceiver extends BroadcastReceiver {

    public static final String USERDATA = "userdata";
    private static String TAG =  TransitionNotificationReceiver.class.getSimpleName();

    public static final String EVENTNAME_ERROR = "event name null or empty.";

    private static final String TRIP_STARTED = "trip_started";
    private static final String TRIP_ENDED = "trip_ended";
    private static final String TRACKING_STARTED = "tracking_started";
    private static final String TRACKING_STOPPED = "tracking_stopped";

    private static final String CONFIG_LIST_KEY = "config_list";
    private static final String MUTED_LIST_KEY = "muted_list";
    private static final String ID = "id";

    public TransitionNotificationReceiver() {
        // The automatically created receiver needs a default constructor
        android.util.Log.i(TAG, "noarg constructor called");
    }

    public TransitionNotificationReceiver(Context context) {
        android.util.Log.i(TAG, "constructor called with arg "+context);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        Log.i(context, TAG, "TripDiaryStateMachineReciever onReceive(" + context + ", " + intent + ") called");

        // Next two calls copied over from the constructor, figure out if this is the best place to
        // put them
        Set<String> validTransitions = new HashSet<String>(Arrays.asList(new String[]{
                context.getString(R.string.transition_initialize),
                context.getString(R.string.transition_exited_geofence),
                context.getString(R.string.transition_stopped_moving),
                context.getString(R.string.transition_stop_tracking),
                context.getString(R.string.transition_start_tracking),
                context.getString(R.string.transition_tracking_error)
        }));

        if (!validTransitions.contains(intent.getAction())) {
            Log.e(context, TAG, "Received unknown action "+intent.getAction()+" ignoring");
            return;
        }
        fireGenericTransition(context, intent.getAction(), new JSONObject());
    }

    /**
     * @param context
     * @param eventName
     * @param userInfo
     * @throws JSONException
     */
    protected void fireGenericTransition( final Context context, final String eventName,
                                          final JSONObject userInfo) {
        Log.d(context, TAG, "Received platform-specification notification "+eventName);
        try {
        if (eventName.equals(context.getString(R.string.transition_exited_geofence))) {
                JSONObject autogenData = getTripStartData(context);
                postNativeAndNotify(context, TRIP_STARTED, autogenData);
    }

        if (eventName.equals(context.getString(R.string.transition_stopped_moving))) {
                JSONObject autogenData = getTripStartEndData(context);
                if (autogenData != null) {
                postNativeAndNotify(context, TRIP_ENDED, autogenData);
        }
            }

        if (eventName.equals(context.getString(R.string.transition_stop_tracking))) {
                postNativeAndNotify(context, TRACKING_STOPPED, new JSONObject());
        }

        if (eventName.equals(context.getString(R.string.transition_start_tracking))) {
                postNativeAndNotify(context, TRACKING_STARTED, new JSONObject());
            }
        } catch (JSONException e) {
            e.printStackTrace();
            Log.e(context, TAG, "Skipping firing of generic transition due to "+e.getMessage());
    }
            }

    public void postNativeAndNotify(Context context, String genericTransition, JSONObject autogenData) {
        Log.d(context, TAG, "Broadcasting generic transition "+genericTransition
                +" and generating notification");
        Intent genericTransitionIntent = new Intent();
        genericTransitionIntent.setAction(genericTransition);
        genericTransitionIntent.putExtras(jsonToBundle(autogenData));
        genericTransitionIntent.setPackage(context.getPackageName());
        context.sendBroadcast(genericTransitionIntent);
        notifyEvent(context, genericTransition, autogenData);
            }

    public void notifyEvent(Context context, String eventName, JSONObject autogenData) {
        Log.d(context, TAG, "Generating all notifications for generic "+eventName);
                        try {
            JSONObject notifyConfigWrapper = UserCacheFactory.getUserCache(context).getLocalStorage(eventName, false);
            if (notifyConfigWrapper == null) {
                Log.d(context, TAG, "no configuration found for event "+eventName+", skipping notification");
                return;
        }
            JSONArray notifyConfigs = notifyConfigWrapper.getJSONArray(CONFIG_LIST_KEY);
            JSONArray mutedConfigs = notifyConfigWrapper.optJSONArray(MUTED_LIST_KEY);
            for(int i = 0; i < notifyConfigs.length(); i++) {
               try {
                   JSONObject currNotifyConfig = notifyConfigs.getJSONObject(i);
                   int mutedIndex = findEntryWithId(mutedConfigs, currNotifyConfig.getLong(ID));
                   if(mutedIndex == -1) {
                   if (autogenData != null) { // we need to merge in the autogenerated data with any user data
                       JSONObject currData = currNotifyConfig.optJSONObject("data");
                       if (currData == null) {
                           currData = new JSONObject();
                           currNotifyConfig.put("data", currData);
                       }
                       mergeObjects(currData, autogenData);
                   }
                   Log.d(context, TAG, "generating notification for event "+eventName
                               + " and id = " + currNotifyConfig.getLong(ID));
                   Manager.getInstance(context).schedule(new Request(new Options(currNotifyConfig)), TriggerReceiver.class);
                   } else {
                       Log.d(context, TAG, "notification for event "+eventName+" and id = "+currNotifyConfig.getLong(ID)
                        +" muted, skip");
                   }
               } catch (Exception e) {
                   Log.e(context, TAG, "Got error "+e.getMessage()+" while processing object "
                           + notifyConfigs.getJSONObject(i) + " at index "+i);
    }
                    }
        } catch(JSONException e) {
            Log.e(context, TAG, e.getMessage());
            Log.e(context, TAG, e.toString());
               }
    }

    private int findEntryWithId(JSONArray array, long id) throws JSONException {
        if (array == null) {
            return -1;
        }
        for (int i = 0; i < array.length(); i++) {
            JSONObject currCheckedObject = array.getJSONObject(i);
            if (currCheckedObject.getLong(ID) == id) {
                return i;
            }
        }
        return -1;
    }

    private JSONObject getTripStartData(Context context) throws JSONException {
        JSONObject retData = new JSONObject();
        long currTime = System.currentTimeMillis();
        // We store the point at which the geofence was exited before we generate the exited_geofence
        // message. The trip start was at the last location.
        SimpleLocation[] lastLocArray = UserCacheFactory.getUserCache(context)
                .getLastSensorData(R.string.key_usercache_filtered_location, 1, SimpleLocation.class);
        if (lastLocArray.length == 0) {
            Log.e(context, TAG, "lastLocArray.length = "+lastLocArray.length+" while generating trip start event");
            retData.put("start_ts", ((double)currTime)/1000);
        } else {
            SimpleLocation lastLoc = lastLocArray[0];
            retData.put("start_ts", ((double) currTime) / 1000);
            retData.put("start_lat", lastLoc.getLatitude());
            retData.put("start_lng", lastLoc.getLongitude());
        }
        return retData;
    }

    private JSONObject getTripStartEndData(Context context) throws JSONException {
        JSONObject retData = new JSONObject();
        long currTime = System.currentTimeMillis();
        // We store the point at which the geofence was exited before we generate the exited_geofence
        // message. The trip start was at the last location.
        SimpleLocation[] lastLocArray = UserCacheFactory.getUserCache(context)
                .getLastSensorData(R.string.key_usercache_filtered_location, 1, SimpleLocation.class);
        if (BuildConfig.DEBUG) {
            if (lastLocArray.length != 1) {
                Log.e(context, TAG, "lastLocArray = "+lastLocArray.length+" while generating trip start event");
                // throw new RuntimeException("lastLocArray = "+lastLocArray.length+" while generating trip start event");
            }
            }

        if (lastLocArray.length == 0) {
            Log.e(context, TAG, "no locations found at trip end, skipping notification");
            return null;
        }
        SimpleLocation lastLoc = lastLocArray[0];
        retData.put("end_ts", lastLoc.getTs());
        retData.put("end_lat", lastLoc.getLatitude());
        retData.put("end_lng", lastLoc.getLongitude());

        // Find the start of this trip
        // Since the transitions are sorted in reverse order, we expect that the first will be the stopped moving transition
        // for the trip that just ended, the second will be the exited geofence transition that started it,
        // and the third (if present) will be the stopped_moving transition before that
        Transition[] lastTwoTransitions = UserCacheFactory.getUserCache(context).getLastMessages(
                R.string.key_usercache_transition, 2, Transition.class);
        SimpleLocation firstLoc = getFirstLocation(context, lastTwoTransitions);
        if(firstLoc == null) {
            Log.e(context, TAG, "error determining first location, skipping notification");
            return null;
        }

        retData.put("start_ts", firstLoc.getTs());
        retData.put("start_lat", firstLoc.getLatitude());
        retData.put("start_lng", firstLoc.getLongitude());
        return retData;
    }

    private SimpleLocation getFirstLocation(Context context, Transition[] lastTwoTransitions) {
        if (BuildConfig.DEBUG) {
            Log.d(context, TAG, "number of transitions = "+lastTwoTransitions.length);
            if (lastTwoTransitions.length == 0) {
                Log.e(context, TAG, "found no transitions at trip end, skipping notification");
                return null;
            }
            if (lastTwoTransitions.length > 2) {
                Log.e(context, TAG, "found too many transitions "
                        +lastTwoTransitions.length+ " at trip end, skipping notification");
                return null;
            }
            }

        if (lastTwoTransitions.length <= 2) {
            Transition startTransition = getStartTransition(lastTwoTransitions);
            if (startTransition.getTransition().equals(context.getString(R.string.transition_exited_geofence))) {
                UserCache.TimeQuery tq = new UserCache.TimeQuery("write_ts",
                        startTransition.getTs() - 5 * 60, //
                        startTransition.getTs() + 5 * 60);

                SimpleLocation[] firstLocArray = UserCacheFactory.getUserCache(context).getSensorDataForInterval(
                        R.string.key_usercache_filtered_location, tq, SimpleLocation.class);

                if (firstLocArray.length == 0) { // no locations found, switch to default
                    Log.d(context, TAG, "Found no locations before exiting geofence while ending trip!");
                    SimpleLocation firstLoc = getDefaultLocation(context);
                    if (firstLoc.getTs() < startTransition.getTs()) {
                        if (BuildConfig.DEBUG) {
                        throw new RuntimeException("firstLocArray[0].ts "+firstLoc.getTs()
                            +" < startTransition.ts "+startTransition.getTs());
                        } else {
                            // Explanation for returning null at
                            // https://github.com/e-mission/e-mission-transition-notify/issues/12#issuecomment-322535726
                            return null;
                        }
                    }
                    return firstLoc;
                } else {
                    // There are points around the start transition
                    // Return the last point before (preferable) or the first point after
                    ArrayList<SimpleLocation> beforePoints = new ArrayList<SimpleLocation>();
                    ArrayList<SimpleLocation> equalOrAfterPoints = new ArrayList<SimpleLocation>();
                    splitArray(firstLocArray, startTransition.getTs(), beforePoints, equalOrAfterPoints);
                    if (beforePoints.size() == 0 && equalOrAfterPoints.size() == 0) {
                        throw new RuntimeException("beforePoints.size = "+beforePoints.size()
                            + "afterPoints.size = "+equalOrAfterPoints.size());
                }

                    int beforeSize = beforePoints.size();
                    if (beforeSize > 0) {
                        return beforePoints.get(beforeSize - 1);
            } else {
                        return equalOrAfterPoints.get(0);
                    }
                }
            } else { // there were at least two transitions in the cache, but the second one
                // was not a geofence exit
                Log.d(context, TAG, "startTransition is "+startTransition.getTransition()
                    +" not "+context.getString(R.string.transition_exited_geofence));
                return getDefaultLocation(context);
            }
        } else {
            // Not enough transitions (have only one transition, presumably the stopping one)
            return getDefaultLocation(context);
        }
    }

    private Transition getStartTransition(Transition[] lastTwoTransitions) {
        /*
         Simple function here - no error checking since we have done that already
         * Small if - that's all we need
         */
        if (lastTwoTransitions.length == 2) {
            return lastTwoTransitions[1];
        } else {
            if (BuildConfig.DEBUG) {
                if (lastTwoTransitions.length > 2) {
                    throw new RuntimeException("last two transitions.length is " + lastTwoTransitions.length
                            + " should be < 2");
                }
            }
            return lastTwoTransitions[0];
        }
    }

    private void splitArray(SimpleLocation[] inArray, double ts,
                                      ArrayList<SimpleLocation> beforePoints,
                                      ArrayList<SimpleLocation> equalOrAfterPoints) {
        for (int i = 0; i < inArray.length; i++) {
            SimpleLocation currLoc = inArray[i];
            if (currLoc.getTs() < ts) {
                beforePoints.add(currLoc);
            } else {
                equalOrAfterPoints.add(currLoc);
            }
        }
    }

    private SimpleLocation getDefaultLocation(Context context) {
        SimpleLocation[] firstLocArray = UserCacheFactory.getUserCache(context).getFirstSensorData(
                R.string.key_usercache_filtered_location,
                1,
                SimpleLocation.class);

        if (firstLocArray.length == 0) {
            Log.e(context, TAG, "Found no locations while ending trip!");
            throw new RuntimeException("Found no locations while ending trip!");
        }

        return firstLocArray[0];
    }

    private void mergeObjects(JSONObject existing, JSONObject autogen) throws JSONException {
        JSONArray toBeCopiedKeys = autogen.names();
        for(int j = 0; j < toBeCopiedKeys.length(); j++) {
            String currKey = toBeCopiedKeys.getString(j);
            existing.put(currKey, autogen.get(currKey));
        }
    }

    private Bundle jsonToBundle(JSONObject toConvert) {
        Bundle bundle = new Bundle();

        for (Iterator<String> it = toConvert.keys(); it.hasNext(); ) {
            String key = it.next();
            JSONArray arr = toConvert.optJSONArray(key);
            Double num = toConvert.optDouble(key);
            String str = toConvert.optString(key);

            if (arr != null && arr.length() <= 0)
                bundle.putStringArray(key, new String[]{});

            else if (arr != null && !Double.isNaN(arr.optDouble(0))) {
                double[] newarr = new double[arr.length()];
                for (int i=0; i<arr.length(); i++)
                    newarr[i] = arr.optDouble(i);
                bundle.putDoubleArray(key, newarr);
            }

            else if (arr != null && arr.optString(0) != null) {
                String[] newarr = new String[arr.length()];
                for (int i=0; i<arr.length(); i++)
                    newarr[i] = arr.optString(i);
                bundle.putStringArray(key, newarr);
            }

            else if (!num.isNaN())
                bundle.putDouble(key, num);

            else if (str != null)
                bundle.putString(key, str);

            else
                System.err.println("unable to transform json to bundle " + key);
        }
        return bundle;
    }
}
