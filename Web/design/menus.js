// Tables menus: pull-down, context and overflow menus that behave like NSMenu
// and always fit inside the window.
//
//   openMenu(items, anchor, options)        open a menu below an element, or at a point
//   attachContextMenu(element, getItems)    replace the browser menu on an element
//   attachMenuBar(bar, menus)               in-window menu bar; menus that don't fit move into »
//   attachToolbarOverflow(toolbar, button)  toolbar items that don't fit move into »
//
// An item is { label, shortcut?, checked?, disabled?, action?, submenu? },
// { separator: true } or { header: "Title" }.

const MARGIN = 8;
const SUBMENU_DELAY = 120;
const PRESS_RELEASE_DELAY = 250;

const CHECK_ICON = '<svg class="ds-icon ds-menu__check" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
const SUBMENU_ICON = '<svg class="ds-icon ds-menu__arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
const OVERFLOW_ICON = '<svg class="ds-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 4l4 4-4 4M8.5 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';

/** Open menus, outermost first: { menu, parentRow }. */
const stack = [];
const itemOf = new WeakMap();
let session = null;
let submenuTimer = 0;
let nextId = 0;

// ------------------------------------------------------------------ Rendering

function tidy(items) {
  const out = [];
  for (const item of items) {
    if (!item) continue;
    if (item.separator && (!out.length || out[out.length - 1].separator || out[out.length - 1].header)) continue;
    out.push(item);
  }
  while (out.length && (out[out.length - 1].separator || out[out.length - 1].header)) out.pop();
  return out;
}

function render(items) {
  const menu = document.createElement("div");
  menu.className = "ds-menu ds-menu--floating";
  menu.setAttribute("role", "menu");
  menu.tabIndex = -1;
  for (const item of tidy(items)) {
    if (item.separator) {
      const separator = document.createElement("div");
      separator.className = "ds-menu__separator";
      separator.setAttribute("role", "separator");
      menu.append(separator);
      continue;
    }
    if (item.header) {
      const header = document.createElement("div");
      header.className = "ds-menu__header";
      header.textContent = item.header;
      menu.append(header);
      continue;
    }
    const row = document.createElement("div");
    row.className = "ds-menu__item";
    row.id = `ds-menu-item-${++nextId}`;
    row.setAttribute("role", item.checked === undefined ? "menuitem" : "menuitemcheckbox");
    if (item.checked !== undefined) row.setAttribute("aria-checked", String(Boolean(item.checked)));
    if (item.disabled) row.setAttribute("aria-disabled", "true");
    if (item.submenu) {
      row.setAttribute("aria-haspopup", "menu");
      row.setAttribute("aria-expanded", "false");
    }
    row.innerHTML = `${CHECK_ICON}<span class="ds-menu__label"></span><span class="ds-menu__shortcut"></span>${item.submenu ? SUBMENU_ICON : "<span></span>"}`;
    row.querySelector(".ds-menu__label").textContent = item.label;
    row.querySelector(".ds-menu__shortcut").textContent = item.shortcut ?? "";
    row.title = item.label;
    itemOf.set(row, item);
    menu.append(row);
  }
  return menu;
}

// ------------------------------------------------------------------ Placement

function viewport() {
  const vv = window.visualViewport;
  return {
    width: vv ? vv.width : document.documentElement.clientWidth,
    height: vv ? vv.height : window.innerHeight,
  };
}

function rectOf(anchor) {
  if (anchor instanceof Element) return anchor.getBoundingClientRect();
  if (typeof anchor.left === "number") return anchor;
  return { left: anchor.x, right: anchor.x, top: anchor.y, bottom: anchor.y };
}

/**
 * Places a menu inside the window. "below" hangs from an element and flips above it
 * when there is more room there; "submenu" opens beside its parent and flips to the
 * other side at the window edge; "point" opens at the pointer like a context menu.
 * A menu taller than the room it has scrolls; one wider than the window ellipsises.
 */
