# Plan: Add French (fr) Language Support

## Context

Issue #3460 requests French language support in the OpenClaw UI. The UI uses a custom TypeScript i18n system (no external library) with lazy-loaded locale files under `ui/src/i18n/locales/`. Currently 6 languages are supported: `en`, `zh-CN`, `zh-TW`, `pt-BR`, `de`, `es`. Adding French requires changes to 4 files and creation of 1 new file.

## Files to Modify

| File | Change |
|------|--------|
| `ui/src/i18n/lib/types.ts` | Add `"fr"` to the `Locale` union type |
| `ui/src/i18n/lib/registry.ts` | Register `fr` in `LAZY_LOCALES`, `LAZY_LOCALE_REGISTRY`, and `resolveNavigatorLocale` |
| `ui/src/i18n/locales/en.ts` | Add `fr` key to the `languages` section |
| `ui/src/i18n/locales/fr.ts` | **New file** — complete French translation map |

## Step-by-Step Changes

### 1. `ui/src/i18n/lib/types.ts`
Add `"fr"` to the `Locale` union:
```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

### 2. `ui/src/i18n/lib/registry.ts`
- Add `"fr"` to `LAZY_LOCALES` array
- Add `fr` entry to `LAZY_LOCALE_REGISTRY` with `exportName: "fr"` and `loader: () => import("../locales/fr.ts")`
- Add `if (navLang.startsWith("fr")) return "fr";` to `resolveNavigatorLocale`

### 3. `ui/src/i18n/locales/en.ts` — `languages` section
Add one line:
```ts
fr: "Français (French)",
```

### 4. New file: `ui/src/i18n/locales/fr.ts`
Full French translation following the exact structure of `es.ts` / `en.ts`. All top-level keys: `common`, `nav`, `tabs`, `subtitles`, `overview`, `login`, `chat`, `languages`, `cron` (with all sub-keys). Must include `common.version` so the existing test at `translate.test.ts:111-115` continues to pass if extended.

Key translation decisions:
- `common.version` → `"Version"` (same, used as label)
- `nav.agent` → `"Agent"`, `nav.settings` → `"Paramètres"`
- `tabs.cron` → `"Tâches Cron"`, `tabs.skills` → `"Compétences"`
- `overview.access.title` → `"Accès à la passerelle"`
- `languages.fr` → `"Français"` (self-referential, no parenthetical needed)
- All other language names in French: `languages.en` → `"Anglais (English)"`, etc.

## Existing Patterns to Follow

- `es.ts` is the most complete non-English locale — use it as the structural template
- Export name must match the locale key exactly: `export const fr: TranslationMap = { ... }`
- Only include keys that differ meaningfully from English (the system falls back to `en` for missing keys), but for completeness follow what `es.ts` does (full coverage)
- Technical terms like `Tailscale`, `WebSocket`, `Cron`, `IANA`, `HTTPS` stay untranslated

## No Test Changes Required

The existing test at line 111-115 only checks `pt_BR`, `zh_CN`, `zh_TW` — it will continue to pass. No new test cases are needed for `fr` since the pattern is already covered.

## Verification

After implementation:
```bash
pnpm build        # Check for TypeScript errors and [INEFFECTIVE_DYNAMIC_IMPORT] warnings
pnpm test -- ui/src/i18n/test/translate.test.ts   # Run i18n tests
pnpm check        # Lint + format check
```

Manually: set `localStorage.setItem("openclaw.i18n.locale", "fr")` in the browser and reload the UI to confirm French strings render.
