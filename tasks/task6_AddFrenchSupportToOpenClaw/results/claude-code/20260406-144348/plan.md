# Plan: Add French (fr) Language Support

## Context
Issue #3460 requests French language support for the OpenClaw UI dashboard. The UI already has an i18n system supporting en, zh-CN, zh-TW, pt-BR, de, and es. French is a natural addition following the same pattern. The i18n system lazy-loads all non-English locales, persists the user's locale preference in localStorage, and falls back to English for any missing keys.

## Files to Modify / Create

### 1. CREATE `ui/src/i18n/locales/fr.ts`
New French translation file following the `es.ts` pattern (same structure, French text). Must cover all sections: `common`, `nav`, `tabs`, `subtitles`, `overview`, `chat`, `languages`, and `cron`. Export name must be `fr` (matches registry `exportName`).

### 2. MODIFY `ui/src/i18n/lib/types.ts`
Add `"fr"` to the `Locale` union type:
```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

### 3. MODIFY `ui/src/i18n/lib/registry.ts`
- Add `"fr"` to the `LAZY_LOCALES` array
- Add entry to `LAZY_LOCALE_REGISTRY`:
  ```ts
  fr: { exportName: "fr", loader: () => import("../locales/fr.ts") }
  ```
- Add French handling to `resolveNavigatorLocale`:
  ```ts
  if (navLang.startsWith("fr")) { return "fr"; }
  ```

### 4. MODIFY `ui/src/i18n/locales/en.ts`
Add `fr` key to `languages` section:
```ts
fr: "Français (French)",
```

### 5. MODIFY all other locale files (5 files)
Add the `fr` key to each locale's `languages` section with a localized name for French:
- `zh-CN.ts`: `fr: "法语 (Français)"`
- `zh-TW.ts`: `fr: "法語 (Français)"`
- `es.ts`: `fr: "Francés (Français)"`
- `de.ts`: `fr: "Französisch (Français)"`
- `pt-BR.ts`: `fr: "Francês (Français)"`

### 6. MODIFY `ui/src/i18n/test/translate.test.ts`
The test `"keeps the version label available in shipped locales"` checks `common.version` for pt_BR, zh_CN, zh_TW. Add `fr` to this test (import `fr` from the new file and add the assertion). Also ensure `fr` is included in the navigator resolution test if applicable.

## French Locale Coverage Strategy
Model after `es.ts` (most complete non-English locale at 348 lines). Provide translations for all top-level sections. The fallback-to-English mechanism means missing keys won't break the UI, but full coverage is the goal.

Key French translations (representative):
- `common.health` → "État"
- `common.online` → "En ligne"
- `nav.settings` → "Paramètres"
- `tabs.overview` → "Aperçu"
- `cron.*` → full French Cron UI translations
- `languages.fr` → "Français"

## Verification
1. `pnpm build` — TypeScript must compile cleanly, no `[INEFFECTIVE_DYNAMIC_IMPORT]` warnings
2. `pnpm test -- ui/src/i18n/test/translate.test.ts` — all i18n tests must pass
3. `pnpm tsgo` — type-check passes with new `"fr"` in `Locale` union
4. Manual smoke: load the UI, open Language selector, verify "Français (French)" appears and switching to it renders French strings
