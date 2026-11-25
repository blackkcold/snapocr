(function () {
  "use strict";

  var root = document.documentElement;
  var toggle = document.getElementById("theme-toggle");
  var nav = document.getElementById("nav");
  var storageKey = "snapglass-theme";

  function storedTheme() {
    try {
      return localStorage.getItem(storageKey);
    } catch (error) {
      return null;
    }
  }

  function syncThemeUI() {
    var dark = root.dataset.theme === "dark";

    if (toggle) {
      var label = dark ? toggle.dataset.labelDark : toggle.dataset.labelLight;
      if (label) {
        toggle.setAttribute("aria-label", label);
      }
      toggle.setAttribute("aria-pressed", dark ? "true" : "false");
    }

    document.querySelectorAll('meta[name="theme-color"]').forEach(function (meta) {
      meta.removeAttribute("media");
      meta.setAttribute("content", dark ? "#08080a" : "#f5f5f7");
    });
  }

  if (toggle) {
    toggle.addEventListener("click", function () {
      var next = root.dataset.theme === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      try {
        localStorage.setItem(storageKey, next);
      } catch (error) {}
      syncThemeUI();
    });
  }

  var media = window.matchMedia("(prefers-color-scheme: dark)");
  if (media.addEventListener) {
    media.addEventListener("change", function (event) {
      if (storedTheme()) {
        return;
      }
      root.dataset.theme = event.matches ? "dark" : "light";
      syncThemeUI();
    });
  }

  function syncNav() {
    if (nav) {
      nav.classList.toggle("is-scrolled", window.scrollY > 8);
    }
  }

  window.addEventListener("scroll", syncNav, { passive: true });
  syncNav();
  syncThemeUI();
}());
