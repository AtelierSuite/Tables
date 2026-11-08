// Tables base behaviour. Import once, before anything else, on every page.
//
// The browser's own context menu never appears over the interface, as in a
// native app: elements with menus of their own open them (menus.js), and
// everything else shows none. Editable text keeps the browser's menu, for
// paste, spelling and input methods, as text fields do on macOS.
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

const TEXT_INPUT_TYPES = new Set(["text", "search", "email", "url", "tel", "password", "number", ""]);

function isEditableText(element) {
  if (!(element instanceof Element)) return false;
  if (element.closest('[contenteditable=""], [contenteditable="true"], .ds-document-content')) return true;
  if (element instanceof HTMLTextAreaElement) return !element.readOnly && !element.disabled;
  if (element instanceof HTMLInputElement) {
    return TEXT_INPUT_TYPES.has(element.getAttribute("type") ?? "") && !element.readOnly && !element.disabled;
  }
  return false;
}

// Bubbling, so a component's own menu has already been opened and the event cancelled.
document.addEventListener("contextmenu", (event) => {
  if (event.defaultPrevented) return;
  const target = event.target instanceof Element ? event.target : event.target?.parentElement;
  if (isEditableText(target)) return;
  event.preventDefault();
});
