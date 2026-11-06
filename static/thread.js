/* rf-comments thread frame: report our height to the embedding page. */
(function () {
  "use strict";
  if (window.parent === window) return;
  var last = 0;
  function report() {
    var h = Math.ceil(document.body.getBoundingClientRect().height);
    if (h !== last) {
      last = h;
      window.parent.postMessage({ type: "rf-comments:height", height: h }, "*");
    }
  }
  if ("ResizeObserver" in window) new ResizeObserver(report).observe(document.body);
  window.addEventListener("load", report);
  report();
  // Comment links leave the frame.
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("a[href]");
    if (a && !a.target) a.target = "_top";
  });
})();
