/*! rf-comments embed — https://comments.ryanfleck.ca
 *
 *   <div id="rf-comments"></div>
 *   <script src="https://comments.ryanfleck.ca/embed.js" data-site="blog" async></script>
 *
 * Optional attributes on the <script> tag:
 *   data-page-url    canonical URL for this thread (default: location.href)
 *   data-page-title  title shown in the admin/profile (default: document.title)
 *   data-target      id of the container element (default: "rf-comments")
 */
(function () {
  "use strict";
  var script = document.currentScript ||
    document.querySelector('script[data-site][src*="/embed.js"]');
  if (!script) return;

  var base = new URL(script.src, location.href).origin;
  var site = script.getAttribute("data-site") || "";
  var targetId = script.getAttribute("data-target") || "rf-comments";
  var target = document.getElementById(targetId);
  if (!target) {
    target = document.createElement("div");
    target.id = targetId;
    script.parentNode.insertBefore(target, script);
  }
  if (target.getAttribute("data-rf-loaded")) return;
  target.setAttribute("data-rf-loaded", "1");

  var params = new URLSearchParams({
    site: site,
    page: script.getAttribute("data-page-url") || location.href,
    title: script.getAttribute("data-page-title") || document.title || ""
  });

  var iframe = document.createElement("iframe");
  iframe.src = base + "/thread?" + params.toString();
  iframe.title = "Comments";
  iframe.loading = "lazy";
  iframe.setAttribute("scrolling", "no");
  iframe.style.cssText = "width:100%;border:0;overflow:hidden;min-height:180px;display:block;color-scheme:normal";
  target.appendChild(iframe);

  window.addEventListener("message", function (event) {
    if (event.origin !== base || event.source !== iframe.contentWindow) return;
    var data = event.data;
    if (data && data.type === "rf-comments:height" && typeof data.height === "number") {
      iframe.style.height = Math.ceil(data.height) + "px";
    }
  });
})();
