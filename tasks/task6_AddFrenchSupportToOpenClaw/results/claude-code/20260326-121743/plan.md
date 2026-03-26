# Add French (fr) Language Support

## Context

Issue #3460 requests French language support. The UI already supports 6 locales (en, zh-CN, zh-TW, pt-BR, de, es) via a custom i18n system in `ui/src/i18n/`. Adding French follows the same pattern used for Spanish (es), which is the most complete non-English locale.

## Files to Modify

| File | Change |
|------|--------|
| `ui/src/i18n/lib/types.ts` | Add `"fr"` to `Locale` union type |
| `ui/src/i18n/lib/registry.ts` | Register fr in `LAZY_LOCALES`, `LAZY_LOCALE_REGISTRY`, and `resolveNavigatorLocale` |
| `ui/src/i18n/locales/en.ts` | Add `fr: "Français (French)"` to `languages` |
| `ui/src/i18n/locales/de.ts` | Add `fr: "Französisch (Français)"` to `languages` |
| `ui/src/i18n/locales/es.ts` | Add `fr: "Francés (Français)"` to `languages` |
| `ui/src/i18n/locales/pt-BR.ts` | Add `fr: "Français (Francês)"` to `languages` |
| `ui/src/i18n/locales/zh-CN.ts` | Add `fr: "Français (法语)"` to `languages` |
| `ui/src/i18n/locales/zh-TW.ts` | Add `fr: "Français (法語)"` to `languages` |
| `ui/src/i18n/locales/fr.ts` | **New file** — complete French translation |
| `src/i18n/registry.test.ts` | Add "fr" to `SUPPORTED_LOCALES` expectation, add fr resolution + load tests |
| `ui/src/i18n/test/translate.test.ts` | Add fr to version label test |

## Implementation Steps

### 1. Create `ui/src/i18n/locales/fr.ts`

Full French translation following the `es.ts` structure (which includes `common`, `nav`, `tabs`, `subtitles`, `overview`, `login`, `chat`, `languages`, and the full `cron` section). Export as `export const fr: TranslationMap`.

Key translations:
- `common.health` → `"Santé"`, `common.connect` → `"Connecter"`, `common.refresh` → `"Actualiser"`
- `nav.control` → `"Contrôle"`, `nav.settings` → `"Paramètres"`
- `tabs.overview` → `"Aperçu"`, `tabs.cron` → `"Tâches Cron"`, `tabs.logs` → `"Journaux"`
- `overview.access.language` → `"Langue"`, `overview.snapshot.title` → `"Instantané"`
- `cron` section: complete translation of all sub-sections (summary, jobs, runs, form, jobList, jobDetail, jobState, runEntry, errors)
- `languages.fr` → `"Français"` (self-reference, no parens needed)

### 2. Update `ui/src/i18n/lib/types.ts`

```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

### 3. Update `ui/src/i18n/lib/registry.ts`

Add to `LAZY_LOCALES`:
```ts
const LAZY_LOCALES: readonly LazyLocale[] = ["zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"];
```

Add to `LAZY_LOCALE_REGISTRY`:
```ts
fr: {
  exportName: "fr",
  loader: () => import("../locales/fr.ts"),
},
```

Add to `resolveNavigatorLocale` before the `return DEFAULT_LOCALE` fallback:
```ts
if (navLang.startsWith("fr")) {
  return "fr";
}
```

### 4. Update `languages` in all existing locale files

Add `fr` to each locale's `languages` block (append at end of the object):
- **en.ts**: `fr: "Français (French)"`
- **de.ts**: `fr: "Französisch (Français)"`
- **es.ts**: `fr: "Francés (Français)"`
- **pt-BR.ts**: `fr: "Français (Francês)"`
- **zh-CN.ts**: `fr: "Français (法语)"`
- **zh-TW.ts**: `fr: "Français (法語)"`

### 5. Update `src/i18n/registry.test.ts`

- Update `SUPPORTED_LOCALES` expectation to include `"fr"`
- Add fr browser locale resolution test: `expect(resolveNavigatorLocale("fr-FR")).toBe("fr")`
- Add fr lazy load test verifying `common.health` → `"Santé"`

### 6. Update `ui/src/i18n/test/translate.test.ts`

Import `fr` and add to version label test:
```ts
import { fr } from "../locales/fr.ts";
// in the test:
expect((fr.common as { version?: string }).version).toBeTruthy();
```

## Branch & PR

- Create branch: `feat/fr-language-support`
- Commit using `scripts/committer`
- PR title: `feat(i18n): add French (fr) language support`

## Verification

```bash
pnpm test -- src/i18n/registry.test.ts
pnpm test -- ui/src/i18n/test/translate.test.ts
pnpm build
```

Confirm no `[INEFFECTIVE_DYNAMIC_IMPORT]` warnings and both test suites pass.