function place(menu, anchor, placement) {
  const { width: vw, height: vh } = viewport();
  menu.style.left = "0px";
  menu.style.top = "0px";
  menu.style.maxWidth = `${vw - 2 * MARGIN}px`;
  menu.style.maxHeight = `${vh - 2 * MARGIN}px`;
  const width = menu.offsetWidth;
  let height = menu.offsetHeight;
  let x;
  let y;

  if (placement === "submenu") {
    x = anchor.right;
    if (x + width > vw - MARGIN && anchor.left - width >= MARGIN) x = anchor.left - width;
    y = anchor.top - 4;
  } else if (placement === "point") {
    x = anchor.left;
    if (x + width > vw - MARGIN && anchor.left - width >= MARGIN) x = anchor.left - width;
    y = anchor.top;
  } else {
    x = anchor.left;
    y = anchor.bottom;
  }

  if (y + height > vh - MARGIN) {
    if (placement === "below") {
      const below = vh - MARGIN - anchor.bottom;
      const above = anchor.top - MARGIN;
      if (above > below) {
        height = Math.min(height, above);
        y = anchor.top - height;
      } else {
        height = below;
      }
      menu.style.maxHeight = `${height}px`;
    } else if (placement === "point" && anchor.top - height >= MARGIN) {
      y = anchor.top - height;
    } else {
      y = vh - MARGIN - height;
    }
  }

  x = Math.max(MARGIN, Math.min(x, vw - MARGIN - width));
  y = Math.max(MARGIN, y);
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
}

// ------------------------------------------------------------------ Opening and closing

function push(items, anchor, placement, parentRow) {
  const menu = render(items);
  document.body.append(menu);
  place(menu, anchor, placement);
  stack.push({ menu, parentRow });
  if (parentRow) parentRow.setAttribute("aria-expanded", "true");
  menu.focus({ preventScroll: true });
  return menu;
}

/** Closes every menu deeper than `level` (-1 closes them all). */
function closeFrom(level) {
  while (stack.length > level + 1) {
    const { menu, parentRow } = stack.pop();
    if (parentRow) parentRow.setAttribute("aria-expanded", "false");
    menu.remove();
  }
  if (stack[level]) stack[level].menu.focus({ preventScroll: true });
}

export function openMenu(items, anchor, { placement = "below", opener = null, onClose = null, bar = null, highlightFirst = false, pressed = false } = {}) {
  closeMenus();
  session = { opener, onClose, bar, pressed, openedAt: performance.now() };
  push(items, rectOf(anchor), placement, null);
  if (highlightFirst) move(0, 1);
}

export function closeMenus({ restoreFocus = false } = {}) {
  clearTimeout(submenuTimer);
  closeFrom(-1);
  const ended = session;
  session = null;
  if (!ended) return;
  ended.onClose?.();
  if (restoreFocus) ended.opener?.focus({ preventScroll: true });
}

export const isMenuOpen = () => stack.length > 0;

// ------------------------------------------------------------------ Highlight and activation

const levelOf = (menu) => stack.findIndex((entry) => entry.menu === menu);
const enabledRows = (menu) => [...menu.querySelectorAll('.ds-menu__item:not([aria-disabled="true"])')];

function highlight(level, row) {
  const { menu } = stack[level];
  for (const old of menu.querySelectorAll("[data-highlighted]")) old.removeAttribute("data-highlighted");
  if (!row) {
    menu.removeAttribute("aria-activedescendant");
    return;
  }
  row.setAttribute("data-highlighted", "");
  menu.setAttribute("aria-activedescendant", row.id);
  row.scrollIntoView({ block: "nearest" });
}

function move(level, step) {
  const { menu } = stack[level];
  const rows = enabledRows(menu);
  if (!rows.length) return;
  const index = rows.indexOf(menu.querySelector("[data-highlighted]"));
  const next = index < 0 ? (step > 0 ? 0 : rows.length - 1) : (index + step + rows.length) % rows.length;
  highlight(level, rows[next]);
}

function openSubmenu(level, row) {
  const item = itemOf.get(row);
  if (!item?.submenu || row.getAttribute("aria-disabled") === "true") return;
  if (stack[level + 1]?.parentRow === row) return;
  closeFrom(level);
  const parent = stack[level].menu.getBoundingClientRect();
  const r = row.getBoundingClientRect();
  push(item.submenu, { left: parent.left, right: parent.right, top: r.top, bottom: r.bottom }, "submenu", row);
}

