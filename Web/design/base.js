// Tables base behaviour. Import once, before anything else, on every page.
//
// UI images never start a drag. CSS (-webkit-user-drag: none in components.css)
// covers WebKit and Chromium; Firefox ignores it, so drags are cancelled here too.
// Elements that are meant to be dragged opt in with draggable="true".

const UI_MEDIA = "img, svg, picture, video, canvas";

document.addEventListener("dragstart", (event) => {
  const target = event.target instanceof Element ? event.target : event.target?.parentElement;
  if (!target || target.closest('[draggable="true"]')) return;
  if (target.closest(UI_MEDIA)) event.preventDefault();
});
