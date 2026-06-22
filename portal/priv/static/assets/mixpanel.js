// Mixpanel — product analytics for the PUBLIC marketing pages only.
//
// It is never loaded on the terminal viewer (/s/:id): that page's URL fragment
// carries the end-to-end session secret, so its Content-Security-Policy forbids any
// external script or connection and this file is simply never referenced there.
//
// First-party loader (served from our own origin under script-src 'self'); it pulls
// the Mixpanel library from cdn.mxpnl.com and sends events to api.mixpanel.com — the
// only two off-origin hosts the marketing CSP allows. The token is a public,
// client-side project token (not a secret). Honors Do Not Track.
(function () {
  var dnt = navigator.doNotTrack || window.doNotTrack || navigator.msDoNotTrack;
  if (dnt === "1" || dnt === "yes") return;

  var s = document.createElement("script");
  s.async = true;
  s.src = "https://cdn.mxpnl.com/libs/mixpanel-2-latest.min.js";
  s.onload = function () {
    if (!window.mixpanel || !window.mixpanel.init) return;
    window.mixpanel.init("63b2ad585d813e71396ff3b94be44789", {
      track_pageview: true,
      persistence: "localStorage",
    });
  };
  document.head.appendChild(s);
})();
