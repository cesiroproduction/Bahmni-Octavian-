/* global angular */
(function () {
    "use strict";

    angular.module("bahmni.reports").run(["$rootScope", function ($rootScope) {
        $rootScope.dateRangeLabels = {
            "Today": "REPORTS_DATE_RANGE_TODAY",
            "This Month": "REPORTS_DATE_RANGE_THIS_MONTH",
            "Previous Month": "REPORTS_DATE_RANGE_PREVIOUS_MONTH",
            "This Quarter": "REPORTS_DATE_RANGE_THIS_QUARTER",
            "This Year": "REPORTS_DATE_RANGE_THIS_YEAR",
            "Last 7 days": "REPORTS_DATE_RANGE_LAST_7_DAYS",
            "Last 30 days": "REPORTS_DATE_RANGE_LAST_30_DAYS"
        };

        // Ensure the reports view scope has the labels when it renders.
        $rootScope.$on("$viewContentLoaded", function () {
            var reportsScope;
            if (window.document) {
                reportsScope = angular.element(window.document.querySelector(".reports-page")).scope();
            }
            if (reportsScope && !reportsScope.dateRangeLabels) {
                reportsScope.dateRangeLabels = $rootScope.dateRangeLabels;
                reportsScope.$applyAsync();
            }
        });
    }]);
}());
