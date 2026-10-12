"use strict";
// Only the home card changes. Every action and all other pages use frozen 9127864.
// Original opposing ports: one continuous bridge owns connection state.
const joinedShape = `<svg class="connection-figure" viewBox="0 0 180 160" aria-hidden="true"><path class="end-a" d="M82 38H38L22 54V106L38 122H82V110H43L34 101V59L43 50H82Z"/><path class="end-b" d="M98 38H142L158 54V106L142 122H98V110H137L146 101V59L137 50H98Z"/><path class="joint" d="M34 80H146"/></svg>`;
function composeConnectionHome() {
  if (state.page !== "home" || !state.profile) return;
  const hero = app.querySelector(".hero");
  const overview = app.querySelector(".connection-overview");
  if (!hero || !overview) return;
  const stage = document.createElement("div");
  stage.className = "connection-stage";
  const copy = document.createElement("div");
  copy.className = "connection-copy";
  while (hero.firstChild) copy.append(hero.firstChild);
  stage.append(copy);
  stage.insertAdjacentHTML("beforeend", joinedShape);
  hero.append(stage);
  const traffic = overview.querySelector(".traffic");
  if (traffic) hero.append(traffic);
  else {
    const waiting = overview.querySelector(".idle-traffic");
    if (waiting) hero.append(waiting);
  }
}
const frozenRender = render;
render = function (...args) {
  frozenRender(...args);
  composeConnectionHome();
};
composeConnectionHome();
