// Marketing-site progressive enhancement: hero word rotation, the shared
// "thinking" spinner/verb loop across the demos, and data-copy buttons. Served as
// an external script (not inline) so the pages run under a strict CSP
// (script-src 'self', no 'unsafe-inline'). Reads everything from DOM data attrs.
(function () {
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var el = document.querySelector('[data-rotate]');
  if (el && !reduce) {
    try {
      var words = JSON.parse(el.getAttribute('data-rotate')), i = 0;
      setInterval(function () { i = (i + 1) % words.length; el.textContent = words[i]; }, 2200);
    } catch (e) {}
  }
  // One loop drives the "thinking" spinner + verb in every demo (terminal AND
  // phone) at once, so they animate in lockstep.
  var spins = document.querySelectorAll('[data-think-spin]');
  var verbs2 = document.querySelectorAll('[data-think-word]');
  if (spins.length && !reduce) {
    var frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    var verbs = ['Thinking', 'Pondering', 'Hatching', 'Conjuring', 'Noodling', 'Cogitating', 'Scheming', 'Brewing'];
    var f = 0, v = 0;
    setInterval(function () { f = (f + 1) % frames.length; spins.forEach(function (s) { s.textContent = frames[f]; }); }, 90);
    setInterval(function () { v = (v + 1) % verbs.length; verbs2.forEach(function (w) { w.textContent = verbs[v]; }); }, 1900);
  }
  document.querySelectorAll('[data-copy]').forEach(function (b) {
    var reset;
    var label = b.getAttribute('aria-label');
    b.addEventListener('click', async function () {
      var text = b.getAttribute('data-copy');
      clearTimeout(reset);
      try {
        await navigator.clipboard.writeText(text);
        b.textContent = 'Copied';
        b.setAttribute('aria-label', 'Command copied');
        document.dispatchEvent(new CustomEvent('onlytty:copy-success', {
          detail: { kind: b.getAttribute('data-copy-kind') }
        }));
      } catch (_) {
        b.textContent = 'Copy blocked';
        b.setAttribute('aria-label', 'Copy blocked. Select the command and copy it manually.');
      }
      reset = setTimeout(function () {
        b.textContent = 'Copy';
        b.setAttribute('aria-label', label);
      }, 2000);
    });
  });
})();
