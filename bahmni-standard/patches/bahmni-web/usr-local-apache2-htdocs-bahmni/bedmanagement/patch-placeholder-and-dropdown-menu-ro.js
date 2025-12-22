(function () {
  "use strict";

  if (!/\/bedmanagement\//.test(window.location.pathname)) {
    return;
  }

  var translations = {};

  function t(key, fallback) {
    return translations[key] || fallback;
  }

  function buildMaps() {
    return {
      textMap: {
        "All Tasks": t("BEDMGMT_TASK_FILTER_ALL", "All Tasks"),
        "Medication Tasks": t(
          "BEDMGMT_TASK_FILTER_MEDICATION",
          "Medication Tasks"
        ),
        "Non-Medication Tasks": t(
          "BEDMGMT_TASK_FILTER_NON_MEDICATION",
          "Non-Medication Tasks"
        ),
      },
      placeholderMap: {
        "Type a minimum of 3 characters to search patient by name, bed number or patient ID":
          t(
            "BEDMGMT_SEARCH_PLACEHOLDER",
            "Type a minimum of 3 characters to search patient by name, bed number or patient ID"
          ),
      },
    };
  }

  var maps = buildMaps();

  function replaceTextNode(node) {
    var value = node.nodeValue;
    if (!value) {
      return;
    }
    var trimmed = value.trim();
    if (!trimmed) {
      return;
    }
    var replacement = maps.textMap[trimmed];
    if (!replacement) {
      return;
    }
    node.nodeValue = value.replace(trimmed, replacement);
  }

  function replaceElement(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      replaceTextNode(node);
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return;
    }

    if (node.tagName === "INPUT") {
      var placeholder = node.getAttribute("placeholder");
      if (placeholder && maps.placeholderMap[placeholder]) {
        node.setAttribute("placeholder", maps.placeholderMap[placeholder]);
      }
    }

    var child = node.firstChild;
    while (child) {
      replaceElement(child);
      child = child.nextSibling;
    }
  }

  function run() {
    replaceElement(document.body);
  }

  function init() {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", run);
    } else {
      run();
    }
  }

  var observer = new MutationObserver(function (mutations) {
    mutations.forEach(function (mutation) {
      if (mutation.type === "characterData") {
        replaceElement(mutation.target);
        return;
      }
      mutation.addedNodes.forEach(function (node) {
        replaceElement(node);
      });
    });
  });

  function loadLocale(lang) {
    return fetch("/ipd/i18n/locale_" + lang + ".json", { cache: "no-store" })
      .then(function (response) {
        return response.ok ? response.json() : null;
      })
      .catch(function () {
        return null;
      });
  }

  var lang = localStorage.getItem("NG_TRANSLATE_LANG_KEY") || "en";
  loadLocale(lang)
    .then(function (data) {
      translations = data || {};
      maps = buildMaps();
    })
    .finally(function () {
      init();
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        characterData: true,
      });
    });
})();