function activate(row) {
  const level = levelOf(row.closest(".ds-menu"));
  const item = itemOf.get(row);
  if (!item || row.getAttribute("aria-disabled") === "true") return;
  if (item.submenu) {
    highlight(level, row);
    openSubmenu(level, row);
    move(level + 1, 1);
    return;
  }
  closeMenus({ restoreFocus: true });
  item.action?.();
}

// ------------------------------------------------------------------ Global events

function onPointerMove(event) {
  if (!stack.length || event.pointerType === "touch") return;
  const row = event.target.closest?.(".ds-menu--floating .ds-menu__item");
  if (!row) return;
  const level = levelOf(row.closest(".ds-menu"));
  if (row.hasAttribute("data-highlighted") && stack.length === level + 1) return;
  highlight(level, row.getAttribute("aria-disabled") === "true" ? null : row);
  clearTimeout(submenuTimer);
  submenuTimer = setTimeout(() => {
    if (itemOf.get(row)?.submenu) openSubmenu(level, row);
    else closeFrom(level);
  }, SUBMENU_DELAY);
}

function onPointerOut(event) {
  const menu = event.target.closest?.(".ds-menu--floating");
  if (!menu || menu.contains(event.relatedTarget)) return;
  const level = levelOf(menu);
  // Keep the row that owns an open submenu highlighted, as macOS does.
  if (level >= 0 && stack.length === level + 1) highlight(level, null);
}

function onPointerDown(event) {
  if (!stack.length) return;
  const target = event.target;
  if (stack.some(({ menu }) => menu.contains(target))) return;
  if (session?.opener?.contains(target) || session?.bar?.element.contains(target)) return;
  closeMenus();
}

function onPointerUp(event) {
  if (!session) return;
  const pressed = session.pressed;
  session.pressed = false;
  // Press on a menu title, drag to an item and release: choose it, as on macOS.
  if (!pressed || performance.now() - session.openedAt < PRESS_RELEASE_DELAY) return;
  const row = event.target.closest?.(".ds-menu--floating .ds-menu__item");
  if (row && !itemOf.get(row)?.submenu) activate(row);
}

function onClick(event) {
  const row = event.target.closest?.(".ds-menu--floating .ds-menu__item");
  if (row) activate(row);
}

function onKeyDown(event) {
  if (!stack.length) return;
  const level = stack.length - 1;
  const { menu } = stack[level];
  const current = menu.querySelector("[data-highlighted]");
  let handled = true;
  switch (event.key) {
    case "ArrowDown": move(level, 1); break;
    case "ArrowUp": move(level, -1); break;
    case "Home": highlight(level, enabledRows(menu)[0] ?? null); break;
    case "End": highlight(level, enabledRows(menu).at(-1) ?? null); break;
    case "ArrowRight":
      if (current && itemOf.get(current)?.submenu) {
        openSubmenu(level, current);
        move(level + 1, 1);
      } else if (session?.bar) {
        session.bar.step(1);
      }
      break;
    case "ArrowLeft":
      if (level > 0) closeFrom(level - 1);
      else if (session?.bar) session.bar.step(-1);
      break;
    case "Enter":
    case " ":
      if (current) activate(current);
      break;
    case "Escape":
      if (level > 0) closeFrom(level - 1);
      else closeMenus({ restoreFocus: true });
      break;
    case "Tab":
      closeMenus({ restoreFocus: true });
      break;
    default:
      handled = typeAhead(level, event.key);
  }
  if (handled) {
    event.preventDefault();
    event.stopPropagation();
  }
}

function typeAhead(level, key) {
  if (key.length !== 1 || !/\S/.test(key)) return false;
  const { menu } = stack[level];
  const rows = enabledRows(menu);
  const start = rows.indexOf(menu.querySelector("[data-highlighted]")) + 1;
  const needle = key.toLowerCase();
  for (let i = 0; i < rows.length; i++) {
    const row = rows[(start + i) % rows.length];
    if (itemOf.get(row).label.toLowerCase().startsWith(needle)) {
      highlight(level, row);
      return true;
    }
  }
  return true;
}

function onScroll(event) {
  if (!stack.length) return;
  if (stack.some(({ menu }) => menu === event.target || menu.contains(event.target))) return;
  closeMenus();
}

