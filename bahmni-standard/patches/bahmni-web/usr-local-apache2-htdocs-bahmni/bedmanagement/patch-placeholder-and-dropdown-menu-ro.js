(function () {
  "use strict";

  if (!/\/bedmanagement\//.test(window.location.pathname)) {
    return;
  }

  var textMap = {
    "All Tasks": "Toate sarcinile",
    "Medication Tasks": "Sarcini medicație",
    "Non-Medication Tasks": "Sarcini non-medicație"
  };

  var placeholderMap = {
    "Type a minimum of 3 characters to search patient by name, bed number or patient ID":
      "Introduceți minimum 3 caractere pentru a căuta pacientul după nume, număr pat sau ID pacient"
  };

  function replaceTextNode(node) {
    var value = node.nodeValue;
    if (!value) {
      return;
    }
    var trimmed = value.trim();
    if (!trimmed) {
      return;
    }
    var replacement = textMap[trimmed];
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
      if (placeholder && placeholderMap[placeholder]) {
        node.setAttribute("placeholder", placeholderMap[placeholder]);
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

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run);
  } else {
    run();
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

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true
  });
})();
