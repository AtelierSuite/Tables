// Closing a sheet the way it opened: it slides back up under the toolbar and its
// backdrop fades, then it is removed. With Reduce Motion the durations are zero
// (tokens.css), so it goes at once.

/**
 * @param {HTMLElement} backdrop the .ds-sheet-backdrop holding the sheet
 * @returns {Promise<void>} once it has gone
 */
export function dismissSheet(backdrop) {
  if (!backdrop.isConnected || backdrop.classList.contains("is-closing")) return Promise.resolve();
  backdrop.classList.add("is-closing");
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(fallback);
      backdrop.remove();
      resolve();
    };
    const duration = parseFloat(getComputedStyle(backdrop).animationDuration) * 1000 || 0;
    // animationend may never come (zero duration, hidden tab): don't depend on it.
    const fallback = setTimeout(done, duration + 50);
    backdrop.addEventListener("animationend", (event) => {
      if (event.target === backdrop) done();
    }, { once: true });
  });
}
