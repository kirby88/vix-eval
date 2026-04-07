# Plan: Add French (fr) Language Support

## Context
Issue #3460 requests French language support. The codebase has a lightweight custom i18n system in `ui/src/i18n/` supporting 6 locales: en, zh-CN, zh-TW, pt-BR, de, es. Adding French follows a well-established pattern: create a locale file, register it in the registry, update the `Locale` type, and update the `languages` section in all existing locale files so users can see "Français" in the language picker.

## Files to Modify / Create

### 1. Create `ui/src/i18n/locales/fr.ts` (new file)
Full French translation of every key in `en.ts`. Structure mirrors existing locale files (e.g. `de.ts`, `es.ts`). Export name: `fr`. Include all sections: `common`, `nav`, `tabs`, `subtitles`, `overview` (with all nested keys including `access`, `snapshot`, `stats`, `notes`, `auth`, `pairing`, `insecure`, `connection`, `cards`, `attention`, `eventLog`, `logTail`, `quickActions`, `palette`), `login`, `chat`, `languages`, `cron` (with `summary`, `jobs`, `runs`, `form`, `jobList`, `jobDetail`, `jobState`, `runEntry`, `errors`).

The `languages` section must name all supported locales in French, including the new `fr` entry:
```typescript
languages: {
  en: "Anglais",
  zhCN: "Chinois simplifié (简体中文)",
  zhTW: "Chinois traditionnel (繁體中文)",
  ptBR: "Portugais brésilien (Português)",
  de: "Allemand (Deutsch)",
  es: "Espagnol (Español)",
  fr: "Français",
},
```

### 2. `ui/src/i18n/lib/types.ts` (line 3)
Add `"fr"` to the `Locale` union:
```typescript
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

### 3. `ui/src/i18n/lib/registry.ts`
- Add `"fr"` to `LAZY_LOCALES` array (line 13)
- Add entry to `LAZY_LOCALE_REGISTRY`:
  ```typescript
  fr: {
    exportName: "fr",
    loader: () => import("../locales/fr.ts"),
  },
  ```
- Add French browser detection to `resolveNavigatorLocale`:
  ```typescript
  if (navLang.startsWith("fr")) return "fr";
  ```
  (before the final `return DEFAULT_LOCALE`)

### 4. `ui/src/i18n/locales/en.ts` (languages section, line 171–178)
Add French entry:
```typescript
fr: "Français (French)",
```

### 5. `ui/src/i18n/locales/de.ts` (languages section)
Add:
```typescript
fr: "Französisch (Français)",
```

### 6. `ui/src/i18n/locales/es.ts` (languages section)
Add:
```typescript
fr: "Francés (Français)",
```

### 7. `ui/src/i18n/locales/pt-BR.ts` (languages section)
Add:
```typescript
fr: "Francês (Français)",
```

### 8. `ui/src/i18n/locales/zh-CN.ts` (languages section)
Add:
```typescript
fr: "法语 (Français)",
```

### 9. `ui/src/i18n/locales/zh-TW.ts` (languages section)
Add:
```typescript
fr: "法語 (Français)",
```

### 10. `src/i18n/registry.test.ts` (line 23)
Update the `SUPPORTED_LOCALES` assertion:
```typescript
expect(SUPPORTED_LOCALES).toEqual(["en", "zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"]);
```
Add a `resolveNavigatorLocale` test case:
```typescript
expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
```
Add a lazy-load test for French:
```typescript
const fr = await loadLazyLocaleTranslation("fr");
expect(getNestedTranslation(fr, "common", "health")).toBe("Santé");
expect(getNestedTranslation(fr, "languages", "de")).toBe("Allemand (Deutsch)");
```

### 11. `ui/src/i18n/test/translate.test.ts` (line 111–115)
Extend the "keeps version label" test to include `fr`:
```typescript
import { fr } from "../locales/fr.ts";
// ...
expect((fr.common as { version?: string }).version).toBeTruthy();
```

## Verification
1. `pnpm build` — no TypeScript errors or dynamic import warnings
2. `pnpm test -- src/i18n/registry.test.ts` — SUPPORTED_LOCALES includes fr, browser detection works, lazy load resolves
3. `pnpm test -- ui/src/i18n/test/translate.test.ts` — version label test passes for fr
4. `pnpm check` — lint/format passes
