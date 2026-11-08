// Strings in the user's language, from the tables Web/build.sh converts out of
// the string catalogues (Web/strings, Engine/*/Localizable.xcstrings).

let table = {};
export let language = "en";

/** The supported language closest to the browser's preferences. */
function pickLanguage(available) {
  // ?lang=ja picks a language for this visit, for checking translations.
  const requested = new URLSearchParams(location.search).get("lang");
  for (const preferred of [...(requested ? [requested] : []), ...(navigator.languages ?? [navigator.language])]) {
    const tag = preferred.toLowerCase();
    if (tag.startsWith("zh")) {
      const traditional = /hant|tw|hk|mo/.test(tag);
      const choice = traditional ? "zh-Hant" : "zh-Hans";
      if (available.includes(choice)) return choice;
      continue;
    }
    const base = tag.split("-")[0];
    const match = available.find((code) => code.toLowerCase() === tag || code.toLowerCase() === base);
    if (match) return match;
  }
  return "en";
}

export async function loadStrings() {
  const base = new URL("../build/strings/", import.meta.url);
  let available = ["en"];
  try {
    available = (await (await fetch(new URL("languages.json", base))).json()).languages;
  } catch {
    // Only English then.
  }
  language = pickLanguage(available);
  for (const code of [language, "en"]) {
    try {
      const response = await fetch(new URL(`app-${code}.json`, base));
      if (response.ok) {
        table = await response.json();
        language = code;
        break;
      }
    } catch {
      // Try the next.
    }
  }
  document.documentElement.lang = language;
  return table;
}

/**
 * The string for `key`, with Apple-style placeholders (%@, %lld, %d, %1$@) filled in order.
 * @param {string} key
 * @param {...(string|number)} values
 */
export function t(key, ...values) {
  let text = table[key] ?? key;
  let index = 0;
  text = text.replace(/%(?:(\d+)\$)?(@|lld|ld|d|f|\.\d+f)/g, (_, position) => {
    const value = values[position ? Number(position) - 1 : index++];
    return value == null ? "" : String(value);
  });
  return text;
}

export function strings() {
  return table;
}
