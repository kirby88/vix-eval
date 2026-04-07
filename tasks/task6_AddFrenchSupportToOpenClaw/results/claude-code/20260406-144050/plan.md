# Plan: Add French (fr) Language Support

## Context
Issue #3460 requests French language support in the OpenClaw UI dashboard. The UI uses a TypeScript i18n system with lazy-loaded locale files. Currently 6 locales exist: `en`, `zh-CN`, `zh-TW`, `pt-BR`, `de`, `es`. French needs to be added as a 7th, following the same patterns.

---

## Files to Modify

### 1. `ui/src/i18n/lib/types.ts`
Add `"fr"` to the `Locale` union type:
```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

### 2. `ui/src/i18n/lib/registry.ts`
- Add `"fr"` to `LAZY_LOCALES`
- Add entry to `LAZY_LOCALE_REGISTRY`:
  ```ts
  fr: {
    exportName: "fr",
    loader: () => import("../locales/fr.ts"),
  },
  ```
- Add `fr-*` branch to `resolveNavigatorLocale()`:
  ```ts
  if (navLang.startsWith("fr")) {
    return "fr";
  }
  ```

### 3. `ui/src/i18n/locales/fr.ts` *(new file)*
Create with complete French translations matching the structure of `de.ts` and `es.ts`. Include all keys from `en.ts`:
- `common`, `nav`, `tabs`, `subtitles`
- `overview` (access, snapshot, stats, notes, auth, pairing, insecure, connection, cards, attention, eventLog, logTail, quickActions, palette)
- `login`, `chat`
- `languages` — include entry for `fr`: `"Français (French)"`
- `cron` (summary, jobs, runs, form, jobList, jobDetail, jobState, runEntry, errors)

Export name: `fr` (simple, no underscore needed unlike `zh_CN`/`pt_BR`).

### 4. `ui/src/i18n/locales/en.ts`
Add French to the `languages` map:
```ts
fr: "Français (French)",
```

### 5. All other locale files — add `fr` to their `languages` section
- `ui/src/i18n/locales/zh-CN.ts` → `fr: "法语（法国）"`
- `ui/src/i18n/locales/zh-TW.ts` → `fr: "法語（法國）"`
- `ui/src/i18n/locales/pt-BR.ts` → `fr: "Français (Francês)"`
- `ui/src/i18n/locales/de.ts` → `fr: "Französisch (Français)"`
- `ui/src/i18n/locales/es.ts` → `fr: "Francés (Français)"`

### 6. `src/i18n/registry.test.ts`
- Update the `SUPPORTED_LOCALES` assertion to include `"fr"`:
  ```ts
  expect(SUPPORTED_LOCALES).toEqual(["en", "zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"]);
  ```
- Add browser locale resolution test:
  ```ts
  expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
  expect(resolveNavigatorLocale("fr-CA")).toBe("fr");
  ```
- Add lazy load assertion for `fr`:
  ```ts
  const fr = await loadLazyLocaleTranslation("fr");
  expect(getNestedTranslation(fr, "common", "health")).toBe("Santé");
  ```

---

## Translation quality notes
- `fr.ts` will be a **complete** translation (like `en.ts`), not a partial (like `de.ts`).
- Use standard French UI terminology (e.g. "Paramètres" for Settings, "Agents" stays, "Tableau de bord" unnecessary since it's not a visible heading).
- Technical terms like "Gateway", "Cron", "WebSocket", "Token", "Session" stay in English/technical form per standard French software practice.

---

## Verification
1. `pnpm build` — must pass with no type errors or `[INEFFECTIVE_DYNAMIC_IMPORT]` warnings
2. `pnpm test` — existing tests must pass; new assertions in `registry.test.ts` must pass
3. Manual check: open the UI, switch language to Français, verify all visible strings render in French with no missing-key fallbacks showing raw keys
