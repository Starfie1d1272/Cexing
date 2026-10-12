"use strict";
// Only the home card changes. Every action and all other pages use frozen 9127864.
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
  stage.insertAdjacentHTML("beforeend", `<div class="stage-surfaces" aria-hidden="true"><span class="paper-plane"></span><span class="ink-plane"></span><span class="signal-seam"></span></div>`);
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
