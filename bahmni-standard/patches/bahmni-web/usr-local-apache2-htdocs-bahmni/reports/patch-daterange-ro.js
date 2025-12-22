/* global angular */
(function () {
    "use strict";

    angular.module("bahmni.reports").run(["$rootScope", function ($rootScope) {
        $rootScope.dateRangeLabels = {
            "Today": "Astăzi",
            "This Month": "Luna aceasta",
            "Previous Month": "Luna trecută",
            "This Quarter": "Trimestrul acesta",
            "This Year": "Anul acesta",
            "Last 7 days": "Ultimele 7 zile",
            "Last 30 days": "Ultimele 30 de zile"
        };
    }]);
}());
