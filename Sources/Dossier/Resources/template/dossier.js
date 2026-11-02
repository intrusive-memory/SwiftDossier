/* dossier-format page template. Behaviour only (DF-49): every element here works
   as plain HTML without this script. It makes no network request (DF-42). */
(function () {
  "use strict";

  /* DF-51. A host message handler, when one is present. See README, "Proposed". */
  function hostHandler() {
    var candidates = [
      window.dossierHost,
      window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dossier
    ];
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] && typeof candidates[i].postMessage === "function") return candidates[i];
    }
    return null;
  }

  function postKey(key) {
    var handler = hostHandler();
    if (!handler) return;
    try { handler.postMessage(key); } catch (error) { /* A host's failure isn't the page's. */ }
  }

  /* Posts this element's key on a click inside it, unless a nested key took the click. */
  class KeyedElement extends HTMLElement {
    connectedCallback() {
      if (this.keyedReady) return;
      this.keyedReady = true;
      this.addEventListener("click", (event) => {
        if (event.target.closest("[data-key]") === this) postKey(this.getAttribute("data-key"));
      });
    }
  }

  /* The lightbox: one dialog, made the first time an image is opened. */
  var lightbox = null;
  var lightboxImage = null;
  var lightboxSet = [];

  function showImage(image) {
    lightboxImage.src = image.src;
    lightboxImage.alt = image.alt;
    lightbox.current = image;
  }

  function openLightbox(image) {
    if (!lightbox) {
      lightbox = document.createElement("dialog");
      lightbox.className = "lightbox";
      lightboxImage = document.createElement("img");
      lightbox.appendChild(lightboxImage);
      lightbox.addEventListener("click", function () { lightbox.close(); });
      lightbox.addEventListener("keydown", function (event) {
        var step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
        if (!step || lightboxSet.length < 2) return;
        var index = lightboxSet.indexOf(lightbox.current);
        showImage(lightboxSet[(index + step + lightboxSet.length) % lightboxSet.length]);
        event.preventDefault();
      });
      document.body.appendChild(lightbox);
    }
    if (typeof lightbox.showModal !== "function") return;
    var set = image.closest("dossier-image-set");
    lightboxSet = set ? Array.prototype.slice.call(set.querySelectorAll("img")) : [];
    showImage(image);
    lightbox.showModal();
  }

  class DossierField extends KeyedElement {
    connectedCallback() {
      super.connectedCallback();
      if (this.fieldReady || this.getAttribute("data-kind") !== "image") return;
      this.fieldReady = true;
      this.addEventListener("click", function (event) {
        if (event.target.tagName === "IMG") openLightbox(event.target);
      });
    }
  }

  class DossierImageSet extends KeyedElement {}

  /* One audio player at a time, on click only (DF-49, DF-50). */
  var PLAY = '<svg width="12" height="12" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 1.5v11l9-5.5z" fill="currentColor"></path></svg>';
  var PAUSE = '<svg width="12" height="12" viewBox="0 0 14 14" aria-hidden="true"><path d="M3 1.5h3v11H3zM8 1.5h3v11H8z" fill="currentColor"></path></svg>';

  document.addEventListener("play", function (event) {
    var players = document.querySelectorAll("audio");
    for (var i = 0; i < players.length; i++) {
      if (players[i] !== event.target) players[i].pause();
    }
  }, true);

  class DossierAudio extends KeyedElement {
    connectedCallback() {
      super.connectedCallback();
      if (this.audioReady) return;
      this.audioReady = true;
      Array.prototype.forEach.call(this.querySelectorAll("audio"), function (audio) {
        var title = audio.getAttribute("aria-label") || "";
        var button = document.createElement("button");
        button.type = "button";
        button.className = "play-button";
        function paint() {
          button.innerHTML = audio.paused ? PLAY : PAUSE;
          button.setAttribute("aria-label", (audio.paused ? "Play " : "Pause ") + title);
        }
        paint();
        button.addEventListener("click", function () {
          if (audio.paused) {
            var started = audio.play();
            if (started && started.catch) started.catch(function () {});
          } else {
            audio.pause();
          }
        });
        audio.addEventListener("play", paint);
        audio.addEventListener("pause", paint);
        audio.addEventListener("ended", paint);
        audio.removeAttribute("controls");
        audio.parentNode.insertBefore(button, audio);
      });
    }
  }

  /* Tabs. Every panel stays in the document, so print still shows them all (DF-49). */
  class DossierTabs extends HTMLElement {
    connectedCallback() {
      if (this.links) return;
      this.links = Array.prototype.slice.call(this.querySelectorAll("[data-tab-link]"));
      this.panels = Array.prototype.slice.call(this.querySelectorAll(":scope > .tab-panel"));
      this.querySelector(".tab-list").setAttribute("role", "tablist");
      this.links.forEach((link) => {
        link.setAttribute("role", "tab");
        link.setAttribute("aria-controls", link.getAttribute("data-tab-link"));
        link.addEventListener("click", (event) => {
          event.preventDefault();
          this.choose(link);
        });
        link.addEventListener("keydown", (event) => this.onKey(event, link));
      });
      this.panels.forEach(function (panel) { panel.setAttribute("role", "tabpanel"); });
      this.setAttribute("data-enhanced", "");
      /* A mark's hash may already be the page's: no hashchange fires, so follow it here. */
      document.addEventListener("click", (event) => {
        var mark = event.target.closest(".mark a");
        if (!mark || mark.hash !== location.hash) return;
        event.preventDefault();
        this.follow();
      });
      window.addEventListener("hashchange", () => this.follow());
      window.addEventListener("load", () => this.follow());
      this.follow();
    }

    choose(link) {
      var key = link.getAttribute("data-tab-link");
      this.select(key);
      try { history.replaceState(null, "", "#" + key); } catch (error) { /* A host's page may refuse. */ }
      link.focus();
    }

    onKey(event, link) {
      var index = this.links.indexOf(link);
      var last = this.links.length - 1;
      var next = { ArrowRight: index === last ? 0 : index + 1, ArrowLeft: index === 0 ? last : index - 1, Home: 0, End: last }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      this.choose(this.links[next]);
    }

    /* DF-50: #voice opens that tab; #profile.age opens its tab and goes to the field, as
       does #page.sources. A key outside the tabs (#page.name) scrolls and keeps the tab. */
    follow() {
      var key = "";
      try { key = decodeURIComponent(location.hash.slice(1)); } catch (error) { key = ""; }
      var target = key ? document.getElementById(key) : null;
      var panel = target ? target.closest(".tab-panel") : null;
      if (panel) this.select(panel.id);
      else if (!this.selected) this.select(this.panels[0].id);
      if (target && target !== panel) target.scrollIntoView();
    }

    select(key) {
      this.selected = key;
      this.panels.forEach(function (panel) {
        if (panel.id === key) panel.setAttribute("data-active", "");
        else panel.removeAttribute("data-active");
      });
      this.links.forEach(function (link) {
        var on = link.getAttribute("data-tab-link") === key;
        link.setAttribute("aria-selected", on ? "true" : "false");
        link.setAttribute("tabindex", on ? "0" : "-1");
      });
    }
  }

  customElements.define("dossier-field", DossierField);
  customElements.define("dossier-image-set", DossierImageSet);
  customElements.define("dossier-audio", DossierAudio);
  customElements.define("dossier-tabs", DossierTabs);
})();
