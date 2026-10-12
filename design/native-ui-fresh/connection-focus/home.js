"use strict";
// Only the home card changes. Every action and all other pages use frozen 9127864.
const joinedShape = `<svg class="connection-figure" viewBox="0 0 180 160" aria-hidden="true"><path class="end-a" fill-rule="evenodd" d="M12 26H88L106 44V100H30L12 82ZM36 48V72L42 78H82V54L76 48Z"/><path class="end-b" fill-rule="evenodd" d="M76 62H152L170 80V136H94L76 118ZM100 84V108L106 114H146V90L140 84Z"/><path class="joint" d="M83 77L102 96"/></svg>`;
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
