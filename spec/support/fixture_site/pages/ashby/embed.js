// Ashby-like job board embed: injects the posting into the company page as iframe#ashby_embed_iframe, served from
// this script's (alt, cross-origin) origin. Like the real embed, a company page URL carrying ?ashby_jid=<job id>
// deep-links the posting: the iframe then opens <origin>/ashby/preply/<jid>?embed=js (the job URL detection keys
// on: slug + jid), otherwise the generic posting.html.
(function () {
  var origin = new URL(document.currentScript.src).origin;
  var jid = new URLSearchParams(window.location.search).get('ashby_jid');
  function inject() {
    var iframe = document.createElement('iframe');
    iframe.id = 'ashby_embed_iframe';
    iframe.title = 'Ashby Job Board';
    iframe.src =
      origin +
      (jid
        ? '/ashby/preply/' + encodeURIComponent(jid) + '?embed=js'
        : '/ashby/posting.html?embed=js');
    document.getElementById('ashby_embed').appendChild(iframe);
  }
  setTimeout(inject, 300);
})();
