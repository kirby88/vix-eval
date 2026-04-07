# Add French (fr) Language Support

## Context
Issue #3460 requests French language support. The UI has a custom TypeScript i18n system under `ui/src/i18n/` with 6 supported locales (en, zh-CN, zh-TW, pt-BR, de, es). Adding French follows a clear, established pattern. No external dependencies are needed.

## Files to Change

| File | Change |
|------|--------|
| `ui/src/i18n/lib/types.ts` | Add `"fr"` to the `Locale` union type |
| `ui/src/i18n/lib/registry.ts` | Add `"fr"` to `LAZY_LOCALES`, add entry to `LAZY_LOCALE_REGISTRY`, add `fr` branch to `resolveNavigatorLocale()` |
| `ui/src/i18n/locales/fr.ts` | **New file** — complete French translation object `fr: TranslationMap` |
| `ui/src/i18n/locales/en.ts` | Add `fr: "Français (French)"` to `languages` section |
| `ui/src/i18n/locales/de.ts` | Add `fr: "Französisch (Français)"` to `languages` section |
| `ui/src/i18n/locales/es.ts` | Add `fr: "Francés (Français)"` to `languages` section |
| `ui/src/i18n/locales/zh-CN.ts` | Add `fr: "法语 (Français)"` to `languages` section |
| `ui/src/i18n/locales/zh-TW.ts` | Add `fr: "法語 (Français)"` to `languages` section |
| `ui/src/i18n/locales/pt-BR.ts` | Add `fr: "Francês (Français)"` to `languages` section |
| `src/i18n/registry.test.ts` | Update `SUPPORTED_LOCALES` assertion; add `fr` test cases for `resolveNavigatorLocale` and `loadLazyLocaleTranslation` |

## Step-by-Step Plan

### 1. Update `Locale` type (`ui/src/i18n/lib/types.ts`)
```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

### 2. Update registry (`ui/src/i18n/lib/registry.ts`)
- Add `"fr"` to `LAZY_LOCALES` array
- Add entry to `LAZY_LOCALE_REGISTRY`:
  ```ts
  fr: {
    exportName: "fr",
    loader: () => import("../locales/fr.ts"),
  },
  ```
- Add `fr` branch to `resolveNavigatorLocale`:
  ```ts
  if (navLang.startsWith("fr")) {
    return "fr";
  }
  ```

### 3. Create `ui/src/i18n/locales/fr.ts`
Full translation of all keys from `en.ts` into French, following the same structure. Export as `export const fr: TranslationMap`. Key sections: `common`, `nav`, `tabs`, `subtitles`, `overview`, `login`, `chat`, `languages`, `cron` (summary, jobs, runs, form, jobList, jobDetail, jobState, runEntry, errors).

The `languages` section in `fr.ts` will list all languages in French:
```ts
languages: {
  en: "Anglais (English)",
  zhCN: "Chinois simplifié (简体中文)",
  zhTW: "Chinois traditionnel (繁體中文)",
  ptBR: "Portugais brésilien (Português)",
  de: "Allemand (Deutsch)",
  es: "Espagnol (Español)",
  fr: "Français",
}
```

### 4. Add `fr` key to `languages` in all existing locale files
- `en.ts`: `fr: "Français (French)"`
- `de.ts`: `fr: "Französisch (Français)"`
- `es.ts`: `fr: "Francés (Français)"`
- `zh-CN.ts`: `fr: "法语 (Français)"`
- `zh-TW.ts`: `fr: "法語 (Français)"`
- `pt-BR.ts`: `fr: "Francês (Français)"`

### 5. Update tests (`src/i18n/registry.test.ts`)
- Update `SUPPORTED_LOCALES` assertion: add `"fr"` to the expected array
- Add `resolveNavigatorLocale("fr-FR")` → `"fr"` assertion
- Add `loadLazyLocaleTranslation("fr")` test asserting a known French string (e.g. `common.health` = `"Santé"`)

## Verification
```bash
pnpm test -- src/i18n/registry.test.ts
pnpm test -- ui/src/i18n/test/translate.test.ts
pnpm build   # check for TypeScript errors and [INEFFECTIVE_DYNAMIC_IMPORT] warnings
```
