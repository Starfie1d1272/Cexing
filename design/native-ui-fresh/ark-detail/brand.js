"use strict";
// An original connection glyph; no application identity or runtime state is changed.
const connectionGlyph = (stateful = false) =>
  `<svg class="ark-connection-symbol ${stateful ? "ark-state-symbol" : ""}" viewBox="0 0 24 24" aria-hidden="true"><path class="terminals" d="M8 5H5v14h3M16 5h3v14h-3"/><path class="link" d="M8 12h8"/></svg>`;
function markNumbers(element) {
  if (!element || element.querySelector(".ark-numeral")) return;
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  for (const node of nodes) {
    const matches = [...node.textContent.matchAll(/\d+(?:[.:/]\d+)*/g)];
    if (!matches.length) continue;
    const fragment = document.createDocumentFragment();
    let offset = 0;
    for (const match of matches) {
      fragment.append(
        document.createTextNode(node.textContent.slice(offset, match.index)),
      );
      const number = document.createElement("span");
      number.className = "ark-numeral";
      number.textContent = match[0];
      fragment.append(number);
      offset = match.index + match[0].length;
    }
    fragment.append(document.createTextNode(node.textContent.slice(offset)));
    node.replaceWith(fragment);
  }
}
function applyArkDetails() {
  const title = app.querySelector(".brand");
  if (title) title.insertAdjacentHTML("afterbegin", connectionGlyph());
  const connectionTab = app.querySelector('[data-tab="home"] svg');
  if (connectionTab) connectionTab.outerHTML = connectionGlyph();
  const hero = app.querySelector(".hero");
  if (hero) hero.insertAdjacentHTML("afterbegin", connectionGlyph(true));
  app
    .querySelectorAll(".row small,.fact span:last-child,.lead")
    .forEach(markNumbers);
}
const baseRender = render;
render = function (...args) {
  baseRender(...args);
  applyArkDetails();
};
applyArkDetails();
