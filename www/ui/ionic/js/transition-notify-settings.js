angular.module('emission.main.control.tnotify', [])
.factory("ControlTransitionNotifyHelper", function($window, 
        $ionicActionSheet, $ionicPopup, $ionicPopover, $rootScope) {

    var ctnh = {};
    var CONFIG_LIST = "config_list";
    var MUTED_LIST = "muted_list";
    ctnh.transition_name_list = [
        "trip_started", "trip_ended", "tracking_started", "tracking_stopped"
    ];
    ctnh.new_configList = [];
    ctnh.transition2configList = [];
    ctnh.settingsPopup = {};

    /* 
     * Functions to read and format values for display
     */

    ctnh.getTNotifySettings = function() {
        var promiseList = ctnh.transition_name_list.map(function(tn) {
            return ctnh.getConfigForTransition(tn, true);
        });
        return Promise.all(promiseList).then(function(resultList){
            ctnh.transition2configList = resultList;
            var notifyEnableLists = resultList.filter(non_null).map(ctnh.config2notifyList);
            var combinedTransitionNotifyEnable = notifyEnableLists.reduce(
                function(acc, val) {
                return acc.concat(val);
            });
            // return combinedTransitionNotifyEnable.map(ctnh.formatConfigForDisplay);
            return combinedTransitionNotifyEnable;
        })
    };

    var non_null = function(el) {
        return el != null;
    }

    /*
     * Output of this function is a map of the form:
     * { transitionName: "trip_ended",
         id: "737678",
         title: "Trip just ended",
         enabled: true/false
     * }
     */

    ctnh.config2notifyList = function(configWithMetadata) {
        var configList = configWithMetadata.data[CONFIG_LIST];
        var mutedList = configWithMetadata.data[MUTED_LIST];
        var enabledList = configList.map(function(config, i) {
            return isMutedEntry(config.id, mutedList);
        });
        var retVal = configList.map(function(config, i) {
            return {
                transitionName: configWithMetadata.metadata.key,
                id: config.id,
                title: "Trip just ended",
                enabled: enabledList[i]
            };
        });
        return retVal;
    }

    var isMutedEntry = function(id, mutedList) {
        if (angular.isUndefined(mutedList)) {
            return false;
        };
        var foundMuted = mutedList.find(function(mutedEntry) {
            if (mutedEntry.id == id) {
                return true;
            }
        });
        // if we found a muted entry, foundMuted is defined
        // so if it is undefined, it is not muted, and we want to return false
        return !(angular.isUndefined(foundMuted));
    }

    /*
     * Currently unused - we're displaying a real template, not just key-value pairs
     */
    ctnh.formatConfigForDisplay = function(tnce) {
        return {'key': tnce.transitionName + " "+tnce.id + " "+tnce.title,
                'val': tnce.enabled};
    }

    /* 
     * Functions to edit and save values
     */

    var getPopoverScope = function() {
        var new_scope = $rootScope.$new();
        new_scope.saveAndReload = ctnh.saveAndReload;
        new_scope.isIOS = ionic.Platform.isIOS;
        new_scope.isAndroid = ionic.Platform.isAndroid;
        new_scope.setAccuracy = ctnh.setAccuracy;
        return new_scope;
    }

    ctnh.editConfig = function($event) {
        // TODO: replace with angular.clone
        ctnh.new_config = JSON.parse(JSON.stringify(ctnh.config));
        var popover_scope = getPopoverScope();
        popover_scope.new_config = ctnh.new_config;
        $ionicPopover.fromTemplateUrl('templates/control/main-collect-settings.html', {
            scope: popover_scope
        }).then(function(popover) {
            ctnh.settingsPopup = popover;
            console.log("settings popup = "+ctnh.settingsPopup);
            ctnh.settingsPopup.show($event);
        });
        return ctnh.new_config;
    }

    ctnh.saveAndReload = function() {
        console.log("new config = "+ctnh.new_config);
        ctnh.setConfig(ctnh.new_config)
        .then(function(){
            ctnh.config = ctnh.new_config;
            $rootScope.$broadcast('control.update.complete', 'collection config');
        }, function(err){
            console.log("setConfig Error: " + err);
        });
        ctnh.settingsPopup.hide();
        ctnh.settingsPopup.remove();
    };

    /* 
     * Edit helpers for values that selected from actionSheets
     */

    ctnh.setAccuracy= function() {
        var accuracyActions = [];
        for (name in ctnh.accuracyOptions) {
            accuracyActions.push({text: name, value: ctnh.accuracyOptions[name]});
        }
        $ionicActionSheet.show({
            buttons: accuracyActions,
            titleText: "Select accuracy",
            cancelText: "Cancel",
            buttonClicked: function(index, button) {
                ctnh.new_config.accuracy = button.value;
                return true;
            }
        });
    };

    ctnh.forceState = function() {
        var forceStateActions = [{text: "Initialize",
                                  transition: "INITIALIZE"},
                                 {text: 'Start trip',
                                  transition: "EXITED_GEOFENCE"},
                                 {text: 'End trip',
                                  transition: "STOPPED_MOVING"},
                                 {text: 'Visit ended',
                                  transition: "VISIT_ENDED"},
                                 {text: 'Visit started',
                                  transition: "VISIT_STARTED"},
                                 {text: 'Remote push',
                                  transition: "RECEIVED_SILENT_PUSH"}];
        $ionicActionSheet.show({
            buttons: forceStateActions,
            titleText: "Force state",
            cancelText: "Cancel",
            buttonClicked: function(index, button) {
                ctnh.forceTransition(button.transition);
                return true;
            }
        });
    };

    ctnh.forceTransition = function(transition) {
        ctnh.forceTransitionWrapper(transition).then(function(result) {
            $rootScope.$broadcast('control.update.complete', 'forceTransition');
            $ionicPopup.alert({template: 'success -> '+result});
        }, function(error) {
            $rootScope.$broadcast('control.update.complete', 'forceTransition');
            $ionicPopup.alert({template: 'error -> '+error});
        });
    };


    /* 
     * Functions for the separate accuracy toggle 
     */

    var accuracy2String = function() {
        var accuracy = ctnh.config.accuracy;
        for (var k in ctnh.accuracyOptions) {
            if (ctnh.accuracyOptions[k] == accuracy) {
                return k;
            }
        }
    }

    ctnh.isMediumAccuracy = function() {
        if (ctnh.config == null) {
            return undefined; // config not loaded when loading ui, set default as false
        } else {
            var v = accuracy2String();
            if (ionic.Platform.isIOS()) {
                return v != "kCLLocationAccuracyBestForNavigation" && v != "kCLLocationAccuracyBest" && v != "kCLLocationAccuracyTenMeters";
            } else if (ionic.Platform.isAndroid()) {
                return v != "PRIORITY_HIGH_ACCURACY";
            } else {
                $ionicPopup.alert("Emission does not support this platform");
            }
        }
    }

    ctnh.toggleLowAccuracy = function() {
        ctnh.new_config = JSON.parse(JSON.stringify(ctnh.config));
        if (ctnh.isMediumAccuracy()) {
            if (ionic.Platform.isIOS()) {
                ctnh.new_config.accuracy = ctnh.accuracyOptions["kCLLocationAccuracyBest"];
            } else if (ionic.Platform.isAndroid()) {
                accuracy = ctnh.accuracyOptions["PRIORITY_HIGH_ACCURACY"];
            }
        } else {
            if (ionic.Platform.isIOS()) {
                ctnh.new_config.accuracy = ctnh.accuracyOptions["kCLLocationAccuracyHundredMeters"];
            } else if (ionic.Platform.isAndroid()) {
                ctnh.new_config.accuracy = ctnh.accuracyOptions["PRIORITY_BALANCED_POWER_ACCURACY"];
            }
        }
        ctnh.setConfig(ctnh.new_config)
        .then(function(){
            console.log("setConfig Sucess");
        }, function(err){
            console.log("setConfig Error: " + err);
        });
    }

    /*
     * BEGIN: Simple read/write wrappers
     */

    ctnh.getConfigForTransition = function(transitionName, withMetadata) {
      return window.cordova.plugins.BEMUserCache.getLocalStorage(transitionName, withMetadata);
    };

    return ctnh;
});
