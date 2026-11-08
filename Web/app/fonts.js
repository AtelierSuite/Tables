// Which fonts this device has, for the font pop-up.
//
// Browsers can't open the system font panel. Where the Local Font Access API
// exists (Chrome and Edge on desktop), every installed family can be listed once
// the user allows it. Everywhere else, a list of common families is checked by
// measuring text, which needs no permission.

const COMMON_FAMILIES = [
  // Across platforms
  "Arial", "Arial Black", "Aptos", "Calibri", "Cambria", "Candara", "Century Gothic", "Comic Sans MS", "Consolas",
  "Constantia", "Corbel", "Courier New", "Franklin Gothic Medium", "Garamond", "Georgia", "Impact", "Palatino Linotype",
  "Rockwell", "Segoe UI", "Tahoma", "Times New Roman", "Trebuchet MS", "Verdana",
  // Apple
  "American Typewriter", "Avenir", "Avenir Next", "Baskerville", "Didot", "Futura", "Geneva", "Gill Sans", "Helvetica",
  "Hoefler Text", "Lucida Grande", "Menlo", "Monaco", "Optima", "Palatino", "SF Pro", "Times",
  // Japanese, Korean and Chinese
  "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Hiragino Maru Gothic ProN", "Hiragino Mincho ProN", "Yu Gothic",
  "Yu Mincho", "Meiryo", "MS Gothic", "MS Mincho", "BIZ UDPGothic", "Apple SD Gothic Neo", "Malgun Gothic",
  "Nanum Gothic", "Nanum Myeongjo", "PingFang SC", "PingFang TC", "Songti SC", "Songti TC", "Heiti SC",
  "Microsoft YaHei", "Microsoft JhengHei", "SimSun", "SimHei", "DFKai-SB",
  // Linux and free fonts
  "Noto Sans", "Noto Serif", "Noto Sans JP", "Noto Serif JP", "Noto Sans KR", "Noto Sans SC", "Noto Sans TC",
  "Roboto", "Open Sans", "Source Sans 3", "Ubuntu", "DejaVu Sans", "DejaVu Serif", "Liberation Sans", "Liberation Serif",
];

/** The engine's name for the system font; offering it as a family would mean the same as "System Font". */
const SYSTEM_FONT_NAME = "Helvetica Neue";

let detected = null;
let localFamilies = null;

const probe = (() => {
  let canvas = null;
  return () => {
    canvas ??= document.createElement("canvas");
    return canvas.getContext("2d");
  };
})();

/** Whether a family is installed: text set in it measures differently from every generic fallback. */
export function isInstalled(family) {
  const ctx = probe();
  const sample = "mmmmmmmmmmlliWWwww@#&1234567890";
  for (const generic of ["serif", "sans-serif", "cursive"]) {
    ctx.font = `64px ${generic}`;
    const fallback = ctx.measureText(sample).width;
    ctx.font = `64px "${family.replace(/["\\]/g, "\\$&")}", ${generic}`;
    if (ctx.measureText(sample).width !== fallback) return true;
  }
  return false;
}

const byName = (a, b) => a.localeCompare(b, undefined, { sensitivity: "base" });

/** Installed families: every one, if the user allowed listing them, otherwise the common ones found here. */
export function installedFamilies() {
  if (localFamilies) return localFamilies;
  detected ??= COMMON_FAMILIES.filter((family) => family !== SYSTEM_FONT_NAME && isInstalled(family)).sort(byName);
  return detected;
}

/** Whether the browser can list every installed font (asking the user first). */
export const canListAllFonts = typeof window.queryLocalFonts === "function";

export const hasListedAllFonts = () => localFamilies !== null;

/** Asks to list every installed family. Must run during a user action. Resolves false if refused. */
export async function listAllFonts() {
  if (!canListAllFonts) return false;
  try {
    const fonts = await window.queryLocalFonts();
    const families = new Set(fonts.map((font) => font.family).filter((family) => family && !family.startsWith(".")));
    families.delete(SYSTEM_FONT_NAME);
    localFamilies = [...families].sort(byName);
    return localFamilies.length > 0;
  } catch {
    return false;
  }
}
