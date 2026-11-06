/*! rf-comments counts — show "N comments" next to links on index pages.
 *
 *   <a href="/posts/hello/" data-rf-count></a>             (counts the link's href)
 *   <span data-rf-count="https://blog.ryanfleck.ca/x/"></span>
 *   <span data-rf-count="post-42"></span>                  (a data-page-id)
 *   <script src="https://comments.ryanfleck.ca/count.js" data-site="blog" async></script>
 *
 * Values starting with http(s): are page URLs; anything else is a page id.
 * One request fetches every count on the page.
 */
(function () {
  "use strict";
  var script = document.currentScript ||
    document.querySelector('script[data-site][src*="/count.js"]');
  if (!script || !window.fetch) return;

  var base = new URL(script.src, location.href).origin;
  var elements = Array.prototype.slice.call(document.querySelectorAll("[data-rf-count]"));
  if (!elements.length) return;

  var params = new URLSearchParams({ site: script.getAttribute("data-site") || "" });
  var keys = elements.map(function (el) {
    var value = el.getAttribute("data-rf-count");
    var key = value
      ? (/^https?:/i.test(value) ? ["page", value] : ["id", value])
      : ["page", new URL(el.getAttribute("href") || location.href, location.href).href];
    params.append(key[0], key[1]);
    return key[1];
  });

  fetch(base + "/api/counts?" + params.toString(), { credentials: "omit" })
    .then(function (response) { return response.ok ? response.json() : {}; })
    .then(function (counts) {
      elements.forEach(function (el, i) {
        var n = counts[keys[i]] || 0;
        el.textContent = n + (n === 1 ? " comment" : " comments");
      });
    })
    .catch(function () { /* counts are decoration; fail quietly */ });
})();