document.addEventListener("pointermove", onPointerMove);
document.addEventListener("pointerout", onPointerOut);
document.addEventListener("pointerdown", onPointerDown, true);
document.addEventListener("pointerup", onPointerUp, true);
document.addEventListener("click", onClick);
document.addEventListener("keydown", onKeyDown, true);
document.addEventListener("scroll", onScroll, true);
window.addEventListener("resize", () => closeMenus());
window.addEventListener("blur", () => closeMenus());

// ------------------------------------------------------------------ Context menus

export function attachContextMenu(element, getItems) {
  element.addEventListener("contextmenu", (event) => {
    const items = getItems(event);
    if (!items) return;
    event.preventDefault();
    openMenu(items, { x: event.clientX, y: event.clientY }, { placement: "point" });
  });
}

// ------------------------------------------------------------------ Overflow

const overflowing = (container) => container.scrollWidth > container.clientWidth + 1;

/**
 * Shows as many `items` as fit in `container`, hiding the rest from the end and
 * showing `button` when anything is hidden. Items marked data-overflow="never"
 * always stay. Separators left at an edge or next to another are hidden too.
 */
export function attachOverflow(container, { items, button, onLayout = null }) {
  const layout = () => {
    for (const element of items) element.hidden = false;
    button.hidden = true;
    if (overflowing(container)) {
      button.hidden = false;
      const candidates = items.filter((element) => element.dataset.overflow !== "never");
      for (let i = candidates.length - 1; i >= 0 && overflowing(container); i--) candidates[i].hidden = true;
      hideStraySeparators(items);
    }
    onLayout?.();
  };
  let frame = 0;
  const observer = new ResizeObserver(() => {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(layout);
  });
  observer.observe(container);
  layout();
  return { layout, hiddenItems: () => items.filter((element) => element.hidden), disconnect: () => observer.disconnect() };
}

function hideStraySeparators(items) {
  const isSeparator = (element) => element.matches(".ds-toolbar__separator");
  let previousVisible = null;
  for (const element of items) {
    if (element.hidden) continue;
    if (isSeparator(element) && (!previousVisible || isSeparator(previousVisible))) element.hidden = true;
    else previousVisible = element;
  }
  if (previousVisible && isSeparator(previousVisible)) previousVisible.hidden = true;
}

function overflowButton(className, label) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className;
  button.innerHTML = OVERFLOW_ICON;
  button.setAttribute("aria-label", label);
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-expanded", "false");
  button.title = label;
  button.hidden = true;
  return button;
}

/** Opens `getItems()` from `button` on press, toggling like a menu title. */
function bindMenuButton(button, getItems) {
  button.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    if (session?.opener === button) {
      closeMenus();
      return;
    }
    button.setAttribute("aria-expanded", "true");
    openMenu(getItems(), button, {
      opener: button,
      pressed: true,
      onClose: () => button.setAttribute("aria-expanded", "false"),
    });
  });
  button.addEventListener("keydown", (event) => {
    if (!["Enter", " ", "ArrowDown"].includes(event.key)) return;
    event.preventDefault();
    button.setAttribute("aria-expanded", "true");
    openMenu(getItems(), button, {
      opener: button,
      highlightFirst: true,
      onClose: () => button.setAttribute("aria-expanded", "false"),
    });
  });
}

// ------------------------------------------------------------------ Toolbar overflow

const labelOf = (element) =>
  element.dataset.overflowLabel || element.getAttribute("aria-label") || element.title || element.textContent.trim();

function stateOf(element) {
  for (const attribute of ["aria-pressed", "aria-checked", "aria-selected"]) {
    if (element.hasAttribute(attribute)) return element.getAttribute(attribute) === "true";
  }
  return undefined;
}

function toolbarEntries(elements) {
  const entries = [];
  for (const element of elements) {
    if (element.matches(".ds-toolbar__separator")) {
      entries.push({ separator: true });
    } else if (element.matches(".ds-segmented")) {
      entries.push({ separator: true });
      if (element.getAttribute("aria-label")) entries.push({ header: element.getAttribute("aria-label") });
      for (const segment of element.querySelectorAll(".ds-segmented__segment")) {
        entries.push({ label: labelOf(segment), checked: stateOf(segment), disabled: segment.disabled, action: () => segment.click() });
      }
      entries.push({ separator: true });
    } else {
      entries.push({ label: labelOf(element), checked: stateOf(element), disabled: element.disabled, action: () => element.click() });
    }
  }
  return entries;
}

