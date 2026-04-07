## Implementation Plan: French (fr) Language Support

### Overview

The codebase has a well-structured i18n system in `/workspace/ui/src/i18n/`. Languages are added by:
1. Creating a new locale file under `locales/`
2. Registering the locale in `lib/registry.ts` (the `Locale` type, `LAZY_LOCALES` array, and `LAZY_LOCALE_REGISTRY`)
3. Updating `lib/types.ts` to include `"fr"` in the `Locale` union type
4. Updating every existing locale's `languages` key to include a French entry
5. Updating the test in `src/i18n/registry.test.ts` to expect `"fr"` in `SUPPORTED_LOCALES`

French follows the `"de"` and `"es"` pattern (simple two-letter code, no region suffix), so it is a straightforward addition.

---

### Step-by-Step Implementation

#### Step 1: Create `/workspace/ui/src/i18n/locales/fr.ts`

This is the main translation file. It must export `const fr: TranslationMap` and cover every key present in `en.ts`. The structure must mirror `en.ts` exactly.

Sections to include (drawn from `en.ts`):
- `common` — standard UI labels
- `nav` — navigation items
- `tabs` — tab labels
- `subtitles` — tab subtitles
- `overview` — the gateway access/snapshot/stats/notes/auth/pairing/insecure/connection/cards/attention/eventLog/logTail/quickActions/palette subsections
- `login` — login panel
- `chat` — chat panel
- `languages` — language picker labels (must name all 7 languages in French, including itself: `fr: "Français (French)"`)
- `cron` — full cron section (summary/jobs/runs/form/jobList/jobDetail/jobState/runEntry/errors)

The `languages` section should follow the pattern seen in other locales: native name + English gloss in parentheses, e.g.:
```
en: "Anglais (English)",
zhCN: "Chinois simplifié (简体中文)",
zhTW: "Chinois traditionnel (繁體中文)",
ptBR: "Portugais brésilien (Português)",
de: "Allemand (Deutsch)",
es: "Espagnol (Español)",
fr: "Français",
```

#### Step 2: Update `/workspace/ui/src/i18n/lib/types.ts`

Add `"fr"` to the `Locale` union type:

```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

#### Step 3: Update `/workspace/ui/src/i18n/lib/registry.ts`

Three changes:

1. Add `"fr"` to `LAZY_LOCALES`:
```ts
const LAZY_LOCALES: readonly LazyLocale[] = ["zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"];
```

2. Add an entry to `LAZY_LOCALE_REGISTRY`:
```ts
fr: {
  exportName: "fr",
  loader: () => import("../locales/fr.ts"),
},
```

3. Add a `resolveNavigatorLocale` branch for French:
```ts
if (navLang.startsWith("fr")) {
  return "fr";
}
```
This branch must be inserted before the final `return DEFAULT_LOCALE` line.

#### Step 4: Update all existing locale files to add `"fr"` to their `languages` sections

Each locale file needs a `fr` key added to its `languages` object. The translations for each file:

- `/workspace/ui/src/i18n/locales/en.ts`: `fr: "Français (French)"`
- `/workspace/ui/src/i18n/locales/de.ts`: `fr: "Französisch (Français)"`
- `/workspace/ui/src/i18n/locales/es.ts`: `fr: "Francés (Français)"`
- `/workspace/ui/src/i18n/locales/pt-BR.ts`: `fr: "Francês (Français)"`
- `/workspace/ui/src/i18n/locales/zh-CN.ts`: `fr: "法语 (Français)"`
- `/workspace/ui/src/i18n/locales/zh-TW.ts`: `fr: "法語 (Français)"`

#### Step 5: Update `/workspace/src/i18n/registry.test.ts`

The test at line `expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es"])` must be updated to:
```ts
expect(SUPPORTED_LOCALES).toEqual(["en", "zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"]);
```

Also add a `resolveNavigatorLocale` assertion:
```ts
expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
expect(resolveNavigatorLocale("fr-CA")).toBe("fr");
```

And add a `loadLazyLocaleTranslation` assertion for `fr`:
```ts
const fr = await loadLazyLocaleTranslation("fr");
expect(getNestedTranslation(fr, "common", "health")).toBe("Santé");
expect(getNestedTranslation(fr, "languages", "fr")).toBe("Français");
```

#### Step 6: Create a PR-ready git branch

After all file changes, create a new branch named something like `feat/french-i18n` or `feat/fr-locale`, stage all changed files, and commit with a descriptive message. The branch should be based on the current HEAD.

---

### Dependency Sequencing

The order matters slightly:
1. `types.ts` first — it defines the `Locale` type that `registry.ts` and `fr.ts` depend on.
2. `fr.ts` second — the actual translation file.
3. `registry.ts` third — references `fr.ts` via dynamic import.
4. Existing locale files fourth — these only add a `fr` key to `languages`, no ordering dependency.
5. `registry.test.ts` last — tests the final state of everything.

---

### Potential Challenges

- The `fr.ts` file must be complete. The `translate.ts` fallback logic falls back to English for missing keys, so incomplete translations won't cause runtime errors, but the test explicitly checks `getNestedTranslation(fr, "common", "health")` which means at least that key must be present.
- The `cron` section is large. It must be copied fully from `en.ts` and translated, following the pattern established in `es.ts` and `zh-CN.ts` (both have complete cron sections).
- The `de.ts` and `zh-TW.ts` locales do NOT have a `cron` section — the `fr.ts` should follow the fuller `es.ts`/`zh-CN.ts`/`pt-BR.ts` pattern and include a complete `cron` section.
- The `pt-BR.ts` does NOT have a `cron` section either (it stops after `languages`). The `es.ts` and `zh-CN.ts` are the best complete references.

---

### Critical Files for Implementation

- `/workspace/ui/src/i18n/locales/fr.ts` - New file to create; the complete French translation map
- `/workspace/ui/src/i18n/lib/registry.ts` - Register `"fr"` as a lazy locale with its loader and navigator resolver
- `/workspace/ui/src/i18n/lib/types.ts` - Add `"fr"` to the `Locale` union type
- `/workspace/src/i18n/registry.test.ts` - Update test assertions to include `"fr"` in SUPPORTED_LOCALES
- `/workspace/ui/src/i18n/locales/en.ts` - Pattern reference and must add `fr` key to its `languages` section