/**
 * Moves toolbar items that don't fit into a » menu, starting from the trailing end.
 * Keep the title, sidebar and inspector toggles with data-overflow="never".
 * The » button is inserted before `before` (default: the end of the toolbar).
 */
export function attachToolbarOverflow(toolbar, { label = "More Toolbar Items", before = null } = {}) {
  const items = [...toolbar.children].filter(
    (element) => !element.matches(".ds-toolbar__spacer, .ds-toolbar__overflow"),
  );
  const button = overflowButton("ds-button ds-button--ghost ds-button--icon ds-toolbar__overflow", label);
  button.dataset.overflow = "never";
  toolbar.insertBefore(button, before);
  const overflow = attachOverflow(toolbar, { items, button });
  bindMenuButton(button, () => toolbarEntries(overflow.hiddenItems()));
  return overflow;
}

// ------------------------------------------------------------------ Menu bar

/**
 * Builds an in-window menu bar from `menus` ([{ label, items }]). Titles that
 * don't fit move into a » menu as submenus. Press a title to open its menu;
 * while one is open, moving over another title switches to it.
 */
export function attachMenuBar(bar, menus, { label = "Menus", overflowLabel = "More Menus" } = {}) {
  bar.classList.add("ds-menu-bar");
  bar.setAttribute("role", "menubar");
  bar.setAttribute("aria-label", label);
  bar.replaceChildren();

  const titles = menus.map((menu, index) => {
    const title = document.createElement("button");
    title.type = "button";
    title.className = "ds-menu-bar__item";
    title.textContent = menu.label;
    title.setAttribute("role", "menuitem");
    title.setAttribute("aria-haspopup", "menu");
    title.setAttribute("aria-expanded", "false");
    title.tabIndex = index === 0 ? 0 : -1;
    bar.append(title);
    return title;
  });
  const more = overflowButton("ds-menu-bar__item ds-menu-bar__overflow", overflowLabel);
  more.setAttribute("role", "menuitem");
  more.tabIndex = -1;
  bar.append(more);

  const menuFor = new Map(titles.map((title, index) => [title, menus[index]]));
  let active = null;

  const itemsFor = (title) =>
    title === more
      ? titles.filter((t) => t.hidden).map((t) => ({ label: menuFor.get(t).label, submenu: menuFor.get(t).items }))
      : menuFor.get(title).items;

  const visibleTitles = () => [...titles, more].filter((t) => !t.hidden);

  const controller = {
    element: bar,
    step(direction) {
      const visible = visibleTitles();
      const index = visible.indexOf(active);
      show(visible[(index + direction + visible.length) % visible.length], { highlightFirst: true });
    },
  };

  function show(title, { highlightFirst = false, pressed = false } = {}) {
    openMenu(itemsFor(title), title, {
      opener: title,
      bar: controller,
      highlightFirst,
      pressed,
      onClose: () => {
        title.setAttribute("aria-expanded", "false");
        if (active === title) active = null;
      },
    });
    active = title;
    title.setAttribute("aria-expanded", "true");
    for (const t of [...titles, more]) t.tabIndex = t === title ? 0 : -1;
  }

  bar.addEventListener("pointerdown", (event) => {
    const title = event.target.closest(".ds-menu-bar__item");
    if (!title || event.button !== 0) return;
    event.preventDefault();
    if (active === title) closeMenus();
    else show(title, { pressed: true });
  });

  bar.addEventListener("pointerover", (event) => {
    const title = event.target.closest(".ds-menu-bar__item");
    if (title && active && active !== title) show(title);
  });

  bar.addEventListener("keydown", (event) => {
    const title = event.target.closest(".ds-menu-bar__item");
    if (!title || isMenuOpen()) return;
    const visible = visibleTitles();
    const index = visible.indexOf(title);
    if (["Enter", " ", "ArrowDown"].includes(event.key)) show(title, { highlightFirst: true });
    else if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
      const next = visible[(index + (event.key === "ArrowRight" ? 1 : -1) + visible.length) % visible.length];
      for (const t of visible) t.tabIndex = t === next ? 0 : -1;
      next.focus();
    } else return;
    event.preventDefault();
  });

  return attachOverflow(bar, { items: titles, button: more });
}
